import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show Uint64List;
import 'package:rxdart/rxdart.dart';

import '../core_api/enums.dart';
import '../core_api/models.dart';
import '../features/storage/google_drive_service.dart';
import '../src/rust/api/cloud_library.dart' as rust;

/// Builds and serves the cloud library.
///
/// Two passes, matching how the library is meant to feel: the first walks the
/// Drive tree and records every audio file by name, so the library is
/// browsable within seconds; the second reads tags over HTTP byte ranges and
/// fills the rows in behind it. A track is playable as soon as pass one has
/// seen it.
class CloudLibrary {
  CloudLibrary({
    required GoogleDriveService drive,
    required String dbPath,
    required String cacheDir,
  })  : _drive = drive,
        _dbPath = dbPath,
        _cacheDir = cacheDir;

  final GoogleDriveService _drive;
  final String _dbPath;

  /// Where tag reads cache byte ranges, on whichever platform this is.
  final String _cacheDir;

  bool _opened = false;
  bool _scanning = false;
  Completer<void>? _cancel;

  /// Folders the user chose to index. Empty means nothing has been chosen
  /// yet; the scan refuses to run rather than silently walking the whole
  /// Drive, which on a large account takes a very long time and indexes a lot
  /// of things that are not music.
  final _folders = BehaviorSubject<List<DriveFolder>>.seeded(const []);

  final _status = BehaviorSubject<SyncStatus>.seeded(SyncStatus.idle);
  final _tracks = BehaviorSubject<List<Track>>.seeded(const []);
  final _albums = BehaviorSubject<List<Album>>.seeded(const []);

  Stream<List<DriveFolder>> get folders => _folders.stream;
  List<DriveFolder> get currentFolders => _folders.value;

  Stream<SyncStatus> get status => _status.stream;
  Stream<List<Track>> get tracks => _tracks.stream;
  Stream<List<Album>> get albums => _albums.stream;

  List<Track> get currentTracks => _tracks.value;
  List<Album> get currentAlbums => _albums.value;
  bool get isScanning => _scanning;

  /// The Drive connection as the UI's own source model, combining who is
  /// signed in with what the scan is doing. Emits an empty list when signed
  /// out, which is what drives Home's "no source yet" state.
  Stream<List<SourceAccount>> get sourceAccounts => Rx.combineLatest3(
        _drive.accountStream.startWith(_drive.currentUser),
        _status.stream,
        _tracks.stream,
        (account, status, tracks) {
          if (account == null) return const <SourceAccount>[];
          return [
            SourceAccount(
              id: 'drive',
              provider: 'Google Drive',
              accountLabel: account.email,
              trackCount: tracks.length,
              folderCount: tracks.map((t) => t.folderPath).toSet().length,
              status: switch (status.phase) {
                SyncPhase.listing || SyncPhase.tags => SourceStatus.syncing,
                SyncPhase.paused => SourceStatus.needsReconnect,
                SyncPhase.error => SourceStatus.error,
                SyncPhase.idle => SourceStatus.upToDate,
              },
              lastSync: DateTime.now(),
              activityLabel: switch (status.phase) {
                SyncPhase.listing => 'Finding music',
                SyncPhase.tags => 'Reading tags',
                SyncPhase.paused => status.detail ?? 'Paused',
                SyncPhase.error => status.detail ?? 'Scan failed',
                SyncPhase.idle => null,
              },
              // Listing has no known total until it ends, so it reports an
              // indeterminate bar rather than inventing a denominator.
              activityProgress: status.phase == SyncPhase.listing
                  ? null
                  : (status.total > 0 ? status.progress : null),
            ),
          ];
        },
      );

  Track? trackById(String id) =>
      _tracks.value.cast<Track?>().firstWhere((t) => t!.id == id, orElse: () => null);

  /// Where the folder choice is kept. Beside the index, so clearing app data
  /// drops both together and they can never disagree.
  File get _folderFile => File('$_dbPath.folders.json');

  Future<void> open() async {
    if (_opened) return;
    await rust.cloudLibraryOpen(dbPath: _dbPath, cacheDir: _cacheDir);
    _opened = true;
    await _loadFolders();
    await _reload();
  }

  Future<void> _loadFolders() async {
    try {
      if (!_folderFile.existsSync()) return;
      final raw = jsonDecode(await _folderFile.readAsString()) as List<dynamic>;
      _folders.add(raw
          .map((e) => DriveFolder.fromJson(e as Map<String, dynamic>))
          .toList());
    } catch (e) {
      debugPrint('[library] could not read folder choice: $e');
    }
  }

  /// Replaces the chosen folders. Clears the index, because rows from a
  /// folder that is no longer selected would otherwise linger forever.
  Future<void> setFolders(List<DriveFolder> folders) async {
    await open();
    _folders.add(folders);
    try {
      await _folderFile.writeAsString(
        jsonEncode(folders.map((f) => f.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[library] could not save folder choice: $e');
    }
    await rust.cloudLibraryClear();
    await _reload();
  }

  /// Walks Drive, then reads tags. Safe to call again; a second call while a
  /// scan is running is ignored rather than starting a competing walk.
  Future<void> scan({List<DriveFolder>? only}) async {
    if (_scanning) return;
    if (!_drive.isSignedIn) {
      _status.add(const SyncStatus(
        phase: SyncPhase.error,
        detail: 'Not signed in to Google Drive.',
      ));
      return;
    }

    await open();
    final targets = only ?? _folders.value;
    if (targets.isEmpty) {
      _status.add(const SyncStatus(
        phase: SyncPhase.error,
        detail: 'Choose which folders to index first.',
      ));
      return;
    }

    _scanning = true;
    _cancel = Completer<void>();

    try {
      await _listPass(targets);
      if (_cancel?.isCompleted ?? false) return;
      await _tagPass();
    } catch (e) {
      debugPrint('[library] scan failed: $e');
      _status.add(SyncStatus(phase: SyncPhase.error, detail: '$e'));
    } finally {
      _scanning = false;
      _cancel = null;
    }
  }

  void cancelScan() {
    if (!(_cancel?.isCompleted ?? true)) _cancel?.complete();
  }

  /// Pass one: record every audio file by name.
  Future<void> _listPass(List<DriveFolder> targets) async {
    _status.add(const SyncStatus(phase: SyncPhase.listing));

    // Batched so FFI crossings scale with folders, not files.
    const batchSize = 16;
    final ids = <String>[];
    final names = <String>[];
    final paths = <String>[];
    final sizes = <int>[];
    var found = 0;

    Future<void> flush() async {
      if (ids.isEmpty) return;
      await rust.cloudLibraryAddFiles(
        fileIds: List.of(ids),
        names: List.of(names),
        folderPaths: List.of(paths),
        sizes: Uint64List.fromList(sizes),
      );
      ids.clear();
      names.clear();
      paths.clear();
      sizes.clear();
      await _reload();
    }

    for (final folder in targets) {
      if (_cancel?.isCompleted ?? false) break;

      await for (final file in _drive.scanFolder(
        folder.id,
        rootName: folder.name,
      )) {
        if (_cancel?.isCompleted ?? false) break;

        ids.add(file.id);
        names.add(file.name);
        paths.add(file.folderPath);
        sizes.add(file.sizeBytes);
        found++;

        if (ids.length >= batchSize) {
          await flush();
          _status.add(SyncStatus(phase: SyncPhase.listing, processed: found));
        }
      }
      // Flush per folder as well, so the library fills in as the walk goes
      // rather than staying empty until a batch happens to fill.
      await flush();
      _status.add(SyncStatus(phase: SyncPhase.listing, processed: found));
    }
    await flush();
    _status.add(SyncStatus(phase: SyncPhase.listing, processed: found, total: found));
  }

  /// Pass two: read tags over byte ranges, a few files at a time.
  Future<void> _tagPass() async {
    final counts = await rust.cloudLibraryCounts();
    var done = counts.tagged;
    final total = counts.total;

    // Small concurrency: enough to hide round-trip latency, low enough to stay
    // well inside Drive's per-user request budget and leave headroom for
    // playback, which shares the same quota.
    const concurrency = 4;
    const pageSize = 64;

    while (true) {
      if (_cancel?.isCompleted ?? false) return;

      final pending = await rust.cloudLibraryPending(limit: pageSize);
      if (pending.isEmpty) break;

      final token = await _drive.freshAccessToken();
      if (token == null) {
        _status.add(const SyncStatus(
          phase: SyncPhase.paused,
          detail: 'Google Drive needs you to reconnect.',
        ));
        return;
      }

      for (var i = 0; i < pending.length; i += concurrency) {
        if (_cancel?.isCompleted ?? false) return;

        final slice = pending.skip(i).take(concurrency);
        await Future.wait(slice.map((id) async {
          try {
            await rust.cloudLibraryReadTags(
              fileId: id,
              url: 'https://www.googleapis.com/drive/v3/files/$id?alt=media',
              authToken: token,
            );
          } catch (e) {
            // One unreadable file must not stop the pass; the row keeps its
            // filename-derived title.
            debugPrint('[library] tag read failed for $id: $e');
          }
        }));

        done += slice.length;
        _status.add(SyncStatus(
          phase: SyncPhase.tags,
          processed: done,
          total: total,
        ));
      }

      await _reload();
    }

    await _reload();
    _status.add(SyncStatus(phase: SyncPhase.idle, processed: total, total: total));
  }

  /// Re-reads the database and rebuilds the track and album lists.
  Future<void> _reload() async {
    if (!_opened) return;
    try {
      final rows = await rust.cloudLibraryTracks();
      final tracks = rows.map(_toTrack).toList();
      _tracks.add(tracks);
      _albums.add(_groupAlbums(tracks));
    } catch (e) {
      debugPrint('[library] reload failed: $e');
    }
  }

  Future<void> clear() async {
    await open();
    await rust.cloudLibraryClear();
    await _reload();
    _status.add(SyncStatus.idle);
  }

  // ---- Mapping -------------------------------------------------------------

  /// A stable album id, so the same album keeps its identity across rescans.
  static String albumIdFor(String album, String artist) {
    final key = '${album.toLowerCase()}|${artist.toLowerCase()}';
    return 'cl-${key.hashCode.toUnsigned(32).toRadixString(16)}';
  }

  static Codec _codecFor(String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'flac' => Codec.flac,
      'alac' || 'm4a' => Codec.alac,
      'wav' || 'wave' => Codec.wav,
      'aif' || 'aiff' => Codec.aiff,
      'mp3' => Codec.mp3,
      'aac' => Codec.aac,
      'ogg' => Codec.opus,
      _ => Codec.flac,
    };
  }

  Track _toTrack(rust.CloudTrack r) {
    final artist = r.artist.isNotEmpty ? r.artist : 'Unknown artist';
    final album = r.album.isNotEmpty ? r.album : 'Unknown album';
    final albumArtist = r.albumArtist.isNotEmpty ? r.albumArtist : artist;
    final albumId = albumIdFor(album, albumArtist);

    return Track(
      id: r.fileId,
      title: r.title,
      artist: artist,
      albumTitle: album,
      albumId: albumId,
      durationMs: r.durationMs,
      // Before the tag pass the stream info is unknown; the UI shows these as
      // pending rather than printing a confident 0/0.
      format: AudioFormat(
        codec: _codecFor(r.name),
        bitDepth: r.bitsPerSample == 0 ? 16 : r.bitsPerSample,
        sampleRate: r.sampleRate == 0 ? 44100 : r.sampleRate,
        channels: r.channels == 0 ? 2 : r.channels,
      ),
      availability: Availability.cloudOnly,
      sizeBytes: r.sizeBytes.toInt(),
      artwork: Artwork(
        seed: albumId.hashCode,
        dominantColor: _tintFor(albumId),
        // Embedded cover pulled out during the tag pass. Null until that
        // reaches this track, so the seeded gradient stands in meanwhile.
        uri: r.artworkPath.isEmpty ? null : r.artworkPath,
      ),
      trackNumber: r.trackNumber == 0 ? null : r.trackNumber,
      discNumber: r.discNumber == 0 ? 1 : r.discNumber,
      year: r.year == 0 ? null : r.year,
      genre: r.genre.isEmpty ? null : r.genre,
      folderPath: r.folderPath,
      tagsPending: !r.tagsRead,
    );
  }

  List<Album> _groupAlbums(List<Track> tracks) {
    final byId = <String, List<Track>>{};
    for (final t in tracks) {
      byId.putIfAbsent(t.albumId, () => []).add(t);
    }

    final out = <Album>[];
    byId.forEach((id, items) {
      items.sort((a, b) {
        final disc = a.discNumber.compareTo(b.discNumber);
        if (disc != 0) return disc;
        return (a.trackNumber ?? 0).compareTo(b.trackNumber ?? 0);
      });

      final rates = items.map((t) => t.format.sampleRate).toSet();
      final depths = items.map((t) => t.format.bitDepth).toSet();

      // The album's headline format is its highest resolution, which is what
      // the badge on the grid card claims.
      final best = items.reduce((a, b) =>
          a.format.sampleRate * a.format.bitDepth >=
                  b.format.sampleRate * b.format.bitDepth
              ? a
              : b);

      out.add(Album(
        id: id,
        title: items.first.albumTitle,
        artist: items.first.artist,
        artistId: 'ca-${items.first.artist.toLowerCase().hashCode.toUnsigned(32).toRadixString(16)}',
        trackCount: items.length,
        durationMs: items.fold(0, (s, t) => s + t.durationMs),
        sizeBytes: items.fold(0, (s, t) => s + t.sizeBytes),
        format: best.format,
        availability: Availability.cloudOnly,
        artwork: items
            .firstWhere((t) => t.artwork.uri != null,
                orElse: () => items.first)
            .artwork,
        year: items.first.year,
        genre: items.first.genre,
        discCount: items.map((t) => t.discNumber).toSet().length,
        mixedFormats: rates.length > 1 || depths.length > 1,
        formatVarianceNote: (rates.length > 1 || depths.length > 1)
            ? 'Formats vary within this album; brief gaps may occur where the '
                'sample rate changes.'
            : null,
        folderPath: items.first.folderPath,
        tagsPending: items.any((t) => t.tagsPending),
      ));
    });

    out.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return out;
  }

  /// A deterministic tint so an album looks the same on every launch.
  static int _tintFor(String seed) {
    const palette = [
      0xFF2E5A7A, 0xFF6B4A3A, 0xFF1F6F6B, 0xFF4A3B6B, 0xFF3E5B2F,
      0xFF7A3B5C, 0xFF8A6A2F, 0xFF3A6B8A, 0xFF6B5A2F, 0xFF4A4A52,
    ];
    return palette[seed.hashCode.toUnsigned(32) % palette.length];
  }

  void dispose() {
    cancelScan();
    unawaited(_folders.close());
    unawaited(_status.close());
    unawaited(_tracks.close());
    unawaited(_albums.close());
  }
}

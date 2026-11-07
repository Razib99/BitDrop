import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show Uint64List;
import 'package:rxdart/rxdart.dart';

import '../core_api/enums.dart';
import '../core_api/models.dart';
import '../features/storage/google_drive_service.dart';
import '../src/rust/api/cloud_library.dart' as rust;
import '../src/rust/cloud/db.dart' as rust_db;

/// A local music directory chosen by the user.
@immutable
class LocalFolder {
  const LocalFolder({
    required this.path,
    required this.label,
    this.lastScanned,
    this.trackCount = 0,
  });

  final String path;
  final String label;
  final DateTime? lastScanned;
  final int trackCount;

  LocalFolder copyWith({
    String? path,
    String? label,
    DateTime? lastScanned,
    int? trackCount,
  }) =>
      LocalFolder(
        path: path ?? this.path,
        label: label ?? this.label,
        lastScanned: lastScanned ?? this.lastScanned,
        trackCount: trackCount ?? this.trackCount,
      );

  Map<String, dynamic> toJson() => {
        'path': path,
        'label': label,
        'lastScanned': lastScanned?.toIso8601String(),
        'trackCount': trackCount,
      };

  factory LocalFolder.fromJson(Map<String, dynamic> json) => LocalFolder(
        path: json['path'] as String,
        label: json['label'] as String? ?? 'Local Music',
        lastScanned: json['lastScanned'] != null
            ? DateTime.tryParse(json['lastScanned'] as String)
            : null,
        trackCount: (json['trackCount'] as num?)?.toInt() ?? 0,
      );
}

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
  final _localFolders = BehaviorSubject<List<LocalFolder>>.seeded(const []);

  final _status = BehaviorSubject<SyncStatus>.seeded(SyncStatus.idle);
  final _tracks = BehaviorSubject<List<Track>>.seeded(const []);
  final _albums = BehaviorSubject<List<Album>>.seeded(const []);

  void Function(String oldId, String newId)? onFileReplaced;
  void Function(List<String> prunedIds)? onFilesPruned;

  Stream<List<DriveFolder>> get folders => _folders.stream;
  List<DriveFolder> get currentFolders => _folders.value;

  Stream<List<LocalFolder>> get localFolders => _localFolders.stream;
  List<LocalFolder> get currentLocalFolders => _localFolders.value;

  Stream<SyncStatus> get status => _status.stream;
  Stream<List<Track>> get tracks => _tracks.stream;
  Stream<List<Album>> get albums => _albums.stream;

  List<Track> get currentTracks => _tracks.value;
  List<Album> get currentAlbums => _albums.value;
  bool get isScanning => _scanning;

  static bool _isLocalTrackId(String id) =>
      id.startsWith('/') ||
      (Platform.isWindows && RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(id));

  void _deleteDiskCacheFor(String fileId) {
    try {
      rust.cloudCacheRemoveTrack(fileId: fileId, cacheDir: _cacheDir);
    } catch (e) {
      debugPrint('[cloud] failed to delete chunk cache for $fileId: $e');
    }
  }

  /// Sources combining connected cloud providers (Google Drive) and local
  /// device music storage roots. Emits an empty list when neither is present,
  /// which drives Home's "no source yet" state.
  Stream<List<SourceAccount>> get sourceAccounts => Rx.combineLatest4(
        _drive.accountStream.startWith(_drive.currentUser),
        _status.stream,
        _tracks.stream,
        _localFolders.stream,
        (account, status, tracks, localFolders) {
          final result = <SourceAccount>[];

          if (localFolders.isNotEmpty) {
            final localTracks =
                tracks.where((t) => _isLocalTrackId(t.id)).toList();
            final lastScan = localFolders
                .map((f) => f.lastScanned)
                .whereNotNull()
                .maxOrNull;
            result.add(
              SourceAccount(
                id: 'local',
                provider: 'This Device',
                accountLabel:
                    '${localFolders.length} folder${localFolders.length == 1 ? '' : 's'} indexed',
                trackCount: localTracks.length,
                folderCount: localFolders.length,
                status: SourceStatus.upToDate,
                lastSync: lastScan,
              ),
            );
          }

          if (account != null) {
            final driveTracks =
                tracks.where((t) => !_isLocalTrackId(t.id)).toList();
            result.add(
              SourceAccount(
                id: 'drive',
                provider: 'Google Drive',
                accountLabel: account.email,
                trackCount: driveTracks.length,
                folderCount:
                    driveTracks.map((t) => t.folderPath).toSet().length,
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
                activityProgress: status.phase == SyncPhase.listing
                    ? null
                    : (status.total > 0 ? status.progress : null),
              ),
            );
          }

          return result;
        },
      );

  Track? trackById(String id) => _tracks.value
      .cast<Track?>()
      .firstWhere((t) => t!.id == id, orElse: () => null);

  /// Where the folder choice is kept. Beside the index, so clearing app data
  /// drops both together and they can never disagree.
  File get _folderFile => File('$_dbPath.folders.json');
  File get _localFolderFile => File('$_dbPath.local_folders.json');

  Future<void> open() async {
    if (_opened) return;
    await rust.cloudLibraryOpen(dbPath: _dbPath, cacheDir: _cacheDir);
    _opened = true;
    await _loadFolders();
    await _loadLocalFolders();
    await _reload();
    unawaited(_artworkPass());
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

  Future<void> _loadLocalFolders() async {
    try {
      if (!_localFolderFile.existsSync()) return;
      final raw =
          jsonDecode(await _localFolderFile.readAsString()) as List<dynamic>;
      _localFolders.add(raw
          .map((e) => LocalFolder.fromJson(e as Map<String, dynamic>))
          .toList());
    } catch (e) {
      debugPrint('[library] could not read local folder choice: $e');
    }
  }

  Future<void> _saveLocalFolders() async {
    try {
      await _localFolderFile.writeAsString(
        jsonEncode(_localFolders.value.map((f) => f.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[library] could not save local folder choice: $e');
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

  /// Adds a local directory as a music source root and immediately indexes it.
  Future<int> addLocalFolder(String directoryPath, {String? label}) async {
    await open();
    final cleanPath = directoryPath.trim();
    if (cleanPath.isEmpty) return 0;

    final existing =
        _localFolders.value.firstWhereOrNull((f) => f.path == cleanPath);
    final folderLabel = label ??
        cleanPath.split(Platform.pathSeparator).lastWhere(
              (s) => s.isNotEmpty,
              orElse: () => 'Local Music',
            );

    final folder = existing ??
        LocalFolder(
          path: cleanPath,
          label: folderLabel,
        );

    if (existing == null) {
      _localFolders.add([..._localFolders.value, folder]);
      await _saveLocalFolders();
    }

    return await scanLocalFolder(folder);
  }

  /// Removes a local directory source and prunes all indexed tracks under it.
  Future<void> removeLocalFolder(String directoryPath) async {
    await open();
    final folder =
        _localFolders.value.firstWhereOrNull((f) => f.path == directoryPath);
    if (folder == null) return;

    final updated =
        _localFolders.value.where((f) => f.path != directoryPath).toList();
    _localFolders.add(updated);
    await _saveLocalFolders();

    final pruned = await rust.cloudLibraryPruneMissing(
      folderPrefixes: [folder.label],
      validFileIds: const [],
    );
    if (pruned.isNotEmpty) {
      onFilesPruned?.call(pruned);
      await _reload();
    }
  }

  /// Clears all local folders and removes their tracks.
  Future<void> clearLocalFolders() async {
    await open();
    final oldFolders = List.of(_localFolders.value);
    _localFolders.add(const []);
    await _saveLocalFolders();

    final prefixes = oldFolders.map((f) => f.label).toList();
    if (prefixes.isNotEmpty) {
      final pruned = await rust.cloudLibraryPruneMissing(
        folderPrefixes: prefixes,
        validFileIds: const [],
      );
      if (pruned.isNotEmpty) {
        onFilesPruned?.call(pruned);
        await _reload();
      }
    }
  }

  /// Scans a single local folder root and updates its track count and timestamp.
  Future<int> scanLocalFolder(LocalFolder folder) async {
    await open();
    try {
      final scannedCount = await rust.cloudLibraryScanLocalFolder(
        directoryPath: folder.path,
        label: folder.label,
      );

      final updatedFolders = _localFolders.value.map((f) {
        if (f.path == folder.path) {
          return f.copyWith(
            lastScanned: DateTime.now(),
            trackCount: scannedCount,
          );
        }
        return f;
      }).toList();

      _localFolders.add(updatedFolders);
      await _saveLocalFolders();
      await _reload();
      return scannedCount;
    } catch (e) {
      debugPrint('[library] local scan error for ${folder.path}: $e');
      rethrow;
    }
  }

  /// Scans all configured local directories sequentially.
  Future<int> scanAllLocalFolders() async {
    await open();
    var totalScanned = 0;
    for (final folder in _localFolders.value) {
      totalScanned += await scanLocalFolder(folder);
    }
    return totalScanned;
  }

  /// Proactively fetches missing posters and synchronizes album artwork.
  Future<void> syncArtwork() async {
    await open();
    await _artworkPass();
  }

  Future<void> _artworkPass() async {
    try {
      final artDir = Directory('$_cacheDir/artwork');
      if (artDir.existsSync()) {
        final bad = File('${artDir.path}/unknown_artist__unknown_album.img');
        if (bad.existsSync()) {
          try {
            bad.deleteSync();
          } catch (_) {}
        }
      }
      final updated = await rust.cloudLibrarySyncMissingArtwork();
      if (updated > 0) {
        debugPrint('[library] artwork sync updated $updated track posters');
        await _reload();
      }
    } catch (e) {
      debugPrint('[library] artwork pass error: $e');
    }
  }

  /// Walks Drive, then reads tags. Safe to call again; a second call while a
  /// scan is running is ignored rather than starting a competing walk.
  Future<void> scan({List<DriveFolder>? only}) async {
    if (_scanning) return;
    _scanning = true;
    _cancel = Completer<void>();
    try {
      if (!_drive.isSignedIn) {
        throw StateError('Not signed in to Google Drive.');
      }
      await open();
      final targets = only ?? _folders.value;
      if (targets.isEmpty) {
        throw StateError('Choose which folders to index first.');
      }
      if (_cancel?.isCompleted ?? false) return;
      await _listPass(targets);
      if (_cancel?.isCompleted ?? false) return;
      await _tagPass();
      if (_cancel?.isCompleted ?? false) return;
      await _artworkPass();
    } catch (e) {
      debugPrint('[library] scan failed: $e');
      _status.add(SyncStatus(phase: SyncPhase.error, detail: '$e'));
    } finally {
      if (_cancel?.isCompleted ?? false) {
        _status.add(
            const SyncStatus(phase: SyncPhase.idle, detail: 'Scan cancelled.'));
      }
      _scanning = false;
      _cancel = null;
    }
  }

  void cancelScan() {
    if (!(_cancel?.isCompleted ?? true)) _cancel?.complete();
  }

  /// Pass one: record every audio file by name and synchronize changes.
  Future<void> _listPass(List<DriveFolder> targets) async {
    _status.add(const SyncStatus(phase: SyncPhase.listing));

    // Batched so FFI crossings scale with folders, not files.
    const batchSize = 16;
    final ids = <String>[];
    final names = <String>[];
    final paths = <String>[];
    final sizes = <int>[];
    var found = 0;
    final seenFileIds = <String>{};

    Future<void> flush() async {
      if (ids.isEmpty) return;
      final replaced = await rust.cloudLibraryAddFiles(
        fileIds: List.of(ids),
        names: List.of(names),
        folderPaths: List.of(paths),
        sizes: Uint64List.fromList(sizes),
      );
      for (final r in replaced) {
        _deleteDiskCacheFor(r.oldFileId);
        onFileReplaced?.call(r.oldFileId, r.newFileId);
      }
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

        seenFileIds.add(file.id);
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

    // Prune missing files that were removed from Google Drive
    if (!(_cancel?.isCompleted ?? false)) {
      final targetPrefixes = targets.map((f) => f.name).toList();
      final prunedIds = await rust.cloudLibraryPruneMissing(
        folderPrefixes: targetPrefixes,
        validFileIds: seenFileIds.toList(),
      );
      for (final id in prunedIds) {
        _deleteDiskCacheFor(id);
      }
      if (prunedIds.isNotEmpty) {
        onFilesPruned?.call(prunedIds);
        await _reload();
      }
    }

    _status.add(
        SyncStatus(phase: SyncPhase.listing, processed: found, total: found));
  }

  /// Pass two: read tags over byte ranges, a few files at a time.
  Future<void> _tagPass() async {
    final counts = await rust.cloudLibraryCounts();
    var done = counts.tagged;
    final total = counts.total;

    // Small concurrency: enough to hide round-trip latency, low enough to stay
    // well inside Drive's per-user request budget and leave headroom for
    // playback, which shares the same quota.
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

      final scanned = await rust.cloudLibraryScanTagsBatch(
        fileIds: pending,
        authToken: token,
      );
      done += scanned;
      _status.add(SyncStatus(
        phase: SyncPhase.tags,
        processed: done,
        total: total,
      ));

      await _reload();
    }

    await _reload();
    _status
        .add(SyncStatus(phase: SyncPhase.idle, processed: total, total: total));
  }

  /// Instant ranked FTS5 search query against SQLite.
  Future<List<Track>> search(String query, {int limit = 50}) async {
    if (!_opened || query.trim().isEmpty) return const [];
    try {
      final rows = await rust.cloudLibrarySearch(query: query, limit: limit);
      return rows.map(_toTrack).toList();
    } catch (e) {
      debugPrint('[library] FTS5 search failed: $e');
      return const [];
    }
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
    if (_localFolders.value.isEmpty) {
      await rust.cloudLibraryClear();
    } else {
      final drivePrefixes = _folders.value.map((f) => f.name).toList();
      if (drivePrefixes.isNotEmpty) {
        await rust.cloudLibraryPruneMissing(
          folderPrefixes: drivePrefixes,
          validFileIds: const [],
        );
      }
    }
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
      'dsf' || 'dff' => Codec.dsf,
      _ => Codec.flac,
    };
  }

  /// Converts an indexed SQLite track row from Rust into a model [Track].
  static Track trackFromRow(rust_db.CloudTrackRow r) {
    final title = r.title.isNotEmpty
        ? r.title
        : r.name.replaceFirst(RegExp(r'\.[a-zA-Z0-9]+$'), '');
    final artist = r.artist.isNotEmpty ? r.artist : 'Unknown artist';
    final album = r.album.isNotEmpty ? r.album : 'Unknown album';
    final albumArtist = r.albumArtist.isNotEmpty ? r.albumArtist : artist;
    final albumId = albumIdFor(album, albumArtist);
    final isLocal = _isLocalTrackId(r.fileId);

    return Track(
      id: r.fileId,
      title: title,
      artist: artist,
      albumTitle: album,
      albumId: albumId,
      durationMs: r.durationMs,
      format: AudioFormat(
        codec: _codecFor(r.name),
        bitDepth: r.bitsPerSample == 0 ? 16 : r.bitsPerSample,
        sampleRate: r.sampleRate == 0 ? 44100 : r.sampleRate,
        channels: r.channels == 0 ? 2 : r.channels,
      ),
      availability: isLocal ? Availability.cached : Availability.cloudOnly,
      sizeBytes: r.sizeBytes.toInt(),
      artwork: Artwork(
        seed: albumId.hashCode,
        dominantColor: _tintFor(albumId),
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

  Track _toTrack(rust.CloudTrack r) {
    final title = r.title.isNotEmpty
        ? r.title
        : r.name.replaceFirst(RegExp(r'\.[a-zA-Z0-9]+$'), '');
    final artist = r.artist.isNotEmpty ? r.artist : 'Unknown artist';
    final album = r.album.isNotEmpty ? r.album : 'Unknown album';
    final albumArtist = r.albumArtist.isNotEmpty ? r.albumArtist : artist;
    final albumId = albumIdFor(album, albumArtist);
    final isLocal = _isLocalTrackId(r.fileId);

    return Track(
      id: r.fileId,
      title: title,
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
      availability: isLocal ? Availability.cached : Availability.cloudOnly,
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

      final albumArt = items
          .firstWhere((t) => t.artwork.uri != null, orElse: () => items.first)
          .artwork;

      if (albumArt.uri != null) {
        for (var i = 0; i < items.length; i++) {
          if (items[i].artwork.uri == null) {
            items[i] = items[i].copyWith(artwork: albumArt);
          }
        }
      }

      final allCached = items.every((t) => t.availability == Availability.cached);

      out.add(Album(
        id: id,
        title: items.first.albumTitle,
        artist: items.first.artist,
        artistId:
            'ca-${items.first.artist.toLowerCase().hashCode.toUnsigned(32).toRadixString(16)}',
        trackCount: items.length,
        durationMs: items.fold(0, (s, t) => s + t.durationMs),
        sizeBytes: items.fold(0, (s, t) => s + t.sizeBytes),
        format: best.format,
        availability: allCached ? Availability.cached : Availability.cloudOnly,
        artwork: albumArt,
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
        addedAt: DateTime.fromMillisecondsSinceEpoch(
            1700000000000 + id.hashCode.abs() % 1000000000),
      ));
    });

    // Propagate enriched tracks back into the passed list so tracks tab has artwork
    final trackMap = <String, Track>{};
    for (final items in byId.values) {
      for (final t in items) {
        trackMap[t.id] = t;
      }
    }
    for (var i = 0; i < tracks.length; i++) {
      if (trackMap.containsKey(tracks[i].id)) {
        tracks[i] = trackMap[tracks[i].id]!;
      }
    }

    out.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return out;
  }

  /// A deterministic tint so an album looks the same on every launch.
  static int _tintFor(String seed) {
    const palette = [
      0xFF2E5A7A,
      0xFF6B4A3A,
      0xFF1F6F6B,
      0xFF4A3B6B,
      0xFF3E5B2F,
      0xFF7A3B5C,
      0xFF8A6A2F,
      0xFF3A6B8A,
      0xFF6B5A2F,
      0xFF4A4A52,
    ];
    return palette[seed.hashCode.toUnsigned(32) % palette.length];
  }

  void dispose() {
    cancelScan();
    unawaited(_folders.close());
    unawaited(_localFolders.close());
    unawaited(_status.close());
    unawaited(_tracks.close());
    unawaited(_albums.close());
  }
}

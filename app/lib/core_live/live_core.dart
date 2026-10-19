import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:audio_service/audio_service.dart' as audio_svc;
import 'package:rxdart/rxdart.dart';
import '../core_api/bitdrop_core.dart';
import '../core_api/commands.dart';
import '../core_api/enums.dart';
import '../core_api/models.dart';
import '../core_api/queries.dart';
import '../core_api/settings.dart';
import '../core_mock/catalog.dart';
import '../core_mock/mock_core.dart';
import 'audio_handler.dart';
import 'cloud_library.dart';
import 'output_device.dart';
import '../src/rust/api/audio_engine.dart' as rust;
import '../src/rust/api/cloud_library.dart' as rust_cache;
import '../src/rust/api/simple.dart' as rust_simple;
import '../util/biquad.dart';

class LiveBitDropCore implements BitDropCore {
  final BitDropAudioHandler _audioHandler;
  final MockBitDropCore _mockCore;

  /// Null until Drive is connected. Everything cloud-related is served from
  /// here; local scanning and the mock catalogue are untouched by it.
  final CloudLibrary? _cloud;

  final Map<String, Track> _realTracks = {};

  /// Where streamed audio chunks land, and where cover art is kept. Two
  /// separate roots, so clearing the cache can take the regenerable gigabytes
  /// and leave the few megabytes the library needs in order to render.
  final String? _chunkCacheDir;
  final String? _artworkCacheDir;

  /// Every directory chunks get written to. The player writes to its own, and
  /// the tag reader writes to the one beside the artwork while probing a new
  /// track for its metadata — so a clear that only swept the player's would
  /// leave tens of megabytes behind and report the wrong figure.
  List<String> get _chunkDirs => [
        if (_chunkCacheDir != null) _chunkCacheDir,
        if (_artworkCacheDir != null)
          _artworkCacheDir.replaceFirst(RegExp(r'/artwork/?$'), ''),
      ];

  /// When the current stall began, for escalating the buffering copy.
  DateTime? _bufferingSince;

  /// Last seen output-stream open count. An exclusive AAudio stream is torn
  /// down by any routing change and the engine silently rebuilds it; logging
  /// the rebuild is what turns "it just went quiet" into something that can
  /// be read off a bug report.
  int _streamOpens = 0;

  final _outputProbe = OutputDeviceProbe();
  final _signalPath = BehaviorSubject<SignalPath>.seeded(_unknownPath);

  static const _unknownPath = SignalPath(
    tier: OutputTier.unknown,
    source: AudioFormat(codec: Codec.flac, bitDepth: 0, sampleRate: 0),
    requested: AudioFormat(codec: Codec.flac, bitDepth: 0, sampleRate: 0),
    actual: AudioFormat(codec: Codec.flac, bitDepth: 0, sampleRate: 0),
    dspActive: false,
    volume: VolumeMode.system,
    explanation: 'Nothing is playing yet, so there is no output path to report.',
  );

  /// What the engine banks before it lets a new track or a landed seek be
  /// heard. Must track `PREBUFFER_MS` in the Rust engine: a progress readout
  /// counting up to a different number than the one the gate actually opens
  /// on would jump to playing part-way along the bar.
  static const _bufferTargetMs = 500;
  Album? _realAlbum;

  LiveBitDropCore(
    this._audioHandler, {
    CloudLibrary? cloudLibrary,
    String? chunkCacheDir,
    String? artworkCacheDir,
  })  : _cloud = cloudLibrary,
        _chunkCacheDir = chunkCacheDir,
        _artworkCacheDir = artworkCacheDir,
        _mockCore = MockBitDropCore() {
    rust.initEngine();

    // The cloud library drives the scan banner on Home and Sources.
    _cloud?.status.listen(_syncStatus.add);
    _cloud?.open();

    refreshStorage();
    _loadFavoritesAndPinned();

    _outputProbe.start();
    _outputProbe.stream.listen((_) => _recomputeSignalPath());
    _mockCore.eq.listen((_) => _recomputeSignalPath());

    _audioHandler.playbackState.listen((state) {
      _recomputeSignalPath();
      final isPlaying = state.playing;
      final buffering =
          state.processingState == audio_svc.AudioProcessingState.buffering;

      final aheadMs = (state.bufferedPosition - state.updatePosition)
          .inMilliseconds
          .clamp(0, 600000);

      // Buffering is not pausing: the user did not stop this, the network
      // did. The wording escalates with the length of the stall so a brief
      // hiccup and a failing connection do not read the same.
      final opens = rust.engineBufferState().streamOpens;
      if (opens != _streamOpens) {
        if (_streamOpens != 0) {
          debugPrint('[audio] output stream rebuilt (open #$opens)');
        }
        _streamOpens = opens;
      }

      if (buffering) {
        _bufferingSince ??= DateTime.now();
        final stalled = DateTime.now().difference(_bufferingSince!);
        _playback.add(BufferingState(
          bufferedMs: aheadMs,
          targetMs: _bufferTargetMs,
          attempt: stalled.inSeconds >= 4 ? 2 : 1,
        ));
      } else {
        _bufferingSince = null;
        _playback.add(isPlaying ? const PlayingState() : const PausedState());
      }

      _position.add(PositionInfo(
        positionMs: state.updatePosition.inMilliseconds,
        durationMs: _audioHandler.mediaItem.value?.duration?.inMilliseconds ?? 0,
        bufferAheadMs: aheadMs,
        // Which parts are already on disk. Non-contiguous after a seek,
        // which is exactly what the bar is meant to show.
        cachedRanges: _cachedRanges(),
      ));
    });
    
    _audioHandler.queue.listen((_) => _emitQueue());
    
    _audioHandler.mediaItem.listen((item) {
      if (item != null) {
        final track = _lookupTrack(item.id);
        if (track != null) {
          _nowPlaying.add(NowPlaying(
            track: _enrichTrack(track),
            contextLabel: _currentContextLabel.isNotEmpty
                ? _currentContextLabel
                : (track.folderPath.isNotEmpty
                    ? track.folderPath
                    : 'Local Music'),
          ));
        }
      }
      _emitQueue();
    });

    _mockCore.eq.listen((eqState) {
      List<double> finalGains;
      if (eqState.mode == EqMode.simple) {
        finalGains = List.filled(10, 0.0);
        finalGains[0] = eqState.bassDb;
        finalGains[1] = eqState.bassDb * 0.8;
        finalGains[2] = eqState.bassDb * 0.4;
        finalGains[7] = eqState.trebleDb * 0.4;
        finalGains[8] = eqState.trebleDb * 0.8;
        finalGains[9] = eqState.trebleDb;
      } else if (eqState.mode == EqMode.graphic) {
        finalGains = eqState.graphicGains.isNotEmpty
            ? eqState.graphicGains.take(10).toList()
            : List.filled(10, 0.0);
      } else if (eqState.mode == EqMode.parametric) {
        // Map parametric EQ bands (including AutoEQ profiles) across the 10 ISO center frequencies:
        // [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000] Hz
        const centers = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
        finalGains = centers
            .map((c) => Biquad.combinedDb(eqState.bands, c.toDouble(), preampDb: 0.0))
            .toList();
      } else {
        finalGains = List.filled(10, 0.0);
      }
      while (finalGains.length < 10) {
        finalGains.add(0.0);
      }
      // Pass the preamp as the 11th element of the gains list!
      finalGains.add(eqState.preampDb);
      
      rust.engineSetEq(gains: finalGains);
      rust.engineSetEqEnabled(enabled: !eqState.bypass);
      _recomputeSignalPath();
    });

    _scanRealMusic();
  }
  
  Future<void> _scanRealMusic() async {
    try {
      final metas = rust_simple.scanDirectory(path: '/home/razib/Desktop/BitDrop/Music');
      if (metas.isEmpty) return;
      
      int duration = 0;
      int size = 0;
      
      for (final m in metas) {
        final t = Track(
          id: m.path,
          title: m.title.isNotEmpty ? m.title : m.path.split('/').last,
          artist: m.artist.isNotEmpty ? m.artist : 'Unknown Artist',
          albumTitle: m.album,
          albumId: 'real-music',
          durationMs: m.durationMs,
          sizeBytes: 50000000,
          format: AudioFormat(codec: Codec.flac, bitDepth: 16, sampleRate: m.sampleRate),
          availability: Availability.cached,
          artwork: Artwork(seed: 42, dominantColor: 0xFF4A90E2, uri: m.path),
          trackNumber: 1,
        );
        _realTracks[t.id] = t;
        duration += m.durationMs;
      }
      
      _realAlbum = Album(
        id: 'real-music',
        title: 'Real Music Folder',
        artist: 'Various Artists',
        artistId: 'various',
        trackCount: _realTracks.length,
        durationMs: duration,
        sizeBytes: size,
        format: const AudioFormat(codec: Codec.flac, bitDepth: 16, sampleRate: 44100),
        availability: Availability.cached,
          artwork: Artwork(seed: 42, dominantColor: 0xFF4A90E2, uri: _realTracks.values.firstOrNull?.id),
        mixedFormats: true,
      );
    } catch (e) {
      debugPrint('[library] local scan failed: $e');
    }
  }


  // Intercepted streams
  final _playback = BehaviorSubject<PlaybackState>.seeded(const IdleState());
  @override Stream<PlaybackState> get playback => _playback.stream;

  final _position = BehaviorSubject<PositionInfo>.seeded(PositionInfo.empty);
  @override Stream<PositionInfo> get position => _position.stream;

  final _nowPlaying = BehaviorSubject<NowPlaying?>.seeded(null);
  @override Stream<NowPlaying?> get nowPlaying => _nowPlaying.stream;

  // Delegated streams
  @override Stream<SignalPath> get signalPath => _signalPath.stream;
  final _queue = BehaviorSubject<QueueState>.seeded(QueueState.empty);
  @override Stream<QueueState> get queue => _queue.stream;
  @override Stream<OutputDevice?> get outputDevice => _outputProbe.stream;
  @override
  Stream<List<SourceAccount>> get sources =>
      _cloud?.sourceAccounts ?? _mockCore.sources;
  final _syncStatus = BehaviorSubject<SyncStatus>.seeded(SyncStatus.idle);
  @override Stream<SyncStatus> get syncStatus => _syncStatus.stream;
  @override Stream<List<AppBanner>> get banners => _mockCore.banners;
  @override Stream<EqState> get eq => _mockCore.eq;
  final _storage = BehaviorSubject<StorageState>.seeded(_emptyStorage);
  @override Stream<StorageState> get storage => _storage.stream;

  static const _emptyStorage = StorageState(
    pinnedBytes: 0,
    cacheBytes: 0,
    freeBytes: 0,
    totalBytes: 0,
    cacheLimitBytes: 0,
  );

  /// Tracks with at least one chunk on disk, for the Sources copy.
  int _cachedTrackCount = 0;
  int get cachedTrackCount => _cachedTrackCount;

  /// Re-measures the on-disk cache.
  ///
  /// Measured by walking the directory rather than tallied as chunks are
  /// written: Android reclaims the cache directory whenever it wants the
  /// space, so a running total the app kept for itself would quietly drift
  /// away from what is really there.
  Future<void> refreshStorage() async {
    final chunks = _chunkCacheDir;
    if (chunks == null) return;
    try {
      final usage = await rust_cache.cacheUsage(
        chunkDirs: _chunkDirs,
        artworkDir: _artworkCacheDir ?? '',
      );
      _cachedTrackCount = usage.trackCount;
      _storage.add(StorageState(
        pinnedBytes: 0,
        cacheBytes: usage.audioBytes.toInt(),
        freeBytes: 0,
        totalBytes: 0,
        cacheLimitBytes: 0,
        artworkBytes: usage.artworkBytes.toInt(),
      ));
    } catch (e) {
      debugPrint('[storage] could not measure cache: $e');
    }
  }
  @override Stream<DiagnosticsSnapshot> get diagnostics => _mockCore.diagnostics;
  @override Stream<VisualizerFrame> get visualizer => _mockCore.visualizer;
  @override Stream<List<DeviceProfile>> get deviceProfiles => _mockCore.deviceProfiles;
  @override Stream<AppSettings> get settings => _mockCore.settings;

  // Delegated queries
  
  /// Resolves an id across every source: cloud first, then the local scan,
  /// then the mock catalogue.
  Track? _lookupTrack(String id) =>
      _cloud?.trackById(id) ?? _realTracks[id] ?? MockCatalog.trackById(id);

  List<Album> get _cloudAlbums => _cloud?.currentAlbums ?? const [];
  List<Track> get _cloudTracks => _cloud?.currentTracks ?? const [];

  final Set<String> _favoriteTrackIds = {};
  final Set<String> _pinnedTrackIds = {};
  final Set<String> _pinnedAlbumIds = {};

  File? get _favoritesFile {
    if (_chunkCacheDir == null) return null;
    final parent = Directory(_chunkCacheDir).parent;
    return File('${parent.path}/favorites.json');
  }

  File? get _pinnedFile {
    if (_chunkCacheDir == null) return null;
    final parent = Directory(_chunkCacheDir).parent;
    return File('${parent.path}/pinned.json');
  }

  Future<void> _loadFavoritesAndPinned() async {
    try {
      final favFile = _favoritesFile;
      if (favFile != null && await favFile.exists()) {
        final text = await favFile.readAsString();
        final raw = jsonDecode(text);
        if (raw is List) {
          _favoriteTrackIds.addAll(raw.map((e) => e.toString()));
        }
      }
    } catch (e) {
      debugPrint('[core] failed to read favorites: $e');
    }

    try {
      final pinFile = _pinnedFile;
      if (pinFile != null && await pinFile.exists()) {
        final text = await pinFile.readAsString();
        final raw = jsonDecode(text);
        if (raw is Map) {
          if (raw['tracks'] is List) {
            _pinnedTrackIds.addAll((raw['tracks'] as List).map((e) => e.toString()));
          }
          if (raw['albums'] is List) {
            _pinnedAlbumIds.addAll((raw['albums'] as List).map((e) => e.toString()));
          }
        }
      }
    } catch (e) {
      debugPrint('[core] failed to read pinned: $e');
    }
  }

  Future<void> _saveFavorites() async {
    final file = _favoritesFile;
    if (file == null) return;
    try {
      await file.writeAsString(jsonEncode(_favoriteTrackIds.toList()));
    } catch (e) {
      debugPrint('[core] failed to write favorites: $e');
    }
  }

  Future<void> _savePinned() async {
    final file = _pinnedFile;
    if (file == null) return;
    try {
      await file.writeAsString(jsonEncode({
        'tracks': _pinnedTrackIds.toList(),
        'albums': _pinnedAlbumIds.toList(),
      }));
    } catch (e) {
      debugPrint('[core] failed to write pinned: $e');
    }
  }

  bool _isTrackFullyCached(String trackId, int sizeBytes) {
    if (_pinnedTrackIds.contains(trackId)) return true;
    final chunks = _chunkCacheDir;
    if (chunks == null || sizeBytes <= 0) return false;
    final idxFile = File('$chunks/$trackId.idx');
    if (!idxFile.existsSync()) return false;
    try {
      final lines = idxFile.readAsLinesSync();
      final unique = lines
          .map((l) => int.tryParse(l.trim()))
          .whereType<int>()
          .toSet();
      final totalChunks = (sizeBytes + 2097152 - 1) ~/ 2097152;
      return totalChunks > 0 && unique.length >= totalChunks;
    } catch (_) {
      return false;
    }
  }

  Track _enrichTrack(Track t) {
    final isFav = _favoriteTrackIds.contains(t.id);
    final isPinned = _pinnedTrackIds.contains(t.id);
    var avail = t.availability;
    if (isPinned) {
      avail = Availability.pinned;
    } else if (_isTrackFullyCached(t.id, t.sizeBytes)) {
      avail = Availability.cached;
    }
    return t.copyWith(
      favorite: isFav,
      availability: avail,
    );
  }

  Album _enrichAlbum(Album a) {
    final isPinned = _pinnedAlbumIds.contains(a.id);
    if (isPinned && a.availability != Availability.pinned) {
      return a.copyWith(availability: Availability.pinned);
    }
    return a;
  }

  List<Track> get _allCandidateTracks => [
        ..._cloudTracks,
        ..._realTracks.values,
        ...MockCatalog.tracks,
      ];

  Album _favoritesAlbum() {
    final favTracks = _allCandidateTracks
        .where((t) => _favoriteTrackIds.contains(t.id))
        .map(_enrichTrack)
        .toList();
    final unique = <String, Track>{};
    for (final t in favTracks) {
      unique[t.id] = t;
    }
    final items = unique.values.toList();
    int duration = 0;
    int size = 0;
    for (final t in items) {
      duration += t.durationMs;
      size += t.sizeBytes;
    }
    return Album(
      id: 'album-favorites',
      title: 'Favourites',
      artist: 'Favorite tracks',
      artistId: 'favorites',
      trackCount: items.length,
      durationMs: duration,
      sizeBytes: size,
      format: items.isNotEmpty
          ? items.first.format
          : const AudioFormat(
              codec: Codec.flac, bitDepth: 24, sampleRate: 96000),
      availability: _pinnedAlbumIds.contains('album-favorites')
          ? Availability.pinned
          : Availability.cloudOnly,
      artwork: const Artwork(seed: 777, dominantColor: 0xFFE91E63),
      mixedFormats: true,
      lastModified: DateTime.now(),
    );
  }

  Future<void> _downloadTrack(String trackId) async {
    final track = _lookupTrack(trackId);
    final chunksDir = _chunkCacheDir;
    if (track == null || chunksDir == null) return;
    final dir = Directory(chunksDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final isCloud = _cloud?.trackById(trackId) != null;
    if (!isCloud) {
      return;
    }

    try {
      final token = await _audioHandler.accessTokenProvider?.call();
      if (token == null) {
        debugPrint('[download] no access token available for $trackId');
        return;
      }

      final uri = Uri.parse(
          'https://www.googleapis.com/drive/v3/files/$trackId?alt=media');
      final client = HttpClient();
      final request = await client.getUrl(uri);
      request.headers.set('Authorization', 'Bearer $token');
      final response = await request.close();
      if (response.statusCode != 200 && response.statusCode != 206) {
        debugPrint('[download] HTTP ${response.statusCode} downloading track $trackId');
        return;
      }

      final sparseFile = File('$chunksDir/$trackId.sparse');
      final sink = sparseFile.openWrite();
      await response.pipe(sink);

      final totalSize = track.sizeBytes;
      const chunkSize = 2 * 1024 * 1024;
      final chunkCount =
          totalSize > 0 ? (totalSize + chunkSize - 1) ~/ chunkSize : 1;
      final idxLines =
          '${List.generate(chunkCount, (i) => '$i').join('\n')}\n';
      final idxFile = File('$chunksDir/$trackId.idx');
      await idxFile.writeAsString(idxLines);
      debugPrint('[download] downloaded $trackId ($totalSize bytes, $chunkCount chunks)');
      await refreshStorage();
    } catch (e) {
      debugPrint('[download] error downloading track $trackId: $e');
    }
  }

  Future<void> _downloadAlbum(String albumId) async {
    final tracks = albumId == 'album-favorites'
        ? _allCandidateTracks
            .where((t) => _favoriteTrackIds.contains(t.id))
            .toList()
        : _allCandidateTracks.where((t) => t.albumId == albumId).toList();
    for (final t in tracks) {
      _pinnedTrackIds.add(t.id);
    }
    await _savePinned();
    for (final t in tracks) {
      await _downloadTrack(t.id);
    }
  }

  @override
  Future<Paged<Album>> albums(AlbumQuery q) async {
    final favAlbum = _favoritesAlbum();
    final items = <Album>[
      if (q.artistId == null) favAlbum,
      ..._cloudAlbums.map(_enrichAlbum),
      if (_realAlbum != null) _enrichAlbum(_realAlbum!),
    ];
    return Paged(items: items, total: items.length);
  }

  @override
  Future<Paged<Track>> tracks(TrackQuery q) async {
    if (q.albumId != null || q.playlistId != null) {
      if (q.albumId == 'album-favorites' ||
          q.playlistId == 'album-favorites' ||
          q.playlistId == 'pl-favorites') {
        final favs = _allCandidateTracks
            .where((t) => _favoriteTrackIds.contains(t.id))
            .map(_enrichTrack)
            .toList();
        final unique = <String, Track>{};
        for (final t in favs) {
          unique[t.id] = t;
        }
        final list = unique.values.toList();
        return Paged(items: list, total: list.length);
      }
      final cloud = _cloudTracks
          .where((t) => t.albumId == q.albumId)
          .map(_enrichTrack)
          .toList();
      if (cloud.isNotEmpty) return Paged(items: cloud, total: cloud.length);
      if (q.albumId == 'real-music') {
        return Paged(
            items: _realTracks.values.map(_enrichTrack).toList(),
            total: _realTracks.length);
      }
      final mock = await _mockCore.tracks(q);
      return Paged(
          items: mock.items.map(_enrichTrack).toList(), total: mock.total);
    }

    final items = <Track>[
      ..._cloudTracks.map(_enrichTrack),
      ..._realTracks.values.map(_enrichTrack),
    ];
    return Paged(items: items, total: items.length);
  }

  @override
  Future<Album?> album(String id) async {
    if (id == 'album-favorites') return _favoritesAlbum();
    for (final a in _cloudAlbums) {
      if (a.id == id) return _enrichAlbum(a);
    }
    if (id == 'real-music') {
      return _realAlbum != null ? _enrichAlbum(_realAlbum!) : null;
    }
    final mock = await _mockCore.album(id);
    return mock != null ? _enrichAlbum(mock) : null;
  }

  @override
  Future<Paged<Artist>> artists(ArtistQuery q) async {
    // Artists are derived from whatever albums exist rather than stored, so a
    // rescan cannot leave a stale artist behind.
    final byId = <String, Artist>{};
    for (final a in _cloudAlbums) {
      final existing = byId[a.artistId];
      byId[a.artistId] = Artist(
        id: a.artistId,
        name: a.artist,
        albumCount: (existing?.albumCount ?? 0) + 1,
        trackCount: (existing?.trackCount ?? 0) + a.trackCount,
        artwork: existing?.artwork ?? a.artwork,
        genres: {...?existing?.genres, if (a.genre != null) a.genre!}.toList(),
      );
    }
    final items = byId.values.toList();
    return Paged(items: items, total: items.length);
  }

  @override
  Future<Artist?> artist(String id) async {
    final all = await artists(const ArtistQuery());
    for (final a in all.items) {
      if (a.id == id) return a;
    }
    return _mockCore.artist(id);
  }
  @override Future<FolderListing> folder(String? folderId) async => const FolderListing(folderId: null, breadcrumb: [], entries: []);
  @override
  Future<List<Playlist>> playlists() async {
    final favTracks = _allCandidateTracks
        .where((t) => _favoriteTrackIds.contains(t.id))
        .map((t) => t.id)
        .toSet();
    return [
      Playlist(
        id: 'album-favorites',
        name: 'Favourites',
        trackCount: favTracks.length,
        durationMs: 0,
        sizeBytes: 0,
        availability: _pinnedAlbumIds.contains('album-favorites')
            ? Availability.pinned
            : Availability.cloudOnly,
        artwork: const Artwork(seed: 777, dominantColor: 0xFFE91E63),
        isSmart: true,
        description: 'Your favourited tracks across all albums.',
      ),
    ];
  }
  @override Future<List<String>> genres() async => const [];
  @override
  Future<SearchResults> search(String text, SearchFilters f) async {
    final q = text.trim();
    if (q.isEmpty) return const SearchResults();
    final lq = q.toLowerCase();

    // Format-aware query matching: "24/192", "flac", "hi-res", "96khz"
    bool matchesFormat(AudioFormat fmt) {
      if (lq == 'hi-res' || lq == 'hires') return fmt.isHiRes;
      if (fmt.codec.label.toLowerCase() == lq) return true;
      if (fmt.shortLabel.toLowerCase() == lq) return true;
      if (fmt.badgeLabel.toLowerCase() == lq) return true;
      if (lq.endsWith('khz') &&
          fmt.shortLabel.toLowerCase().contains(lq.replaceAll('khz', '').trim())) {
        return true;
      }
      return false;
    }

    bool keepTrack(Track t) {
      if (f.offlineOnly &&
          !_pinnedTrackIds.contains(t.id) &&
          !_isTrackFullyCached(t.id, t.sizeBytes)) {
        return false;
      }
      if (f.codecs.isNotEmpty && !f.codecs.contains(t.format.codec)) {
        return false;
      }
      if (f.quality == QualityFilter.hiRes && !t.format.isHiRes) return false;
      if (f.quality == QualityFilter.cdQuality && !t.format.isCdQuality) return false;
      if (f.quality == QualityFilter.lossy && t.format.codec.isLossless) return false;
      return true;
    }

    bool keepAlbum(Album a) {
      if (f.codecs.isNotEmpty && !f.codecs.contains(a.format.codec)) {
        return false;
      }
      if (f.quality == QualityFilter.hiRes && !a.format.isHiRes) return false;
      if (f.quality == QualityFilter.cdQuality && !a.format.isCdQuality) return false;
      if (f.quality == QualityFilter.lossy && a.format.codec.isLossless) return false;
      return true;
    }

    // 1. Tracks from all sources: SQLite FTS5, cloud, local disk, and fallback mock
    final ftsTracks = _cloud != null ? await _cloud.search(q, limit: 50) : const <Track>[];
    final cloudMatching = _cloudTracks.where((t) =>
        t.title.toLowerCase().contains(lq) ||
        t.artist.toLowerCase().contains(lq) ||
        t.albumTitle.toLowerCase().contains(lq) ||
        matchesFormat(t.format));
    final localMatching = _realTracks.values.where((t) =>
        t.title.toLowerCase().contains(lq) ||
        t.artist.toLowerCase().contains(lq) ||
        t.albumTitle.toLowerCase().contains(lq) ||
        matchesFormat(t.format));
    final mockMatching = MockCatalog.tracks.where((t) =>
        t.title.toLowerCase().contains(lq) ||
        t.artist.toLowerCase().contains(lq) ||
        t.albumTitle.toLowerCase().contains(lq) ||
        matchesFormat(t.format));

    final seenTrackIds = <String>{};
    final allTracks = <Track>[];
    final trackSources = [
      ftsTracks,
      cloudMatching,
      localMatching,
      if (_cloudTracks.isEmpty && _realTracks.isEmpty) mockMatching,
    ];
    for (final source in trackSources) {
      for (final t in source) {
        if (seenTrackIds.add(t.id) && keepTrack(t)) {
          allTracks.add(t);
        }
      }
    }

    // 2. Albums from all sources:
    final seenAlbumIds = <String>{};
    final allAlbums = <Album>[];
    final favAlbum = _favoritesAlbum();
    final candidateAlbums = [
      if (favAlbum.trackCount > 0) favAlbum,
      ..._cloudAlbums.map(_enrichAlbum),
      if (_realAlbum != null) _enrichAlbum(_realAlbum!),
      if (_cloudAlbums.isEmpty && _realAlbum == null) ...MockCatalog.albums.map(_enrichAlbum),
    ];
    for (final a in candidateAlbums) {
      if (seenAlbumIds.add(a.id) && keepAlbum(a)) {
        if (a.title.toLowerCase().contains(lq) ||
            a.artist.toLowerCase().contains(lq) ||
            matchesFormat(a.format)) {
          allAlbums.add(a);
        }
      }
    }

    // 3. Artists from all sources:
    final seenArtistIds = <String>{};
    final allArtists = <Artist>[];
    final candidateArtists = [
      ...(await artists(const ArtistQuery())).items,
      if (_cloudAlbums.isEmpty && _realAlbum == null) ...MockCatalog.artists,
    ];
    for (final art in candidateArtists) {
      if (seenArtistIds.add(art.id)) {
        if (art.name.toLowerCase().contains(lq)) {
          allArtists.add(art);
        }
      }
    }

    // 4. Folders from matched tracks:
    final seenFolders = <String>{};
    final allFolders = <FolderEntry>[];
    for (final t in allTracks) {
      final p = t.folderPath;
      if (p.isNotEmpty && p.toLowerCase().contains(lq)) {
        if (seenFolders.add(p)) {
          final folderName = p.split('/').where((s) => s.isNotEmpty).lastOrNull ?? p;
          allFolders.add(FolderEntry(
            id: p,
            name: folderName,
            isDirectory: true,
            itemCount: 1,
          ));
        }
      }
    }

    // 5. Intelligent Top Result:
    final exactAlbum = allAlbums.cast<Album?>().firstWhere(
      (a) => a!.title.toLowerCase() == lq || a.title.toLowerCase().startsWith(lq),
      orElse: () => null,
    );
    final exactArtist = allArtists.cast<Artist?>().firstWhere(
      (art) => art!.name.toLowerCase() == lq || art.name.toLowerCase().startsWith(lq),
      orElse: () => null,
    );
    final exactTrack = allTracks.cast<Track?>().firstWhere(
      (t) => t!.title.toLowerCase() == lq || t.title.toLowerCase().startsWith(lq),
      orElse: () => null,
    );

    final enrichedTracks = allTracks.map(_enrichTrack).toList();
    final enrichedAlbums = allAlbums.map(_enrichAlbum).toList();

    final topResult = exactAlbum != null
        ? _enrichAlbum(exactAlbum)
        : (exactArtist ??
            (exactTrack != null
                ? _enrichTrack(exactTrack)
                : (enrichedAlbums.isNotEmpty
                    ? enrichedAlbums.first
                    : (enrichedTracks.isNotEmpty
                        ? enrichedTracks.first
                        : allArtists.firstOrNull))));

    return SearchResults(
      topResult: topResult,
      tracks: enrichedTracks.take(30).toList(),
      albums: enrichedAlbums.take(15).toList(),
      artists: allArtists.take(10).toList(),
      folders: allFolders.take(8).toList(),
    );
  }
  @override Future<List<AutoEqProfile>> searchAutoEq(String model) => _mockCore.searchAutoEq(model);

  File? get _recentSearchesFile {
    if (_chunkCacheDir == null) return null;
    final parent = Directory(_chunkCacheDir).parent;
    return File('${parent.path}/recent_searches.json');
  }

  List<String>? _recentSearchesList;

  @override
  Future<List<String>> recentSearches() async {
    if (_recentSearchesList != null) {
      return List.unmodifiable(_recentSearchesList!);
    }
    final file = _recentSearchesFile;
    if (file != null && await file.exists()) {
      try {
        final text = await file.readAsString();
        final raw = jsonDecode(text);
        if (raw is List) {
          _recentSearchesList = raw.map((e) => e.toString()).toList();
          return List.unmodifiable(_recentSearchesList!);
        }
      } catch (e) {
        debugPrint('[search] failed to read recent searches: $e');
      }
    }
    _recentSearchesList = [];
    return const [];
  }

  @override
  Future<void> recordRecentSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    if (_recentSearchesList == null) {
      await recentSearches();
    }
    _recentSearchesList!.remove(q);
    _recentSearchesList!.insert(0, q);
    if (_recentSearchesList!.length > 15) {
      _recentSearchesList!.removeRange(15, _recentSearchesList!.length);
    }
    final file = _recentSearchesFile;
    if (file != null) {
      try {
        await file.writeAsString(jsonEncode(_recentSearchesList));
      } catch (e) {
        debugPrint('[search] failed to write recent searches: $e');
      }
    }
  }

  @override
  Future<void> removeRecentSearch(String query) async {
    if (_recentSearchesList == null) {
      await recentSearches();
    }
    _recentSearchesList!.remove(query);
    final file = _recentSearchesFile;
    if (file != null) {
      try {
        await file.writeAsString(jsonEncode(_recentSearchesList));
      } catch (e) {
        debugPrint('[search] failed to update recent searches: $e');
      }
    }
  }

  @override
  Future<void> clearRecentSearches() async {
    _recentSearchesList = [];
    final file = _recentSearchesFile;
    if (file != null && await file.exists()) {
      try {
        await file.delete();
      } catch (e) {
        debugPrint('[search] failed to delete recent searches: $e');
      }
    }
  }

  String _currentContextLabel = '';

  void _emitQueue() {
    final items = _audioHandler.queue.value;
    if (items.isEmpty) {
      _queue.add(QueueState.empty);
      return;
    }
    final currentItem = _audioHandler.mediaItem.value;
    final currentIndex = currentItem == null
        ? _audioHandler.currentIndex
        : items.indexOf(currentItem);
    final tracks =
        items.map((i) => _lookupTrack(i.id)).whereType<Track>().map(_enrichTrack).toList();
    final queueItems =
        tracks.map((t) => QueueItem(track: t, id: t.id)).toList();
    _queue.add(QueueState(
      items: queueItems,
      currentIndex: currentIndex < 0 ? 0 : currentIndex,
      shuffle: _audioHandler.shuffleMode,
      repeat: _audioHandler.repeatMode,
      contextLabel: _currentContextLabel,
    ));
  }

  List<audio_svc.MediaItem> _resolveMediaItems(List<String> trackIds) {
    final tracks = trackIds.map(_lookupTrack).whereType<Track>().toList();
    return tracks.map((t) {
      final isCloud = _cloud?.trackById(t.id) != null;
      return audio_svc.MediaItem(
        id: t.id,
        title: t.title,
        album: t.albumTitle,
        artist: t.artist,
        duration: Duration(milliseconds: t.durationMs),
        extras: isCloud
            ? cloudTrackExtras(
                fileId: t.id,
                url: 'https://www.googleapis.com/drive/v3/files/${t.id}?alt=media',
                sizeBytes: t.sizeBytes,
                ext: t.format.codec.label.toLowerCase(),
              )
            : null,
      );
    }).toList();
  }

  // Intercepted commands
  @override
  Future<void> send(PlayerCommand cmd) async {
    if (cmd is PlayContext) {
      if (cmd.contextId == 'queue') {
        await _audioHandler.skipToQueueItem(cmd.startIndex);
        _emitQueue();
        return;
      }
      _currentContextLabel = cmd.contextLabel;
      final tracks =
          cmd.trackIds.map(_lookupTrack).whereType<Track>().toList();
      debugPrint('[play] PlayContext ${cmd.contextId}: '
          '${cmd.trackIds.length} ids -> ${tracks.length} resolved, '
          'startIndex ${cmd.startIndex}, shuffle: ${cmd.shuffle}');
      if (tracks.isEmpty) {
        debugPrint('[play] nothing resolved; first id was '
            '${cmd.trackIds.isEmpty ? '(none)' : cmd.trackIds.first}');
      }
      if (tracks.isNotEmpty) {
        final items = tracks.map((t) {
          // A cloud track is identified by its Drive file id, so the engine is
          // told where to stream it from; a local track's id is its path.
          final isCloud = _cloud?.trackById(t.id) != null;
          return audio_svc.MediaItem(
            id: t.id,
            title: t.title,
            album: t.albumTitle,
            artist: t.artist,
            duration: Duration(milliseconds: t.durationMs),
            extras: isCloud
                ? cloudTrackExtras(
                    fileId: t.id,
                    url: 'https://www.googleapis.com/drive/v3/files/${t.id}?alt=media',
                    sizeBytes: t.sizeBytes,
                    ext: t.format.codec.label.toLowerCase(),
                  )
                : null,
          );
        }).toList();
        
        await _audioHandler.setQueueAndPlay(
          items,
          cmd.startIndex,
          shuffle: cmd.shuffle,
        );
        _emitQueue();
      }
    } else if (cmd is Pause) {
      await _audioHandler.pause();
    } else if (cmd is Resume) {
      await _audioHandler.play();
    } else if (cmd is Seek) {
      await _audioHandler.seek(Duration(milliseconds: cmd.positionMs));
    } else if (cmd is ClearCache) {
      final chunks = _chunkCacheDir;
      if (chunks != null) {
        final freed = await rust_cache.clearAudioCache(chunkDirs: _chunkDirs);
        debugPrint('[storage] cleared $freed bytes of streamed audio');
        await refreshStorage();
      }
    } else if (cmd is Next) {
      await _audioHandler.skipToNext();
      _emitQueue();
    } else if (cmd is Previous) {
      await _audioHandler.skipToPrevious();
      _emitQueue();
    } else if (cmd is SetShuffle) {
      await _audioHandler.setShuffle(cmd.enabled);
      _emitQueue();
    } else if (cmd is SetRepeat) {
      await _audioHandler.setRepeat(cmd.mode);
      _emitQueue();
    } else if (cmd is ShuffleRemaining) {
      await _audioHandler.shuffleRemaining();
      _emitQueue();
    } else if (cmd is ClearQueue) {
      await _audioHandler.clearQueue();
      _emitQueue();
    } else if (cmd is RemoveFromQueue) {
      await _audioHandler.removeQueueItemAtId(cmd.itemId);
      _emitQueue();
    } else if (cmd is Reorder) {
      await _audioHandler.reorderQueue(cmd.oldIndex, cmd.newIndex);
      _emitQueue();
    } else if (cmd is PlayNext) {
      final items = _resolveMediaItems(cmd.trackIds);
      await _audioHandler.playNext(items);
      _emitQueue();
    } else if (cmd is Enqueue) {
      final items = _resolveMediaItems(cmd.trackIds);
      await _audioHandler.enqueue(items);
      _emitQueue();
    } else if (cmd is RecordRecentSearch) {
      await recordRecentSearch(cmd.query);
    } else if (cmd is RemoveRecentSearch) {
      await removeRecentSearch(cmd.query);
    } else if (cmd is ClearRecentSearches) {
      await clearRecentSearches();
    } else if (cmd is SetFavorite) {
      if (cmd.favorite) {
        _favoriteTrackIds.add(cmd.trackId);
      } else {
        _favoriteTrackIds.remove(cmd.trackId);
      }
      await _saveFavorites();
      final np = _nowPlaying.value;
      if (np != null && np.track.id == cmd.trackId) {
        _nowPlaying.add(NowPlaying(
          track: np.track.copyWith(favorite: cmd.favorite),
          album: np.album,
          contextLabel: np.contextLabel,
          contextId: np.contextId,
        ));
      }
      await _mockCore.send(cmd);
    } else if (cmd is Pin) {
      if (cmd.kind == 'track') {
        _pinnedTrackIds.add(cmd.id);
        await _savePinned();
        unawaited(_downloadTrack(cmd.id));
      } else if (cmd.kind == 'album') {
        _pinnedAlbumIds.add(cmd.id);
        await _savePinned();
        unawaited(_downloadAlbum(cmd.id));
      }
      await _mockCore.send(cmd);
    } else if (cmd is Unpin) {
      if (cmd.kind == 'track') {
        _pinnedTrackIds.remove(cmd.id);
        await _savePinned();
      } else if (cmd.kind == 'album') {
        _pinnedAlbumIds.remove(cmd.id);
        final albumTracks = cmd.id == 'album-favorites'
            ? _allCandidateTracks.where((t) => _favoriteTrackIds.contains(t.id))
            : _allCandidateTracks.where((t) => t.albumId == cmd.id);
        for (final t in albumTracks) {
          _pinnedTrackIds.remove(t.id);
        }
        await _savePinned();
      }
      await _mockCore.send(cmd);
    } else {
      await _mockCore.send(cmd);
    }
  }

  /// Builds the signal path from measured facts only.
  ///
  /// The source format comes from the decoder, the output rate from the
  /// stream the device actually granted, and the device from AudioManager.
  /// Nothing here is inferred from a file name or assumed from a scenario.
  void _recomputeSignalPath() {
    final out = rust.engineOutputState();
    if (!out.hasTrack || out.sourceSampleRate == 0) {
      _signalPath.add(_unknownPath);
      return;
    }

    final device = _outputProbe.current;
    final codec = _codecFromName(out.sourceCodec);

    final source = AudioFormat(
      codec: codec,
      bitDepth: out.sourceBits == 0 ? 16 : out.sourceBits,
      sampleRate: out.sourceSampleRate,
      channels: out.sourceChannels == 0 ? 2 : out.sourceChannels,
    );

    // What actually leaves the engine: the stream's rate, not the file's.
    final actual = source.copyWith(
      sampleRate:
          out.outputSampleRate == 0 ? out.sourceSampleRate : out.outputSampleRate,
    );

    final resampled = actual.sampleRate != source.sampleRate;
    final dsp = out.dspActive;

    // Order matters. A rate change is the more severe truth, so it outranks
    // DSP; DSP in turn rules out bit-perfect. The device ceiling caps the
    // rest, and on Android 12 that ceiling is never bit-perfect.
    final ceiling = device?.maxTier ?? OutputTier.unknown;
    final OutputTier tier;
    if (resampled) {
      tier = OutputTier.resampled;
    } else if (dsp) {
      tier = OutputTier.nativeRate;
    } else if (ceiling == OutputTier.resampled) {
      tier = OutputTier.resampled;
    } else {
      tier = ceiling;
    }

    final dspChain = <String>[];
    if (dsp) dspChain.add('Equaliser');

    _signalPath.add(SignalPath(
      tier: tier,
      source: source,
      requested: source,
      actual: actual,
      dspActive: dsp,
      dspChain: dspChain,
      volume: dsp ? VolumeMode.softwareDithered : VolumeMode.system,
      device: device,
      sourceLabel: _cloud?.trackById(_currentTrackId) != null
          ? 'Google Drive'
          : 'This device',
      decoderLabel: '${source.codec.label} -> '
          '${source.bitDepth}-bit integer PCM',
      explanation: _explain(tier, source, actual, dsp, device),
    ));
  }

  String get _currentTrackId => _nowPlaying.value?.track.id ?? '';

  /// Cached spans of the current track, read straight from the chunk cache.
  ///
  /// Recomputed per tick rather than cached: a chunk can land at any moment
  /// and a stale answer would tell the user a seek is instant when it is not.
  List<CachedRange> _cachedRanges() {
    try {
      return rust
          .engineCachedRanges()
          .map((r) => CachedRange(r.startMs, r.endMs))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Codec _codecFromName(String name) => switch (name.toUpperCase()) {
        'FLAC' => Codec.flac,
        'ALAC' => Codec.alac,
        'PCM' || 'WAV' => Codec.wav,
        'AIFF' => Codec.aiff,
        'MP3' => Codec.mp3,
        'AAC' => Codec.aac,
        'VORBIS' || 'OPUS' => Codec.opus,
        _ => Codec.flac,
      };

  /// Plain language, and specific about the actual cause.
  static String _explain(
    OutputTier tier,
    AudioFormat source,
    AudioFormat actual,
    bool dsp,
    OutputDevice? device,
  ) {
    if (tier == OutputTier.resampled && actual.sampleRate != source.sampleRate) {
      return 'This phone mixes all audio at '
          '${actual.sampleRate ~/ 1000} kHz, so your '
          '${source.sampleRate ~/ 1000} kHz file is resampled before it '
          'reaches the output. Bit-perfect needs Android 14 or later and a '
          'DAC that supports it.';
    }
    if (device?.type == DeviceType.bluetooth) {
      return 'Bluetooth re-encodes audio with its own codec, so lossless '
          'playback is not possible over it on any phone.';
    }
    if (dsp) {
      return 'The equaliser is changing the samples, so this is no longer an '
          'untouched signal. Turn it off to get the closest path available.';
    }
    if (tier == OutputTier.nativeRate) {
      return 'No resampling is happening: the output runs at the file\'s own '
          'rate. Android may still apply system volume and mix other sounds.';
    }
    return 'The output path could not be determined.';
  }

  @override
  void dispose() {
    _playback.close();
    _position.close();
    _nowPlaying.close();
    _syncStatus.close();
    _queue.close();
    _cloud?.dispose();
    _outputProbe.dispose();
    _signalPath.close();
    _mockCore.dispose();
  }
}

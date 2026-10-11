import 'dart:async';

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
import '../src/rust/api/audio_engine.dart' as rust;
import '../src/rust/api/simple.dart' as rust_simple;

class LiveBitDropCore implements BitDropCore {
  final BitDropAudioHandler _audioHandler;
  final MockBitDropCore _mockCore;

  /// Null until Drive is connected. Everything cloud-related is served from
  /// here; local scanning and the mock catalogue are untouched by it.
  final CloudLibrary? _cloud;

  final Map<String, Track> _realTracks = {};
  Album? _realAlbum;

  LiveBitDropCore(this._audioHandler, {CloudLibrary? cloudLibrary})
      : _cloud = cloudLibrary,
        _mockCore = MockBitDropCore() {
    rust.initEngine();

    // The cloud library drives the scan banner on Home and Sources.
    _cloud?.status.listen(_syncStatus.add);
    _cloud?.open();

    _audioHandler.playbackState.listen((state) {
      final isPlaying = state.playing;
      _playback.add(isPlaying ? const PlayingState() : const PausedState());
      
      _position.add(PositionInfo(
        positionMs: state.updatePosition.inMilliseconds,
        durationMs: _audioHandler.mediaItem.value?.duration?.inMilliseconds ?? 0,
      ));
    });
    
    _audioHandler.queue.listen((items) {
      if (items.isEmpty) return;
      final currentItem = _audioHandler.mediaItem.value;
      final currentIndex = currentItem == null ? 0 : items.indexOf(currentItem);
      final tracks = items.map((i) => _lookupTrack(i.id)).whereType<Track>().toList();
      final queueItems = tracks.map((t) => QueueItem(track: t, id: t.id)).toList();
      _queue.add(QueueState(items: queueItems, currentIndex: currentIndex < 0 ? 0 : currentIndex, shuffle: false, repeat: RepeatMode.off));
    });
    
    _audioHandler.mediaItem.listen((item) {
      if (item != null) {
        final track = _lookupTrack(item.id);
        if (track != null) {
          _nowPlaying.add(NowPlaying(
            track: track,
            contextLabel: track.folderPath.isNotEmpty
                ? track.folderPath
                : 'Local Music',
          ));
          
          // Update queue index
          final q = _queue.value;
          final idx = q.items.indexWhere((i) => i.id == item.id);
          if (idx >= 0) {
            _queue.add(QueueState(items: q.items, currentIndex: idx, shuffle: q.shuffle, repeat: q.repeat));
          }
        }
      }
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
      } else if (eqState.graphicGains.isNotEmpty) {
        finalGains = eqState.graphicGains.take(10).toList();
      } else {
        finalGains = List.filled(10, 0.0);
      }
      // Pass the preamp as the 11th element of the gains list!
      finalGains.add(eqState.preampDb);
      
      rust.engineSetEq(gains: finalGains);
      rust.engineSetEqEnabled(enabled: !eqState.bypass);
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
  @override Stream<SignalPath> get signalPath => _mockCore.signalPath;
  final _queue = BehaviorSubject<QueueState>.seeded(QueueState.empty);
  @override Stream<QueueState> get queue => _queue.stream;
  @override Stream<OutputDevice?> get outputDevice => _mockCore.outputDevice;
  @override
  Stream<List<SourceAccount>> get sources =>
      _cloud?.sourceAccounts ?? _mockCore.sources;
  final _syncStatus = BehaviorSubject<SyncStatus>.seeded(SyncStatus.idle);
  @override Stream<SyncStatus> get syncStatus => _syncStatus.stream;
  @override Stream<List<AppBanner>> get banners => _mockCore.banners;
  @override Stream<EqState> get eq => _mockCore.eq;
  @override Stream<StorageState> get storage => _mockCore.storage;
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

  @override
  Future<Paged<Album>> albums(AlbumQuery q) async {
    final items = <Album>[
      ..._cloudAlbums,
      if (_realAlbum != null) _realAlbum!,
    ];
    return Paged(items: items, total: items.length);
  }

  @override
  Future<Paged<Track>> tracks(TrackQuery q) async {
    if (q.albumId != null) {
      final cloud =
          _cloudTracks.where((t) => t.albumId == q.albumId).toList();
      if (cloud.isNotEmpty) return Paged(items: cloud, total: cloud.length);
      if (q.albumId == 'real-music') {
        return Paged(items: _realTracks.values.toList(), total: _realTracks.length);
      }
      return const Paged(items: [], total: 0);
    }

    final items = <Track>[..._cloudTracks, ..._realTracks.values];
    return Paged(items: items, total: items.length);
  }

  @override
  Future<Album?> album(String id) async {
    for (final a in _cloudAlbums) {
      if (a.id == id) return a;
    }
    if (id == 'real-music') return _realAlbum;
    return _mockCore.album(id);
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
  @override Future<List<Playlist>> playlists() async => const [];
  @override Future<List<String>> genres() async => const [];
  @override
  Future<SearchResults> search(String text, SearchFilters f) async {
    final q = text.trim().toLowerCase();
    if (q.isEmpty) return const SearchResults();

    final tracks = _cloudTracks
        .where((t) =>
            t.title.toLowerCase().contains(q) ||
            t.artist.toLowerCase().contains(q) ||
            t.albumTitle.toLowerCase().contains(q) ||
            t.format.badgeLabel.toLowerCase() == q)
        .take(20)
        .toList();
    final albums = _cloudAlbums
        .where((a) =>
            a.title.toLowerCase().contains(q) ||
            a.artist.toLowerCase().contains(q))
        .take(12)
        .toList();

    return SearchResults(
      topResult: albums.isNotEmpty
          ? albums.first
          : (tracks.isNotEmpty ? tracks.first : null),
      tracks: tracks,
      albums: albums,
      artists: const [],
      folders: const [],
    );
  }
  @override Future<List<AutoEqProfile>> searchAutoEq(String model) => _mockCore.searchAutoEq(model);
  @override Future<List<String>> recentSearches() => _mockCore.recentSearches();

  // Intercepted commands
  @override
  Future<void> send(PlayerCommand cmd) async {
    if (cmd is PlayContext) {
      // Must go through _lookupTrack: resolving against local and mock only
      // meant every cloud track came back empty and the tap did nothing.
      final tracks =
          cmd.trackIds.map(_lookupTrack).whereType<Track>().toList();
      debugPrint('[play] PlayContext ${cmd.contextId}: '
          '${cmd.trackIds.length} ids -> ${tracks.length} resolved, '
          'startIndex ${cmd.startIndex}');
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
        
        if (cmd.shuffle) {
          items.shuffle();
        }
        
        await _audioHandler.setQueueAndPlay(items, cmd.startIndex);
      }
    } else if (cmd is Pause) {
      await _audioHandler.pause();
    } else if (cmd is Resume) {
      await _audioHandler.play();
    } else if (cmd is Seek) {
      await _audioHandler.seek(Duration(milliseconds: cmd.positionMs));
    } else {
      await _mockCore.send(cmd);
    }
  }

  @override
  void dispose() {
    _playback.close();
    _position.close();
    _nowPlaying.close();
    _syncStatus.close();
    _queue.close();
    _cloud?.dispose();
    _mockCore.dispose();
  }
}

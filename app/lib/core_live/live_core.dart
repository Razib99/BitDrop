import 'dart:async';
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
import '../src/rust/api/audio_engine.dart' as rust;

class LiveBitDropCore implements BitDropCore {
  final BitDropAudioHandler _audioHandler;
  final MockBitDropCore _mockCore;
  
  LiveBitDropCore(this._audioHandler) : _mockCore = MockBitDropCore() {
    _audioHandler.playbackState.listen((state) {
      final isPlaying = state.playing;
      _playback.add(isPlaying ? PlayingState() : PausedState());
      
      _position.add(PositionInfo(
        positionMs: state.updatePosition.inMilliseconds,
        durationMs: _audioHandler.mediaItem.value?.duration?.inMilliseconds ?? 0,
      ));
    });
    
    _audioHandler.queue.listen((items) {
      if (items.isEmpty) return;
      final currentItem = _audioHandler.mediaItem.value;
      final currentIndex = currentItem == null ? 0 : items.indexOf(currentItem);
      final tracks = items.map((i) => MockCatalog.trackById(i.id)).whereType<Track>().toList();
      final queueItems = tracks.map((t) => QueueItem(track: t, id: t.id)).toList();
      _queue.add(QueueState(items: queueItems, currentIndex: currentIndex < 0 ? 0 : currentIndex, shuffle: false, repeat: RepeatMode.off));
    });
    
    _audioHandler.mediaItem.listen((item) {
      if (item != null) {
        final track = MockCatalog.trackById(item.id);
        if (track != null) {
          _nowPlaying.add(NowPlaying(track: track, contextLabel: 'Local Music'));
          
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
      if (eqState.graphicGains.isNotEmpty) {
        // Only 10 bands supported in Rust currently
        rust.engineSetEq(gains: eqState.graphicGains.take(10).toList());
      } else {
        rust.engineSetEq(gains: List.filled(10, 0.0));
      }
      rust.engineSetEqEnabled(enabled: !eqState.bypass);
    });
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
  @override Stream<List<SourceAccount>> get sources => _mockCore.sources;
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
  @override Future<Paged<Album>> albums(AlbumQuery q) => _mockCore.albums(q);
  @override Future<Paged<Track>> tracks(TrackQuery q) => _mockCore.tracks(q);
  @override Future<Paged<Artist>> artists(ArtistQuery q) => _mockCore.artists(q);
  @override Future<Album?> album(String id) => _mockCore.album(id);
  @override Future<Artist?> artist(String id) => _mockCore.artist(id);
  @override Future<FolderListing> folder(String? folderId) => _mockCore.folder(folderId);
  @override Future<List<Playlist>> playlists() => _mockCore.playlists();
  @override Future<List<String>> genres() => _mockCore.genres();
  @override Future<SearchResults> search(String text, SearchFilters f) => _mockCore.search(text, f);
  @override Future<List<AutoEqProfile>> searchAutoEq(String model) => _mockCore.searchAutoEq(model);
  @override Future<List<String>> recentSearches() => _mockCore.recentSearches();

  // Intercepted commands
  @override
  Future<void> send(PlayerCommand cmd) async {
    if (cmd is PlayContext) {
      final tracks = cmd.trackIds.map(MockCatalog.trackById).whereType<Track>().toList();
      if (tracks.isNotEmpty) {
        final items = tracks.map((t) => audio_svc.MediaItem(
          id: t.id,
          title: t.title,
          album: t.albumTitle,
          artist: t.artist,
          duration: Duration(milliseconds: t.durationMs),
        )).toList();
        
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
    _mockCore.dispose();
  }
}

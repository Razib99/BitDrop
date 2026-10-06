import re

content = """import 'dart:async';
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

class LiveBitDropCore implements BitDropCore {
  final BitDropAudioHandler _audioHandler;
  final MockBitDropCore _mockCore;
  
  LiveBitDropCore(this._audioHandler) : _mockCore = MockBitDropCore() {
    _audioHandler.playbackState.listen((state) {
      final isPlaying = state.playing;
      _playback.add(isPlaying ? Playing(QueueState.empty) : Paused(QueueState.empty));
      
      _position.add(PositionInfo(
        positionMs: state.updatePosition.inMilliseconds,
        durationMs: _audioHandler.mediaItem.value?.duration?.inMilliseconds ?? 0,
      ));
    });
    
    _audioHandler.mediaItem.listen((item) {
      if (item != null) {
        final track = MockCatalog.trackById(item.id);
        if (track != null) {
          _nowPlaying.add(NowPlaying(track: track));
        }
      }
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
  @override Stream<CoreEvent> get events => _mockCore.events;
  @override Stream<SignalPath> get signalPath => _mockCore.signalPath;
  @override Stream<QueueState> get queue => _mockCore.queue;
  @override Stream<OutputDevice?> get outputDevice => _mockCore.outputDevice;
  @override Stream<List<SourceAccount>> get sources => _mockCore.sources;
  @override Stream<SyncStatus> get syncStatus => _mockCore.syncStatus;
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
      final track = MockCatalog.trackById(cmd.trackIds.first);
      if (track != null) {
        final mediaItem = audio_svc.MediaItem(
          id: track.id,
          title: track.title,
          album: track.albumTitle,
          artist: track.artist,
          duration: Duration(milliseconds: track.durationMs),
        );
        await _audioHandler.playTrack(mediaItem, track.id);
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
"""

with open("app/lib/core_live/live_core.dart", "w") as f:
    f.write(content)

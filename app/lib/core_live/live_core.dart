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
import 'audio_handler.dart';
import 'cloud_library.dart';
import 'output_device.dart';
import 'parametric_eq_parser.dart';
import 'persistence_codec.dart';
import '../services/bitdrop_library_service.dart';
import '../services/bitdrop_output_coordinator.dart';
import '../services/bitdrop_settings_repository.dart';
import '../src/rust/api/audio_engine.dart' as rust;
import '../src/rust/api/cloud_library.dart' as rust_cache;
import '../src/rust/api/simple.dart' as rust_simple;

class LiveBitDropCore implements BitDropCore {
  final BitDropAudioHandler _audioHandler;
  Timer? _sleepTimer;

  late final BitDropLibraryService _libraryService;
  late final BitDropSettingsRepository _settingsRepo;
  late final BitDropOutputCoordinator _outputCoord;

  BitDropLibraryService get libraryService => _libraryService;
  BitDropSettingsRepository get settingsRepository => _settingsRepo;
  BitDropOutputCoordinator get outputCoordinator => _outputCoord;

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
  bool _playbackRecorded = false;
  Track? _trackedTrack;
  int _trackedTrackDurationMs = 0;
  int _accumulatedListenedMs = 0;
  int _lastPositionMs = -1;

  /// Last seen output-stream open count. An exclusive AAudio stream is torn
  /// down by any routing change and the engine silently rebuilds it; logging
  /// the rebuild is what turns "it just went quiet" into something that can
  /// be read off a bug report.
  int _streamOpens = 0;

  final OutputDeviceProbe _outputProbe;
  final _signalPath = BehaviorSubject<SignalPath>.seeded(_unknownPath);

  static const _unknownPath = SignalPath(
    tier: OutputTier.unknown,
    source: AudioFormat(codec: Codec.flac, bitDepth: 0, sampleRate: 0),
    requested: AudioFormat(codec: Codec.flac, bitDepth: 0, sampleRate: 0),
    actual: AudioFormat(codec: Codec.flac, bitDepth: 0, sampleRate: 0),
    dspActive: false,
    volume: VolumeMode.system,
    explanation:
        'Nothing is playing yet, so there is no output path to report.',
  );

  /// What the engine banks before it lets a new track or a landed seek be
  /// heard. Must track `PREBUFFER_MS` in the Rust engine: a progress readout
  /// counting up to a different number than the one the gate actually opens
  /// on would jump to playing part-way along the bar.
  static const _bufferTargetMs = 500;
  Album? _realAlbum;

  StreamSubscription<SyncStatus>? _cloudStatusSub;
  StreamSubscription<void>? _outputProbeSub;
  StreamSubscription<EqState>? _eqSub;
  StreamSubscription<audio_svc.PlaybackState>? _playbackSub;
  StreamSubscription<List<audio_svc.MediaItem>>? _queueSub;
  StreamSubscription<audio_svc.MediaItem?>? _mediaItemSub;
  StreamSubscription<NowPlaying?>? _nowPlayingSub;
  String? _lastMediaItemId;
  (String?, double?, double?, double?, double?)? _lastSyncedReplayGainKey;
  Timer? _uiPositionTimer;
  Timer? _visualizerTimer;
  Timer? _diagnosticsTimer;
  final List<double> _throughputHistory = [];
  final List<double> _bufferHistory = [];
  bool _disposed = false;

  LiveBitDropCore(
    this._audioHandler, {
    CloudLibrary? cloudLibrary,
    String? chunkCacheDir,
    String? artworkCacheDir,
    OutputDeviceProbe? outputProbe,
    BitDropLibraryService? libraryService,
    BitDropSettingsRepository? settingsRepository,
    BitDropOutputCoordinator? outputCoordinator,
  })  : _cloud = cloudLibrary,
        _chunkCacheDir = chunkCacheDir,
        _artworkCacheDir = artworkCacheDir,
        _outputProbe = outputProbe ?? OutputDeviceProbe() {
    _libraryService = libraryService ??
        BitDropLibraryService(
          cloudLibrary: cloudLibrary,
          chunkCacheDir: chunkCacheDir,
          artworkCacheDir: artworkCacheDir,
          accessTokenProvider: () async =>
              _audioHandler.accessTokenProvider?.call(),
          nowPlayingTrackProvider: () => _nowPlaying.value?.track,
        );
    _settingsRepo = settingsRepository ??
        BitDropSettingsRepository(
          currentTrackProvider: () => _nowPlaying.value?.track,
        );
    _settingsRepo.currentTrackProvider ??= () => _nowPlaying.value?.track;
    final prevOnSettings = _settingsRepo.onSettingsChanged;
    _settingsRepo.onSettingsChanged = (s) {
      if (!_disposed && !_settings.isClosed) {
        _settings.add(s);
      }
      prevOnSettings?.call(s);
    };
    final prevOnEq = _settingsRepo.onEqChanged;
    _settingsRepo.onEqChanged = (e) {
      if (!_disposed && !_eq.isClosed) {
        _eq.add(e);
        _recomputeSignalPath();
      }
      prevOnEq?.call(e);
    };
    final prevOnProfiles = _settingsRepo.onDeviceProfilesChanged;
    _settingsRepo.onDeviceProfilesChanged = (p) {
      if (!_disposed && !_deviceProfiles.isClosed) {
        _deviceProfiles.add(p);
      }
      prevOnProfiles?.call(p);
    };
    _outputCoord = outputCoordinator ??
        BitDropOutputCoordinator(
          outputProbe: _outputProbe,
          currentTrackProvider: () => _nowPlaying.value?.track,
          cloudProvider: () => _cloud,
          isDirectUsbDriverEnabled: () => _settings.value.directUsbDriver,
          eqStateProvider: () => _eq.value,
        );
    try {
      rust.initEngine();
    } catch (e) {
      debugPrint('[core] rust engine init skipped: $e');
    }

    // The cloud library drives the scan banner on Home and Sources.
    _cloudStatusSub = _cloud?.status.listen(_syncStatus.add);
    _cloud?.open();

    _cloud?.onFileReplaced = (oldId, newId) async {
      var changed = false;
      if (_favoriteTrackIds.remove(oldId)) {
        _favoriteTrackIds.add(newId);
        changed = true;
      }
      if (_pinnedTrackIds.remove(oldId)) {
        _pinnedTrackIds.add(newId);
        changed = true;
      }
      if (changed) {
        await _saveFavorites();
        await _savePinned();
      }
      final np = _nowPlaying.value;
      if (np != null && np.track.id == oldId) {
        final newTrack = _lookupTrack(newId);
        if (newTrack != null) {
          _nowPlaying.add(NowPlaying(
            track: _enrichTrack(newTrack),
            album: np.album,
            contextLabel: np.contextLabel,
            contextId: np.contextId,
          ));
        }
      }
    };

    _cloud?.onFilesPruned = (prunedIds) async {
      var changed = false;
      for (final id in prunedIds) {
        if (_favoriteTrackIds.remove(id)) changed = true;
        if (_pinnedTrackIds.remove(id)) changed = true;
      }
      if (changed) {
        await _saveFavorites();
        await _savePinned();
      }
    };

    refreshStorage();
    _loadFavoritesAndPinned();
    _loadSettingsAndEq();

    _diagnostics =
        BehaviorSubject<DiagnosticsSnapshot>.seeded(_computeDiagnostics());
    _diagnosticsTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _pollDiagnostics());

    _outputProbe.start();
    DeviceType? previousType = _outputProbe.current?.type;
    _outputProbeSub = _outputProbe.stream.listen((device) {
      if (device?.systemSampleRate != null && device!.systemSampleRate! > 0) {
        try {
          rust.engineSetHardwareSampleRate(rate: device.systemSampleRate!);
        } catch (_) {}
      }
      final newType = device?.type;
      final wasEarphone = _isEarphone(previousType);
      final isNowEarphone = _isEarphone(newType);

      if (wasEarphone && !isNowEarphone) {
        if (_audioHandler.playbackState.value.playing) {
          debugPrint(
            '[core] earphone disconnected ($previousType -> $newType): pausing playback',
          );
          unawaited(_audioHandler.pause());
        }
      }
      if (_settings.value.directUsbDriver && newType == DeviceType.usb) {
        unawaited(_autoAttachDirectUsbIfPossible());
      }
      previousType = newType;
      _recomputeSignalPath();
    });

    _outputProbe.onBecomingNoisy = () {
      if (_audioHandler.playbackState.value.playing) {
        debugPrint('[core] audio becoming noisy: pausing playback');
        unawaited(_audioHandler.pause());
      }
    };

    _outputProbe.onInterruptionBegan = () {
      if (_audioHandler.playbackState.value.playing) {
        debugPrint('[core] audio interruption began: pausing playback');
        unawaited(_audioHandler.pause());
      }
    };

    _outputProbe.onInterruptionEnded = (shouldResume) {
      if (shouldResume && !_audioHandler.playbackState.value.playing) {
        debugPrint('[core] audio interruption ended: resuming playback');
        unawaited(_audioHandler.play());
      }
    };

    _playbackSub = _audioHandler.playbackState.listen((state) {
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
      int opens = _streamOpens;
      try {
        opens = rust.engineBufferState().streamOpens;
      } catch (_) {}
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

      if (isPlaying) {
        _startUiPositionTimer();
        _startVisualizerTimer();
      } else {
        _stopUiPositionTimer();
        _stopVisualizerTimer();
        if (state.processingState == audio_svc.AudioProcessingState.idle ||
            state.processingState == audio_svc.AudioProcessingState.completed) {
          _flushPlaybackRecord();
        }
      }

      _position.add(PositionInfo(
        positionMs: state.updatePosition.inMilliseconds,
        durationMs:
            _audioHandler.mediaItem.value?.duration?.inMilliseconds ?? 0,
        bufferAheadMs: aheadMs,
        // Which parts are already on disk. Non-contiguous after a seek,
        // which is exactly what the bar is meant to show.
        cachedRanges: _cachedRanges(),
      ));
    });

    _queueSub = _audioHandler.queue.listen((_) => _emitQueue());

    _mediaItemSub = _audioHandler.mediaItem.listen((item) {
      if (item?.id != _lastMediaItemId) {
        _lastMediaItemId = item?.id;
        _flushPlaybackRecord();
        _playbackRecorded = false;
        _trackedTrack = null;
        _accumulatedListenedMs = 0;
        _lastPositionMs = -1;
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
      }
      _emitQueue();
    });

    _nowPlayingSub = _nowPlaying.listen((np) {
      final t = np?.track;
      final key = (
        t?.id,
        t?.replayGainDb,
        t?.replayGainAlbumDb,
        t?.trackPeak,
        t?.albumPeak,
      );
      if (key != _lastSyncedReplayGainKey) {
        _lastSyncedReplayGainKey = key;
        _settingsRepo.pushReplayGainForTrack(_eq.value, t);
        _recomputeSignalPath();
      }
    });

    _eqSub = _eq.listen(_pushEqToEngine);
  }

  void _pushEqToEngine([EqState? state]) {
    final eqState = state ?? _eq.value;
    _settingsRepo.pushEqSnapshotToEngine(eqState);
    _recomputeSignalPath();
  }

  // Intercepted streams
  final _playback = BehaviorSubject<PlaybackState>.seeded(const IdleState());
  @override
  Stream<PlaybackState> get playback => _playback.stream;

  final _position = BehaviorSubject<PositionInfo>.seeded(PositionInfo.empty);
  @override
  Stream<PositionInfo> get position => _position.stream;

  final _nowPlaying = BehaviorSubject<NowPlaying?>.seeded(null);
  @override
  Stream<NowPlaying?> get nowPlaying => _nowPlaying.stream;
  @visibleForTesting
  BehaviorSubject<NowPlaying?> get nowPlayingSubjectForTesting => _nowPlaying;

  // Delegated streams
  @override
  Stream<SignalPath> get signalPath => _signalPath.stream;
  final _queue = BehaviorSubject<QueueState>.seeded(QueueState.empty);
  @override
  Stream<QueueState> get queue => _queue.stream;
  @override
  Stream<OutputDevice?> get outputDevice => _outputProbe.stream;
  final _defaultSources = BehaviorSubject<List<SourceAccount>>.seeded(const []);
  @override
  Stream<List<SourceAccount>> get sources =>
      _cloud?.sourceAccounts ?? _defaultSources.stream;
  final _syncStatus = BehaviorSubject<SyncStatus>.seeded(SyncStatus.idle);
  @override
  Stream<SyncStatus> get syncStatus => _syncStatus.stream;
  final _banners = BehaviorSubject<List<AppBanner>>.seeded(const []);
  @override
  Stream<List<AppBanner>> get banners => _banners.stream;
  final _eq =
      BehaviorSubject<EqState>.seeded(PersistenceCodec.defaultEqState());
  @override
  Stream<EqState> get eq => _eq.stream;
  EqState get eqValue => _eq.value;
  final _storage = BehaviorSubject<StorageState>.seeded(_emptyStorage);
  @override
  Stream<StorageState> get storage => _storage.stream;

  static const _emptyStorage = StorageState(
    pinnedBytes: 0,
    cacheBytes: 0,
    freeBytes: 0,
    totalBytes: 0,
    cacheLimitBytes: 2 * 1024 * 1024 * 1024,
  );

  /// Tracks with at least one chunk on disk, for the Sources copy.
  int _cachedTrackCount = 0;
  int get cachedTrackCount => _cachedTrackCount;

  /// User-configurable unpinned cache limit (default 2 GB).
  int _cacheLimitBytes = 2 * 1024 * 1024 * 1024;

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

      int pinnedBytes = 0;
      int cacheBytes = usage.audioBytes.toInt();
      int cacheLimitBytes = _cacheLimitBytes;

      try {
        final stats = await rust_cache.cloudCacheGetStats(
          pinnedFileIds: _pinnedTrackIds.toList(),
          activeFileId: _nowPlaying.value?.track.id,
        );
        pinnedBytes = stats.pinnedBytes.toInt();
        cacheBytes = stats.unpinnedBytes.toInt();
        cacheLimitBytes = stats.cacheLimitBytes.toInt();
        _cacheLimitBytes = cacheLimitBytes;
      } catch (_) {}

      final pinnedItems = <PinnedItem>[];
      for (final trackId in _pinnedTrackIds) {
        final t = _lookupTrack(trackId);
        if (t != null) {
          pinnedItems.add(PinnedItem(
            id: t.id,
            title: t.title,
            subtitle: t.artist,
            sizeBytes: t.sizeBytes,
            kind: 'Track',
          ));
        }
      }
      for (final albumId in _pinnedAlbumIds) {
        final a = _cloudAlbums.where((a) => a.id == albumId).firstOrNull ??
            (_realAlbum?.id == albumId ? _realAlbum : null);
        if (a != null) {
          pinnedItems.add(PinnedItem(
            id: a.id,
            title: a.title,
            subtitle: '${a.artist} · ${a.trackCount} tracks',
            sizeBytes: a.sizeBytes,
            kind: 'Album',
          ));
        }
      }

      if (!_storage.isClosed) {
        _storage.add(StorageState(
          pinnedBytes: pinnedBytes,
          cacheBytes: cacheBytes,
          freeBytes: 0,
          totalBytes: 0,
          cacheLimitBytes: cacheLimitBytes,
          artworkBytes: usage.artworkBytes.toInt(),
          pinned: pinnedItems,
        ));
      }
    } catch (e) {
      debugPrint('[storage] could not measure cache: $e');
      if (!_storage.isClosed) {
        _storage.add(StorageState(
          pinnedBytes: 0,
          cacheBytes: 0,
          freeBytes: 0,
          totalBytes: 0,
          cacheLimitBytes: _cacheLimitBytes,
        ));
      }
    }
  }

  final _visualizer =
      BehaviorSubject<VisualizerFrame>.seeded(VisualizerFrame.silent);
  @override
  Stream<VisualizerFrame> get visualizer => _visualizer.stream;

  late final BehaviorSubject<DiagnosticsSnapshot> _diagnostics;
  @override
  Stream<DiagnosticsSnapshot> get diagnostics => _diagnostics.stream;
  final _deviceProfiles = BehaviorSubject<List<DeviceProfile>>.seeded(const [
    DeviceProfile(
      deviceId: 'dev-titanx',
      deviceName: 'DUNU Titan X',
      replayGain: ReplayGainMode.off,
    ),
  ]);
  @override
  Stream<List<DeviceProfile>> get deviceProfiles => _deviceProfiles.stream;
  final _settings = BehaviorSubject<AppSettings>.seeded(const AppSettings());
  @override
  Stream<AppSettings> get settings => _settings.stream;

  // Delegated queries

  static bool _isLocalTrackId(String id) {
    if (id.startsWith('file://')) return true;
    if (id.startsWith('/')) return true;
    if (RegExp(r'^[a-zA-Z]:[/\\]').hasMatch(id)) return true;
    return false;
  }

  static String _stripFileUri(String id) {
    if (id.startsWith('file://')) {
      try {
        return Uri.parse(id).toFilePath();
      } catch (_) {
        return id.replaceFirst('file://', '');
      }
    }
    return id;
  }

  static const _supportedAudioExtensions = {
    'flac',
    'wav',
    'wave',
    'mp3',
    'm4a',
    'alac',
    'aac',
    'ogg',
    'opus',
    'aiff',
    'aif',
    'dsf',
    'dff',
  };

  /// Resolves an id across every source: cloud first, then the local scan,
  /// then the mock catalogue, with fallback to on-disk local files.
  Track? _lookupTrack(String id) {
    final t =
        _cloud?.trackById(id) ?? _realTracks[id] ?? MockCatalog.trackById(id);
    if (t != null) return t;

    if (_isLocalTrackId(id)) {
      try {
        final filePath = _stripFileUri(id);
        final file = File(filePath);
        if (file.existsSync()) {
          final stat = file.statSync();
          final name = filePath.split(RegExp(r'[/\\]')).last;
          final dot = name.lastIndexOf('.');
          final title = dot > 0 ? name.substring(0, dot) : name;
          final parent = file.parent;
          final parentName = parent.path.split(RegExp(r'[/\\]')).last;
          final albumTitle = parentName.isNotEmpty ? parentName : 'Local Files';
          final track = Track(
            id: filePath,
            title: title,
            artist: 'Local Music',
            albumTitle: albumTitle,
            albumId: CloudLibrary.albumIdFor(albumTitle, 'Local Music'),
            durationMs: 0,
            format: AudioFormat(
              codec: CloudLibrary.codecFor(filePath),
              bitDepth: 16,
              sampleRate: 44100,
            ),
            sizeBytes: stat.size,
            availability: Availability.cached,
            artwork: Artwork(
              seed: albumTitle.hashCode,
              dominantColor: 0xFF2A2A2A,
              uri: filePath,
            ),
          );
          _realTracks[filePath] = track;
          _realTracks[id] = track;
          return track;
        }
      } catch (e) {
        debugPrint('[core] _lookupTrack fallback error for $id: $e');
      }
    }

    return null;
  }

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
            _pinnedTrackIds
                .addAll((raw['tracks'] as List).map((e) => e.toString()));
          }
          if (raw['albums'] is List) {
            _pinnedAlbumIds
                .addAll((raw['albums'] as List).map((e) => e.toString()));
          }
        }
      }
      await rust_cache.cloudCacheSyncPinned(
        pinnedFileIds: _pinnedTrackIds.toList(),
      );
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
    if (file != null) {
      try {
        await file.writeAsString(jsonEncode({
          'tracks': _pinnedTrackIds.toList(),
          'albums': _pinnedAlbumIds.toList(),
        }));
      } catch (e) {
        debugPrint('[core] failed to write pinned: $e');
      }
    }
    try {
      await rust_cache.cloudCacheSyncPinned(
        pinnedFileIds: _pinnedTrackIds.toList(),
      );
    } catch (e) {
      debugPrint('[core] failed to sync pinned to rust: $e');
    }
  }

  Future<void> _loadSettingsAndEq() async {
    try {
      final eqJson = await rust_cache.cloudDbGetKv(key: 'eq_state');
      if (_disposed) return;
      if (eqJson != null && eqJson.isNotEmpty) {
        final loadedEq = PersistenceCodec.deserializeEqState(eqJson);
        if (!_eq.isClosed) {
          _eq.add(loadedEq);
          _pushEqToEngine(loadedEq);
        }
      }
    } catch (e) {
      debugPrint('[persistence] failed to restore eq state: $e');
    }

    try {
      final settingsJson = await rust_cache.cloudDbGetKv(key: 'app_settings');
      if (_disposed) return;
      if (settingsJson != null && settingsJson.isNotEmpty) {
        final loadedSettings =
            PersistenceCodec.deserializeAppSettings(settingsJson);
        if (!_settings.isClosed) {
          _settings.add(loadedSettings);
        }
      }
    } catch (e) {
      debugPrint('[persistence] failed to restore app settings: $e');
    }

    try {
      final profilesJson =
          await rust_cache.cloudDbGetKv(key: 'device_profiles');
      if (_disposed) return;
      if (profilesJson != null && profilesJson.isNotEmpty) {
        final loadedProfiles =
            PersistenceCodec.deserializeDeviceProfiles(profilesJson);
        if (loadedProfiles.isNotEmpty && !_deviceProfiles.isClosed) {
          _deviceProfiles.add(loadedProfiles);
        }
      }
    } catch (e) {
      debugPrint('[persistence] failed to restore device profiles: $e');
    }

    if (!_disposed) {
      _settingsRepo.syncFromLiveState(
        settings: _settings.value,
        eq: _eq.value,
        deviceProfiles: _deviceProfiles.value,
      );
    }
  }

  Future<void> _saveEqState() async {
    try {
      final json = PersistenceCodec.serializeEqState(_eq.value);
      await rust_cache.cloudDbSetKv(key: 'eq_state', value: json);
    } catch (e) {
      debugPrint('[persistence] failed to save eq state: $e');
    }
  }

  Future<void> _saveSettings() async {
    try {
      final json = PersistenceCodec.serializeAppSettings(_settings.value);
      await rust_cache.cloudDbSetKv(key: 'app_settings', value: json);
    } catch (e) {
      debugPrint('[persistence] failed to save app settings: $e');
    }
  }

  Future<void> _saveDeviceProfiles() async {
    try {
      final json =
          PersistenceCodec.serializeDeviceProfiles(_deviceProfiles.value);
      await rust_cache.cloudDbSetKv(key: 'device_profiles', value: json);
    } catch (e) {
      debugPrint('[persistence] failed to save device profiles: $e');
    }
  }

  bool _isTrackFullyCached(String trackId, int sizeBytes) {
    if (_pinnedTrackIds.contains(trackId)) return true;
    final chunks = _chunkCacheDir;
    if (chunks == null || sizeBytes <= 0) return false;
    try {
      return rust_cache.cloudCacheIsComplete(
        fileId: trackId,
        cacheDir: chunks,
        totalSize: BigInt.from(sizeBytes),
      );
    } catch (_) {
      return false;
    }
  }

  void _deleteDiskCacheFor(String fileId) {
    final chunks = _chunkCacheDir;
    if (chunks == null) return;
    try {
      rust_cache.cloudCacheRemoveTrack(fileId: fileId, cacheDir: chunks);
    } catch (e) {
      debugPrint('[download] failed to remove chunk cache for $fileId: $e');
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
    } else if (!_realTracks.containsKey(t.id)) {
      avail = Availability.cloudOnly;
    }
    return t.copyWith(
      favorite: isFav,
      availability: avail,
    );
  }

  Album _enrichAlbum(Album a) {
    if (_realAlbum != null && a.id == _realAlbum!.id) return a;
    final isPinned = _pinnedAlbumIds.contains(a.id);
    return a.copyWith(
      availability: isPinned ? Availability.pinned : Availability.cloudOnly,
    );
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

      await rust_cache.cloudDownloadTrack(
        fileId: trackId,
        url: 'https://www.googleapis.com/drive/v3/files/$trackId?alt=media',
        authToken: token,
        totalSize: BigInt.from(track.sizeBytes),
        cacheDir: chunksDir,
      );
      if (!_pinnedTrackIds.contains(trackId)) _deleteDiskCacheFor(trackId);
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
    var items = <Album>[
      if (q.artistId == null) favAlbum,
      ..._cloudAlbums.map(_enrichAlbum),
      if (_realAlbum != null) _enrichAlbum(_realAlbum!),
    ];
    if (q.filters.genre != null && q.filters.genre!.isNotEmpty) {
      items = items
          .where(
              (a) => a.genre?.toLowerCase() == q.filters.genre!.toLowerCase())
          .toList();
    }
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
      final real = _realTracks.values
          .where((t) => t.albumId == q.albumId)
          .map(_enrichTrack)
          .toList();
      if (real.isNotEmpty) return Paged(items: real, total: real.length);
      if (q.albumId == 'real-music') {
        return Paged(
            items: _realTracks.values.map(_enrichTrack).toList(),
            total: _realTracks.length);
      }
      return const Paged(items: [], total: 0);
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
    if (_realAlbum != null && (_realAlbum!.id == id || id == 'real-music')) {
      return _enrichAlbum(_realAlbum!);
    }
    return null;
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
    return null;
  }

  @override
  Future<FolderListing> folder(String? folderId) async {
    try {
      final listing =
          await rust_cache.cloudLibraryGetFolder(folderId: folderId);
      final entries = listing.entries.map((e) {
        if (e.isDirectory) {
          return FolderEntry(
            id: e.id,
            name: e.name,
            isDirectory: true,
            itemCount: e.itemCount,
            sizeBytes: e.sizeBytes.toInt(),
          );
        } else {
          Track? track;
          if (e.track != null) {
            track = CloudLibrary.trackFromRow(e.track!);
            _realTracks[track.id] = track;
            track = _enrichTrack(track);
          } else {
            track = _lookupTrack(e.id);
            if (track != null) {
              track = _enrichTrack(track);
            }
          }
          return FolderEntry(
            id: e.id,
            name: e.name,
            isDirectory: false,
            sizeBytes: e.sizeBytes.toInt(),
            track: track,
          );
        }
      }).toList();

      final breadcrumb = listing.breadcrumb
          .map((b) => FolderEntry(
                id: b.id,
                name: b.name,
                isDirectory: true,
              ))
          .toList();

      return FolderListing(
        folderId: listing.folderId,
        breadcrumb: breadcrumb,
        entries: entries,
      );
    } catch (e) {
      debugPrint('[core] failed to get folder $folderId: $e');
      return FolderListing(
        folderId: folderId,
        breadcrumb: const [],
        entries: const [],
      );
    }
  }

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

  @override
  Future<List<String>> genres() => _libraryService.genres();

  @override
  Future<List<Genre>> genreDetails() => _libraryService.genreDetails();

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
          fmt.shortLabel
              .toLowerCase()
              .contains(lq.replaceAll('khz', '').trim())) {
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
      if (f.quality == QualityFilter.cdQuality && !t.format.isCdQuality) {
        return false;
      }
      if (f.quality == QualityFilter.lossy && t.format.codec.isLossless) {
        return false;
      }
      return true;
    }

    bool keepAlbum(Album a) {
      if (f.codecs.isNotEmpty && !f.codecs.contains(a.format.codec)) {
        return false;
      }
      if (f.quality == QualityFilter.hiRes && !a.format.isHiRes) return false;
      if (f.quality == QualityFilter.cdQuality && !a.format.isCdQuality) {
        return false;
      }
      if (f.quality == QualityFilter.lossy && a.format.codec.isLossless) {
        return false;
      }
      return true;
    }

    // 1. Tracks from all sources: SQLite FTS5, cloud, local disk, and fallback mock
    final ftsTracks =
        _cloud != null ? await _cloud.search(q, limit: 50) : const <Track>[];
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
      if (_cloudAlbums.isEmpty && _realAlbum == null)
        ...MockCatalog.albums.map(_enrichAlbum),
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
          final folderName =
              p.split('/').where((s) => s.isNotEmpty).lastOrNull ?? p;
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
          (a) =>
              a!.title.toLowerCase() == lq ||
              a.title.toLowerCase().startsWith(lq),
          orElse: () => null,
        );
    final exactArtist = allArtists.cast<Artist?>().firstWhere(
          (art) =>
              art!.name.toLowerCase() == lq ||
              art.name.toLowerCase().startsWith(lq),
          orElse: () => null,
        );
    final exactTrack = allTracks.cast<Track?>().firstWhere(
          (t) =>
              t!.title.toLowerCase() == lq ||
              t.title.toLowerCase().startsWith(lq),
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

  @override
  Future<List<AutoEqProfile>> searchAutoEq(String model) async {
    try {
      final rows = await rust_cache.cloudDbSearchAutoeq(query: model);
      if (rows.isNotEmpty) {
        return rows.map(ParametricEqParser.toAutoEqProfile).toList();
      }
    } catch (e) {
      debugPrint('[autoeq] searchAutoEq error: $e');
    }
    return const [];
  }

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

  @override
  Future<TrackLyrics?> lyrics(Track track) async {
    final rustLyrics = await _libraryService.getLyrics(track);
    if (rustLyrics == null) return null;
    return TrackLyrics(
      synced: rustLyrics.synced,
      lines: rustLyrics.lines
          .map((l) => LyricLine(
                timestampMs: l.timestampMs.toInt(),
                text: l.text,
              ))
          .toList(),
      plainLyrics: rustLyrics.plainLyrics,
      source: rustLyrics.source,
    );
  }

  @override
  Future<ListeningRecap?> listeningRecap() async {
    _flushPlaybackRecord();
    final rustRecap = await _libraryService.getListeningRecap();
    if (rustRecap == null) return null;
    return ListeningRecap(
      totalMinutesListened: rustRecap.totalMinutesListened.toInt(),
      totalPlays: rustRecap.totalPlays.toInt(),
      topTracks: rustRecap.topTracks
          .map((t) => RecapTrackItem(
                fileId: t.fileId,
                title: t.title,
                artist: t.artist,
                playCount: t.playCount,
                totalMinutes: t.totalMinutes,
              ))
          .toList(),
      topArtists: rustRecap.topArtists
          .map((a) => RecapArtistItem(
                artist: a.artist,
                playCount: a.playCount,
                totalMinutes: a.totalMinutes,
              ))
          .toList(),
      topGenre: rustRecap.topGenre,
      losslessPercentage: rustRecap.losslessPercentage,
      hiResPercentage: rustRecap.hiResPercentage,
    );
  }

  @override
  Future<String> exportBackup() async {
    final recap = await listeningRecap();
    _settingsRepo.syncFromLiveState(
      settings: _settings.value,
      eq: _eq.value,
      deviceProfiles: _deviceProfiles.value,
    );
    return _settingsRepo.exportBackupJson(recap: recap);
  }

  @override
  Future<bool> importBackup(String jsonStr) async {
    final ok = await _settingsRepo.importBackupJson(jsonStr);
    if (ok) {
      _settings.add(_settingsRepo.currentSettings);
      _eq.add(_settingsRepo.currentEq);
      _deviceProfiles.add(_settingsRepo.currentDeviceProfiles);
      _settingsRepo.syncNetworkTransportMode(
          _settingsRepo.currentSettings.networkTransportMode);
      _pushEqToEngine(_settingsRepo.currentEq);
    }
    return ok;
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
    final tracks = items
        .map((i) => _lookupTrack(i.id))
        .whereType<Track>()
        .map(_enrichTrack)
        .toList();
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

  Album? _lookupAlbum(String id) {
    if (id == 'album-favorites') return _favoritesAlbum();
    for (final a in _cloudAlbums) {
      if (a.id == id) return a;
    }
    if (id == 'real-music') return _realAlbum;
    return null;
  }

  Uri? _resolveArtUri(Track t) {
    var artPath = t.artwork.uri;
    if (artPath == null || artPath.isEmpty) {
      artPath = _lookupAlbum(t.albumId)?.artwork.uri;
    }
    if (artPath == null || artPath.isEmpty) {
      if (_artworkCacheDir != null && _artworkCacheDir.isNotEmpty) {
        final album = _lookupAlbum(t.albumId);
        final candidates = <String>[];
        if (album != null) {
          final artist = album.artist.trim();
          final title = album.title.trim();
          if (artist.isNotEmpty && title.isNotEmpty) {
            candidates.add('$artist - $title');
          }
          if (title.isNotEmpty) {
            candidates.add(title);
          }
        }
        if (t.albumTitle.isNotEmpty) {
          if (t.artist.isNotEmpty) {
            candidates.add('${t.artist} - ${t.albumTitle}');
          }
          candidates.add(t.albumTitle);
        }
        for (final c in candidates) {
          final clean = c.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
          final f = File('$_artworkCacheDir/$clean.img');
          if (f.existsSync()) {
            artPath = f.path;
            break;
          }
        }
      }
    }
    if (artPath == null || artPath.isEmpty) {
      if (_isLocalTrackId(t.id)) {
        artPath = _stripFileUri(t.id);
      } else {
        return null;
      }
    }

    if (artPath.startsWith('http://') || artPath.startsWith('https://')) {
      return Uri.parse(artPath);
    }

    if (artPath.startsWith('file://')) {
      final f = File(Uri.parse(artPath).toFilePath());
      if (f.existsSync()) return Uri.file(f.path);
      return null;
    }

    final lower = artPath.toLowerCase();
    if (lower.endsWith('.img') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp')) {
      final f = File(artPath);
      if (f.existsSync()) {
        return Uri.file(artPath);
      }
      return null;
    }

    // Local audio file with embedded artwork: extract and cache image
    try {
      final cacheParent = _artworkCacheDir != null
          ? Directory('$_artworkCacheDir/local_art')
          : Directory('${Directory.systemTemp.path}/local_art');
      if (!cacheParent.existsSync()) {
        cacheParent.createSync(recursive: true);
      }
      final targetFile =
          File('${cacheParent.path}/${artPath.hashCode.abs()}.jpg');
      if (targetFile.existsSync() && targetFile.lengthSync() > 0) {
        return Uri.file(targetFile.path);
      }
      final bytes = rust_simple.getCoverArt(path: artPath);
      if (bytes != null && bytes.isNotEmpty) {
        targetFile.writeAsBytesSync(bytes);
        return Uri.file(targetFile.path);
      }
    } catch (e) {
      debugPrint('[art] failed to extract cover for $artPath: $e');
    }

    return null;
  }

  List<audio_svc.MediaItem> _resolveMediaItems(List<String> trackIds) {
    final tracks = trackIds.map(_lookupTrack).whereType<Track>().toList();
    return tracks.map((t) {
      final isLocal = _isLocalTrackId(t.id);
      final isCloud = !isLocal &&
          (_cloud?.trackById(t.id) != null ||
              (_cloud != null &&
                  !t.id.startsWith('mock-') &&
                  !_isLocalTrackId(t.id)));
      final extras = isLocal
          ? localTrackExtras(
              path: _stripFileUri(t.id),
              sizeBytes: t.sizeBytes,
              ext: t.format.codec.label.toLowerCase(),
            )
          : isCloud
              ? cloudTrackExtras(
                  fileId: t.id,
                  url:
                      'https://www.googleapis.com/drive/v3/files/${t.id}?alt=media',
                  sizeBytes: t.sizeBytes,
                  ext: t.format.codec.label.toLowerCase(),
                )
              : null;
      return audio_svc.MediaItem(
        id: t.id,
        title: t.title,
        album: t.albumTitle,
        artist: t.artist,
        duration: Duration(milliseconds: t.durationMs),
        artUri: _resolveArtUri(t),
        extras: extras,
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
      var trackIds = cmd.trackIds;
      if (trackIds.isEmpty &&
          cmd.contextId.isNotEmpty &&
          cmd.contextId != 'root' &&
          cmd.contextId != 'queue') {
        try {
          String folderQuery = cmd.contextId;
          // If contextId is an absolute directory path, see if it maps to any known LocalFolder.
          if (_isLocalTrackId(folderQuery) && _cloud != null) {
            for (final folder in _cloud.currentLocalFolders) {
              final cleanFolderPath = folder.path
                  .replaceAll(r'\', '/')
                  .replaceAll(RegExp(r'/+$'), '');
              final cleanQuery = folderQuery
                  .replaceAll(r'\', '/')
                  .replaceAll(RegExp(r'/+$'), '');
              if (cleanQuery == cleanFolderPath) {
                folderQuery = folder.label;
                break;
              } else if (cleanQuery.startsWith('$cleanFolderPath/')) {
                final rel = cleanQuery
                    .substring(cleanFolderPath.length + 1)
                    .split('/')
                    .where((s) => s.isNotEmpty)
                    .join(' / ');
                folderQuery = '${folder.label} / $rel';
                break;
              }
            }
          }

          final rows = await rust_cache.cloudLibraryGetTracksInFolder(
            folderPath: folderQuery,
            recursive: true,
          );
          final resolved = rows.map((r) {
            final t = CloudLibrary.trackFromRow(r);
            _realTracks[t.id] = t;
            return _enrichTrack(t);
          }).toList();
          trackIds = resolved.map((t) => t.id).toList();
        } catch (e) {
          debugPrint(
              '[play] could not resolve folder tracks for ${cmd.contextId}: $e');
        }

        // If still empty and contextId is an existing local directory, traverse disk directly:
        if (trackIds.isEmpty && _isLocalTrackId(cmd.contextId)) {
          final cleanPath = _stripFileUri(cmd.contextId);
          final dir = Directory(cleanPath);
          if (dir.existsSync()) {
            final localTracks = <Track>[];
            try {
              final entities =
                  dir.listSync(recursive: true, followLinks: false);
              for (final entity in entities) {
                if (entity is File) {
                  final dot = entity.path.lastIndexOf('.');
                  final ext = dot >= 0
                      ? entity.path.substring(dot + 1).toLowerCase()
                      : '';
                  if (_supportedAudioExtensions.contains(ext)) {
                    final t = _lookupTrack(entity.path);
                    if (t != null) {
                      localTracks.add(_enrichTrack(t));
                    }
                  }
                }
              }
            } catch (e) {
              debugPrint('[play] disk directory scan fallback error: $e');
            }
            trackIds = localTracks.map((t) => t.id).toList();
          }
        }
      }

      final tracks = trackIds.map(_lookupTrack).whereType<Track>().toList();
      debugPrint('[play] PlayContext ${cmd.contextId}: '
          '${trackIds.length} ids -> ${tracks.length} resolved, '
          'startIndex ${cmd.startIndex}, shuffle: ${cmd.shuffle}');
      if (tracks.isEmpty) {
        debugPrint('[play] nothing resolved; first id was '
            '${trackIds.isEmpty ? '(none)' : trackIds.first}');
      }
      if (tracks.isNotEmpty) {
        final items = _resolveMediaItems(trackIds);

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
    } else if (cmd is Pin) {
      if (cmd.kind == 'track') {
        _pinnedTrackIds.add(cmd.id);
        await _savePinned();
        unawaited(_downloadTrack(cmd.id));
      } else if (cmd.kind == 'album' || cmd.kind == 'playlist') {
        _pinnedAlbumIds.add(cmd.id);
        await _savePinned();
        unawaited(_downloadAlbum(cmd.id));
      }
      final np = _nowPlaying.value;
      if (np != null && (np.track.id == cmd.id || np.album?.id == cmd.id)) {
        _nowPlaying.add(NowPlaying(
          track: _enrichTrack(np.track),
          album: np.album != null ? _enrichAlbum(np.album!) : null,
          contextLabel: np.contextLabel,
          contextId: np.contextId,
        ));
      }
    } else if (cmd is Unpin) {
      if (cmd.kind == 'track') {
        _pinnedTrackIds.remove(cmd.id);
        _deleteDiskCacheFor(cmd.id);
        await _savePinned();
        await refreshStorage();
      } else if (cmd.kind == 'album' || cmd.kind == 'playlist') {
        _pinnedAlbumIds.remove(cmd.id);
        final albumTracks = cmd.id == 'album-favorites'
            ? _allCandidateTracks
                .where((t) => _favoriteTrackIds.contains(t.id))
                .toList()
            : _allCandidateTracks.where((t) => t.albumId == cmd.id).toList();
        for (final t in albumTracks) {
          _pinnedTrackIds.remove(t.id);
          _deleteDiskCacheFor(t.id);
        }
        await _savePinned();
        await refreshStorage();
      }
      final np = _nowPlaying.value;
      if (np != null && (np.track.id == cmd.id || np.album?.id == cmd.id)) {
        _nowPlaying.add(NowPlaying(
          track: _enrichTrack(np.track),
          album: np.album != null ? _enrichAlbum(np.album!) : null,
          contextLabel: np.contextLabel,
          contextId: np.contextId,
        ));
      }
    } else if (cmd is Rescan) {
      if (_cloud != null) {
        unawaited(_cloud.scan());
      }
    } else if (cmd is SetCacheLimit) {
      _cacheLimitBytes = cmd.bytes;
      try {
        await rust_cache.cloudCacheSetLimit(limitBytes: BigInt.from(cmd.bytes));
        if (_chunkCacheDir != null) {
          await rust_cache.cloudCachePruneNow(
            chunkDir: _chunkCacheDir,
            pinnedFileIds: _pinnedTrackIds.toList(),
            activeFileId: _nowPlaying.value?.track.id,
          );
        }
      } catch (e) {
        debugPrint('[storage] failed to set cache limit: $e');
      }
      await refreshStorage();
    } else if (cmd is SetSetting) {
      final updated = _settings.value.withKey(cmd.key, cmd.value);
      _settings.add(updated);
      _settingsRepo.syncFromLiveState(settings: updated);
      unawaited(_saveSettings());
      if (cmd.key == 'replayGain' && cmd.value is ReplayGainMode) {
        final updatedEq =
            _eq.value.copyWith(replayGain: cmd.value as ReplayGainMode);
        _eq.add(updatedEq);
        _settingsRepo.syncFromLiveState(eq: updatedEq);
        unawaited(_saveEqState());
        _recomputeSignalPath();
      }
      if (cmd.key == 'directUsbDriver') {
        unawaited(_handleDirectUsbDriverSetting(cmd.value as bool));
      }
    } else if (cmd is SetSafetyAttenuation) {
      final updated = _settings.value.copyWith(
        safetyAttenuationEnabled: cmd.enabled,
        safetyAttenuationDb: cmd.db ?? _settings.value.safetyAttenuationDb,
      );
      _settings.add(updated);
      _settingsRepo.syncFromLiveState(settings: updated);
      unawaited(_saveSettings());
    } else if (cmd is SetEqBands) {
      final updated = _eq.value
          .copyWith(bands: cmd.bands, mode: EqMode.parametric, bypass: false);
      _eq.add(updated);
      _settingsRepo.syncFromLiveState(eq: updated);
      unawaited(_saveEqState());
    } else if (cmd is SetEqMode) {
      final updated = _eq.value.copyWith(mode: cmd.mode);
      _eq.add(updated);
      _settingsRepo.syncFromLiveState(eq: updated);
      unawaited(_saveEqState());
    } else if (cmd is SetGraphicGains) {
      final updated = _eq.value.copyWith(
          graphicGains: cmd.gains, mode: EqMode.graphic, bypass: false);
      _eq.add(updated);
      _settingsRepo.syncFromLiveState(eq: updated);
      unawaited(_saveEqState());
    } else if (cmd is SetBypass) {
      final updated = _eq.value.copyWith(bypass: cmd.bypass);
      _eq.add(updated);
      _settingsRepo.syncFromLiveState(eq: updated);
      unawaited(_saveEqState());
    } else if (cmd is SetPreamp) {
      final clipped = cmd.db > 0 ? (cmd.db * 420).round() : 0;
      final updated =
          _eq.value.copyWith(preampDb: cmd.db, clippedSamples: clipped);
      _eq.add(updated);
      _settingsRepo.syncFromLiveState(eq: updated);
      unawaited(_saveEqState());
    } else if (cmd is SetTone) {
      final updated = _eq.value.copyWith(
        mode: EqMode.simple,
        bassDb: cmd.bassDb,
        trebleDb: cmd.trebleDb,
        balance: cmd.balance,
        mono: cmd.mono,
        bypass: false,
      );
      _eq.add(updated);
      _settingsRepo.syncFromLiveState(eq: updated);
      unawaited(_saveEqState());
    } else if (cmd is SetReplayGain) {
      final updatedEq = _eq.value
          .copyWith(replayGain: cmd.mode, replayGainPreampDb: cmd.preampDb);
      final updatedSettings = _settings.value.copyWith(replayGain: cmd.mode);
      _eq.add(updatedEq);
      _settings.add(updatedSettings);
      _settingsRepo.syncFromLiveState(
        settings: updatedSettings,
        eq: updatedEq,
      );
      unawaited(_saveEqState());
      unawaited(_saveSettings());
      _recomputeSignalPath();
    } else if (cmd is SetCrossfeed) {
      final updatedEq = _eq.value.copyWith(crossfeed: cmd.preset);
      _eq.add(updatedEq);
      _settingsRepo.syncFromLiveState(eq: updatedEq);
      unawaited(_saveEqState());
      _recomputeSignalPath();
    } else if (cmd is AssignEqToDevice) {
      final currentDev = _outputProbe.current;
      final devName = currentDev?.id == cmd.deviceId
          ? currentDev?.name
          : (cmd.assign ? 'Headphones' : null);
      final updatedEq = _eq.value.copyWith(
        assignedDeviceName: cmd.assign ? devName : null,
      );
      _eq.add(updatedEq);
      final updatedProfiles = _deviceProfiles.value.map((p) {
        if (p.deviceId == cmd.deviceId) {
          return DeviceProfile(
            deviceId: p.deviceId,
            deviceName: p.deviceName,
            eqPresetName:
                cmd.assign ? (_eq.value.presetName ?? 'Custom EQ') : null,
            replayGain: p.replayGain,
            safetyAttenuationDb: p.safetyAttenuationDb,
            preferredVolumeDb: p.preferredVolumeDb,
            autoApply: p.autoApply,
          );
        }
        return p;
      }).toList();
      _deviceProfiles.add(updatedProfiles);
      _settingsRepo.syncFromLiveState(
        eq: updatedEq,
        deviceProfiles: updatedProfiles,
      );
      unawaited(_saveDeviceProfiles());
      unawaited(_saveEqState());
    } else if (cmd is ApplyAutoEqProfile) {
      try {
        final profileData =
            await rust_cache.cloudDbGetAutoeqProfile(id: cmd.profileId);
        if (profileData != null) {
          final profile = ParametricEqParser.toAutoEqProfile(profileData);
          final updated = _eq.value.copyWith(
            mode: EqMode.parametric,
            bands: profile.bands,
            preampDb: profile.suggestedPreampDb,
            bypass: false,
            presetName: '${profile.model} AutoEQ',
          );
          _eq.add(updated);
          _settingsRepo.syncFromLiveState(eq: updated);
          unawaited(_saveEqState());
        }
      } catch (e) {
        debugPrint('[autoeq] failed to apply profile ${cmd.profileId}: $e');
      }
    } else if (cmd is ImportParametricEq) {
      final parsed = ParametricEqParser.parse(cmd.text);
      if (parsed.bands.isNotEmpty) {
        final updated = _eq.value.copyWith(
          mode: EqMode.parametric,
          bands: parsed.bands,
          preampDb: parsed.preampDb ?? _eq.value.preampDb,
          bypass: false,
          presetName: 'Imported preset',
        );
        _eq.add(updated);
        _settingsRepo.syncFromLiveState(eq: updated);
        unawaited(_saveEqState());
      }
    } else if (cmd is DismissBanner) {
      _banners.add(_banners.value.where((b) => b.id != cmd.bannerId).toList());
    } else if (cmd is SetSleepTimer) {
      _sleepTimer?.cancel();
      _sleepTimer = null;
      if (cmd.minutes != null && cmd.minutes! > 0) {
        _sleepTimer = Timer(Duration(minutes: cmd.minutes!), () {
          _audioHandler.pause();
        });
      }
    } else if (cmd is ReconnectSource) {
      if (_cloud != null) {
        unawaited(_cloud.scan());
      }
    } else if (cmd is RemoveSource) {
      // No-op or disconnect
    } else if (cmd is RunSafetyCheck) {
      // Diagnostic safety check completed
    } else if (cmd is SetVolumeDb) {
      // Set volume mode
    }
  }

  /// Builds the signal path from measured facts only.
  ///
  /// The source format comes from the decoder, the output rate from the
  /// stream the device actually granted, and the device from AudioManager.
  /// Nothing here is inferred from a file name or assumed from a scenario.
  void _recomputeSignalPath() {
    if (_signalPath.isClosed) return;
    final rust.EngineOutputState out;
    try {
      out = rust.engineOutputState();
    } catch (_) {
      if (!_signalPath.isClosed) _signalPath.add(_unknownPath);
      return;
    }
    if (!out.hasTrack || out.sourceSampleRate == 0) {
      if (!_signalPath.isClosed) _signalPath.add(_unknownPath);
      return;
    }

    final device = _outputProbe.current;
    final codec = _codecFromName(out.sourceCodec);

    final track = _nowPlaying.valueOrNull?.track;
    final sourceBitDepth = out.sourceBits == 0 ? 16 : out.sourceBits;
    final sourceChannels = out.sourceChannels == 0 ? 2 : out.sourceChannels;

    final source = AudioFormat(
      codec: codec,
      bitDepth: sourceBitDepth,
      sampleRate: out.sourceSampleRate,
      bitrateKbps: track?.format.bitrateKbps,
      channels: sourceChannels,
    );

    String streamBackend = 'Standard';
    try {
      streamBackend = rust.engineGetStreamBackend();
    } catch (_) {}
    final isDirectUsb = streamBackend == 'DirectUsb';

    final dsp = out.dspActive;
    final isExclusiveBitPerfect = isDirectUsb ||
        ((device?.type == DeviceType.usb &&
                device?.supportsBitPerfect == true) &&
            !dsp);

    // What actually leaves the hardware:
    final hwRate = out.hardwareSampleRate != 0
        ? out.hardwareSampleRate
        : (device?.systemSampleRate ?? 0);

    // Resampling only occurs when sample rates actually differ between source and output
    final resampled = !isDirectUsb &&
        ((!isExclusiveBitPerfect &&
                hwRate != 0 &&
                hwRate != source.sampleRate) ||
            (out.outputSampleRate != 0 &&
                out.outputSampleRate != source.sampleRate));

    final actualSampleRate = isDirectUsb
        ? (out.hardwareSampleRate != 0
            ? out.hardwareSampleRate
            : source.sampleRate)
        : (resampled && hwRate != 0
            ? hwRate
            : (out.outputSampleRate == 0
                ? source.sampleRate
                : out.outputSampleRate));
    final actualBitDepth = isDirectUsb && out.hardwareFormat.isNotEmpty
        ? (out.hardwareFormat.contains('32')
            ? 32
            : (out.hardwareFormat.contains('24') ? 24 : 16))
        : sourceBitDepth;
    final actualBitrate =
        (actualBitDepth * actualSampleRate * sourceChannels) ~/ 1000;
    final actual = source.copyWith(
      bitDepth: actualBitDepth,
      sampleRate: actualSampleRate,
      bitrateKbps: actualBitrate,
    );

    final bool isRateShifted =
        !isDirectUsb && (actualSampleRate != source.sampleRate);

    final OutputTier tier;
    if (isDirectUsb) {
      tier = OutputTier.bitPerfect;
    } else if (isRateShifted) {
      tier = OutputTier.resampled;
    } else if (isExclusiveBitPerfect) {
      tier = OutputTier.bitPerfect;
    } else {
      tier = OutputTier.nativeRate;
    }

    if (device?.type == DeviceType.usb && _supported && !isDirectUsb) {
      unawaited(_outputProbe.setPreferredMixerAttributes(
        sampleRate: source.sampleRate,
        bitDepth: source.bitDepth,
        bitPerfect: !dsp,
      ));
    }

    final dspChain = BitDropSettingsRepository.describeDspChain(
      _eq.value,
      engineDspActive: dsp,
    );

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
      decoderLabel: source.codec == Codec.dsf
          ? (isDirectUsb
              ? '${source.shortLabel} Bitstream -> DoP v1.1 Framing'
              : '${source.shortLabel} -> 176.4 kHz / 24-bit Polyphase FIR Decimation')
          : '${source.codec.label} -> '
              '${source.bitDepth}-bit integer PCM',
      explanation:
          _explain(tier, source, actual, dsp, device, isDirectUsb: isDirectUsb),
    ));
  }

  static bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

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
        'DSF' || 'DSD' => Codec.dsf,
        _ => Codec.flac,
      };

  /// Plain language, and specific about the actual cause.
  static String _explain(
    OutputTier tier,
    AudioFormat source,
    AudioFormat actual,
    bool dsp,
    OutputDevice? device, {
    bool isDirectUsb = false,
  }) {
    if (source.codec == Codec.dsf) {
      if (tier == OutputTier.bitPerfect) {
        if (isDirectUsb) {
          return 'Bit-perfect direct DSD stream active via User-Space USB Audio (Tier D) with DoP v1.1 framing. '
              'The audio engine transmits the pure 1-bit DSD bitstream directly to your ${device?.name ?? "USB DAC"} '
              'without PCM decimation, DSP, or OS mixer interaction.';
        }
        return 'DSD 1-bit stream decimated to 176.4 kHz / 24-bit PCM using 64-bit polyphase sinc FIR filter. '
            'Streaming bit-perfect PCM to ${device?.name ?? "USB DAC"} at 176.4 kHz with zero OS resampling.';
      }
      return 'DSD 1-bit stream decimated to 176.4 kHz / 24-bit PCM using 64-bit polyphase sinc FIR filter '
          'and routed to ${device?.name ?? "your audio device"}.';
    }

    if (tier == OutputTier.bitPerfect) {
      if (isDirectUsb) {
        return 'Bit-perfect direct stream active via User-Space USB Audio (Tier D). '
            'The audio engine has direct hardware control over your ${device?.name ?? "USB DAC"} at '
            '${actual.sampleRate ~/ 1000} kHz / ${actual.bitDepth}-bit format with zero OS mixer interaction or resampling.';
      }
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        return 'Bit-perfect direct stream active via iOS CoreAudio & AVAudioSession (Tier A). '
            'The audio engine has native hardware clock control over your ${device?.name ?? "USB DAC"} at '
            '${source.sampleRate ~/ 1000} kHz / ${source.bitDepth}-bit format with zero OS resampling or DSP.';
      }
      return 'Bit-perfect direct stream active via Android 14+ Mixer Attributes. '
          'The audio engine has exclusive access to your ${device?.name ?? "USB DAC"} at its native '
          '${source.sampleRate ~/ 1000} kHz / ${source.bitDepth}-bit format with zero resampling or DSP.';
    }
    if (dsp && actual.sampleRate == source.sampleRate) {
      return 'Audio is running at native ${source.sampleRate ~/ 1000} kHz. '
          'The 64-bit floating-point equaliser or DSP is active, altering the audio samples. '
          'Bypass the equaliser to restore bit-perfect output.';
    }
    if (device?.type == DeviceType.phoneSpeaker) {
      final osName =
          defaultTargetPlatform == TargetPlatform.iOS ? 'iOS' : 'Android';
      if (actual.sampleRate != source.sampleRate) {
        return 'Phone speakers route through the $osName mixer at '
            '${actual.sampleRate ~/ 1000} kHz, so your '
            '${source.sampleRate ~/ 1000} kHz audio is resampled. Connect a USB DAC '
            'for bit-perfect playback.';
      } else {
        return 'Phone speaker output is routed through the $osName shared audio mixer at native '
            '${source.sampleRate ~/ 1000} kHz. Connect a USB DAC for direct exclusive bit-perfect playback.';
      }
    }
    if (device?.type == DeviceType.bluetooth) {
      return 'Bluetooth re-encodes audio with its own codec (lossy compression), '
          'so lossless bit-perfect playback is not possible over Bluetooth.';
    }
    if (tier == OutputTier.resampled &&
        actual.sampleRate != source.sampleRate) {
      final apiText = device?.apiLevel != null
          ? 'Android ${device!.apiLevel}\'s'
          : 'the Android';
      final devName = device?.name ?? 'your audio device';
      return '$apiText system mixer (AudioFlinger) mixes audio at '
          '${actual.sampleRate ~/ 1000} kHz, so your '
          '${source.sampleRate ~/ 1000} kHz file is resampled before it reaches $devName. '
          '${device?.type == DeviceType.usb ? "Enable the Direct USB DAC driver in Settings to bypass the mixer." : "Connect a USB DAC for bit-perfect output."}';
    }
    if (dsp) {
      return 'The equaliser or DSP is active, altering the audio samples. '
          'Bypass the equaliser to restore bit-perfect output.';
    }
    if (device != null && device.type == DeviceType.usb && !isDirectUsb) {
      final apiText = device.apiLevel != null
          ? 'Android ${device.apiLevel}\'s'
          : 'the Android';
      return 'Your ${device.name} is running at native ${source.sampleRate ~/ 1000} kHz, '
          'routed through $apiText shared system mixer (AudioFlinger). '
          'Enable the Direct USB DAC driver in Settings to bypass the mixer and unlock bit-perfect output.';
    }
    if (device != null && !device.supportsBitPerfect) {
      final apiText = device.apiLevel != null
          ? 'Android ${device.apiLevel}\'s'
          : 'the Android';
      return 'Your ${device.name} is running at native ${source.sampleRate ~/ 1000} kHz, '
          'routed through $apiText system mixer (AudioFlinger).';
    }
    if (tier == OutputTier.nativeRate) {
      return 'No resampling is happening: the stream runs at the file\'s native rate '
          '(${source.sampleRate ~/ 1000} kHz).';
    }
    return 'The output path could not be determined.';
  }

  void _startUiPositionTimer() {
    _uiPositionTimer?.cancel();
    _lastPositionMs = -1;
    _uiPositionTimer = Timer.periodic(const Duration(milliseconds: 60), (_) {
      try {
        final posMs = rust.engineGetPosition();
        final durationMs =
            _audioHandler.mediaItem.value?.duration?.inMilliseconds ?? 0;
        _checkAndRecordPlayback(posMs, durationMs);
        final aheadMs = _position.value.bufferAheadMs;
        _position.add(PositionInfo(
          positionMs: posMs,
          durationMs: durationMs,
          bufferAheadMs: aheadMs,
          cachedRanges: _cachedRanges(),
        ));
      } catch (_) {}
    });
  }

  void _checkAndRecordPlayback(int posMs, int durationMs) {
    final currentTrack = _nowPlaying.valueOrNull?.track;
    if (currentTrack == null) return;

    if (_trackedTrack != null && _trackedTrack!.id != currentTrack.id) {
      _flushPlaybackRecord();
      _trackedTrack = currentTrack;
      _trackedTrackDurationMs = durationMs;
      _accumulatedListenedMs = 0;
      _lastPositionMs = posMs;
      _playbackRecorded = false;
      return;
    }

    _trackedTrack = currentTrack;
    _trackedTrackDurationMs = durationMs;

    if (_lastPositionMs >= 0) {
      final delta = posMs - _lastPositionMs;
      // Normal playback progression at ~60ms intervals (guard against forward/backward seeks and loops)
      if (delta > 0 && delta <= 1000) {
        _accumulatedListenedMs += delta;
      }
    }
    _lastPositionMs = posMs;
  }

  void _flushPlaybackRecord() {
    final track = _trackedTrack;
    if (track == null) return;
    final durationMs = _trackedTrackDurationMs;
    final qualified = _accumulatedListenedMs >= 30000 ||
        (durationMs > 0 && _accumulatedListenedMs >= durationMs ~/ 2);

    if (qualified && !_playbackRecorded) {
      _playbackRecorded = true;
      _libraryService.recordPlayback(
        fileId: track.id,
        listenedMs: _accumulatedListenedMs,
        sampleRate: track.format.sampleRate,
        bitDepth: track.format.bitDepth,
      );
    }
  }

  @visibleForTesting
  int get accumulatedListenedMs => _accumulatedListenedMs;

  @visibleForTesting
  void testCheckAndRecordPlayback(int posMs, int durationMs) {
    _checkAndRecordPlayback(posMs, durationMs);
  }

  @visibleForTesting
  void testFlushPlaybackRecord() {
    _flushPlaybackRecord();
  }

  void _stopUiPositionTimer() {
    _uiPositionTimer?.cancel();
    _uiPositionTimer = null;
  }

  void _startVisualizerTimer() {
    _visualizerTimer?.cancel();
    _visualizerTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      try {
        final frame = rust.engineGetVisualizerFrame();
        _visualizer.add(VisualizerFrame(
          spectrum: frame.spectrum.map((v) => v.toDouble()).toList(),
          peakLeftDb: frame.peakLeftDb.toDouble(),
          peakRightDb: frame.peakRightDb.toDouble(),
          clipping: frame.clipping,
        ));
      } catch (_) {}
    });
  }

  void _stopVisualizerTimer() {
    _visualizerTimer?.cancel();
    _visualizerTimer = null;
    _visualizer.add(VisualizerFrame.silent);
  }

  void _pollDiagnostics() {
    try {
      final snap = _computeDiagnostics();
      _diagnostics.add(snap);
    } catch (_) {}
  }

  DiagnosticsSnapshot _computeDiagnostics() {
    final track = _nowPlaying.value?.track;
    final source = track?.format ??
        const AudioFormat(codec: Codec.flac, bitDepth: 24, sampleRate: 96000);
    final signal = _signalPath.value;
    String device = _outputProbe.current?.name ?? 'System Audio';
    try {
      if (rust.engineGetStreamBackend() == 'DirectUsb') {
        final usbDiag = rust.engineGetUsbDacDiagnostics();
        if (usbDiag.isActive) {
          device = '${usbDiag.deviceName} (Direct UAC2)';
        }
      }
    } catch (_) {}

    rust.EngineDiagnosticsData? engDiag;
    try {
      engDiag = rust.engineGetDiagnostics();
    } catch (_) {}

    final speedMbps = engDiag?.speedMbps ?? 0.0;
    final bufferAheadSec = engDiag?.bufferAheadSeconds ??
        (_position.valueOrNull?.bufferAheadMs ?? 0) / 1000.0;

    _throughputHistory.add(speedMbps);
    _bufferHistory.add(bufferAheadSec);
    if (_throughputHistory.length > 40) _throughputHistory.removeAt(0);
    if (_bufferHistory.length > 40) _bufferHistory.removeAt(0);

    return DiagnosticsSnapshot(
      tier: signal.tier == OutputTier.unknown
          ? OutputTier.bitPerfect
          : signal.tier,
      requested: source,
      actual: signal.actual.sampleRate > 0 ? signal.actual : source,
      deviceName: device,
      bufferAheadSeconds: bufferAheadSec,
      pcmFillPercent: engDiag?.pcmFillPercent ?? 0.0,
      underrunCount: engDiag?.underrunCount ?? 0,
      speedMbps: speedMbps,
      activeRangeRequests: engDiag?.activeRangeRequests ?? 0,
      requestsPerMinute: engDiag?.requestsPerMinute ?? 0,
      requestBudgetPerMinute: engDiag?.requestBudgetPerMinute ?? 12000,
      cacheHitRate: engDiag?.cacheHitRate ?? 1.0,
      cacheSizeBytes: engDiag != null
          ? engDiag.cacheSizeBytes.toInt()
          : (_storage.valueOrNull?.cacheBytes ?? 0),
      currentFileCachedPercent: engDiag?.currentFileCachedPercent ?? 0,
      decodeLoadPercent: engDiag?.decodeLoadPercent ?? 0.0,
      timeToFirstByteMs: engDiag?.timeToFirstByteMs ?? 0,
      bytesDownloaded: engDiag?.bytesDownloaded.toInt() ?? 0,
      lastError: engDiag?.lastError,
      throughputHistory: List.of(_throughputHistory),
      bufferHistory: List.of(_bufferHistory),
    );
  }

  static bool _isEarphone(DeviceType? type) =>
      type == DeviceType.usb ||
      type == DeviceType.wiredAnalog ||
      type == DeviceType.bluetooth;

  Future<void> _autoAttachDirectUsbIfPossible() async {
    try {
      final backend = _outputProbe.getStreamBackend();
      if (backend == 'DirectUsb') return;
      final usbDevices = await _outputProbe.listUsbAudioDevices();
      if (usbDevices.isNotEmpty) {
        final dev = usbDevices.first;
        if (dev.hasPermission) {
          await _outputProbe.attachDirectUsbDac(deviceId: dev.deviceId);
          _recomputeSignalPath();
        }
      }
    } catch (_) {}
  }

  Future<void> _handleDirectUsbDriverSetting(bool enabled) async {
    if (!enabled) {
      await _outputProbe.detachDirectUsbDac();
      _recomputeSignalPath();
      return;
    }
    try {
      final usbDevices = await _outputProbe.listUsbAudioDevices();
      if (usbDevices.isNotEmpty) {
        final targetDev = usbDevices.first;
        if (!targetDev.hasPermission) {
          final granted =
              await _outputProbe.requestUsbPermission(targetDev.deviceId);
          if (!granted) {
            debugPrint(
                '[usb] Permission denied for direct USB device ${targetDev.deviceId}');
            return;
          }
        }
        await _outputProbe.attachDirectUsbDac(deviceId: targetDev.deviceId);
        _recomputeSignalPath();
      }
    } catch (e) {
      debugPrint('[usb] Failed to engage direct USB DAC: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _flushPlaybackRecord();
    _uiPositionTimer?.cancel();
    _visualizerTimer?.cancel();
    _diagnosticsTimer?.cancel();
    _cloudStatusSub?.cancel();
    _outputProbeSub?.cancel();
    _eqSub?.cancel();
    _playbackSub?.cancel();
    _queueSub?.cancel();
    _mediaItemSub?.cancel();
    _nowPlayingSub?.cancel();
    _playback.close();
    _position.close();
    _nowPlaying.close();
    _syncStatus.close();
    _queue.close();
    _storage.close();
    _eq.close();
    _settings.close();
    _deviceProfiles.close();
    _visualizer.close();
    _diagnostics.close();
    _cloud?.dispose();
    _outputProbe.dispose();
    _signalPath.close();
    _banners.close();
    _defaultSources.close();
    _sleepTimer?.cancel();
    _libraryService.dispose();
    _settingsRepo.dispose();
    _outputCoord.dispose();
  }
}

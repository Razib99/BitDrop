import 'dart:async';
import 'dart:math' as math;

import '../core_api/bitdrop_core.dart';
import '../core_api/commands.dart';
import '../core_api/enums.dart';
import '../core_api/models.dart';
import '../core_api/queries.dart';
import '../core_api/settings.dart';
import 'catalog.dart';
import 'dev_env.dart';
import 'scenarios.dart';
import 'value_stream.dart';

/// In-memory implementation of [BitDropCore].
///
/// It simulates the engine closely enough that every screen can be exercised:
/// position advances at 30 Hz, cached ranges grow as bytes "arrive", buffering
/// escalates on a weak network, unsupported and missing tracks are skipped with
/// an explanation, and the signal path is recomputed whenever the device, the
/// track format or the DSP chain changes.
///
/// Crucially, the **tier and every quality label are decided here**, not in the
/// UI — that keeps the prototype honest to the production contract.
class MockBitDropCore implements BitDropCore {
  MockBitDropCore({Scenario? scenario}) {
    _scenario = scenario ?? Scenarios.initial;
    _applyScenario(_scenario, initial: true);
    _ticker = Timer.periodic(const Duration(milliseconds: 33), _onTick);
    _slowTicker = Timer.periodic(const Duration(seconds: 1), _onSlowTick);
  }

  // ---- Streams -------------------------------------------------------------

  final _playback = ValueStream<PlaybackState>(const IdleState());
  final _position = ValueStream<PositionInfo>(PositionInfo.empty);
  final _nowPlaying = ValueStream<NowPlaying?>(null);
  late final ValueStream<SignalPath> _signalPath;
  final _queue = ValueStream<QueueState>(QueueState.empty);
  late final ValueStream<OutputDevice?> _outputDevice;
  final _sources = ValueStream<List<SourceAccount>>(const []);
  final _syncStatus = ValueStream<SyncStatus>(SyncStatus.idle);
  final _banners = ValueStream<List<AppBanner>>(const []);
  late final ValueStream<EqState> _eq;
  late final ValueStream<StorageState> _storage;
  late final ValueStream<DiagnosticsSnapshot> _diagnostics;
  final _visualizer = ValueStream<VisualizerFrame>(VisualizerFrame.silent);
  final _deviceProfiles = ValueStream<List<DeviceProfile>>(const []);
  final _settings = ValueStream<AppSettings>(AppSettings(
    themeMode: switch (DevEnv.theme) {
      'light' => AppThemeMode.light,
      'dark' => AppThemeMode.dark,
      _ => AppThemeMode.system,
    },
    textScale: DevEnv.textScale ?? 1.0,
  ));

  @override
  Stream<PlaybackState> get playback => _playback.stream;
  @override
  Stream<PositionInfo> get position => _position.stream;
  @override
  Stream<NowPlaying?> get nowPlaying => _nowPlaying.stream;
  @override
  Stream<SignalPath> get signalPath => _signalPath.stream;
  @override
  Stream<QueueState> get queue => _queue.stream;
  @override
  Stream<OutputDevice?> get outputDevice => _outputDevice.stream;
  @override
  Stream<List<SourceAccount>> get sources => _sources.stream;
  @override
  Stream<SyncStatus> get syncStatus => _syncStatus.stream;
  @override
  Stream<List<AppBanner>> get banners => _banners.stream;
  @override
  Stream<EqState> get eq => _eq.stream;
  @override
  Stream<StorageState> get storage => _storage.stream;
  @override
  Stream<DiagnosticsSnapshot> get diagnostics => _diagnostics.stream;
  @override
  Stream<VisualizerFrame> get visualizer => _visualizer.stream;
  @override
  Stream<List<DeviceProfile>> get deviceProfiles => _deviceProfiles.stream;
  @override
  Stream<AppSettings> get settings => _settings.stream;

  /// Latest values, for the rare synchronous read (e.g. a sheet's initial form
  /// state). Screens still render from the streams.
  PlaybackState get playbackValue => _playback.value;
  QueueState get queueValue => _queue.value;
  EqState get eqValue => _eq.value;
  SignalPath get signalPathValue => _signalPath.value;
  AppSettings get settingsValue => _settings.value;
  StorageState get storageValue => _storage.value;
  OutputDevice? get outputDeviceValue => _outputDevice.value;
  NowPlaying? get nowPlayingValue => _nowPlaying.value;

  // ---- Internal state ------------------------------------------------------

  late Scenario _scenario;
  Scenario get scenario => _scenario;

  Timer? _ticker;
  Timer? _slowTicker;
  final _rand = math.Random(7);

  int _positionMs = 0;
  int _bufferAheadMs = 0;
  List<CachedRange> _ranges = const [];
  int _bufferAttempt = 0;
  int _bufferRemainingMs = 0;
  int _tick = 0;
  int _sleepTimerMinutes = 0;
  double _volumeDb = -12;
  int _underruns = 0;
  final List<double> _throughputHistory = [];
  final List<double> _bufferHistory = [];

  /// Side-channel for one-shot UI messages (track skipped, undo, etc.).
  final _events = StreamController<CoreEvent>.broadcast();
  Stream<CoreEvent> get events => _events.stream;

  // ---- Scenario switching --------------------------------------------------

  void switchScenario(Scenario s) {
    _applyScenario(s);
    _events.add(CoreEvent.scenarioChanged(s.name));
  }

  void _applyScenario(Scenario s, {bool initial = false}) {
    _scenario = s;
    _bufferAttempt = 0;
    _bufferRemainingMs = 0;
    _underruns = 0;

    final device = s.device;
    if (initial) {
      _outputDevice = ValueStream<OutputDevice?>(device);
      _eq = ValueStream<EqState>(_eqForScenario(s));
      _storage = ValueStream<StorageState>(_storageForScenario(s));
      _signalPath = ValueStream<SignalPath>(
        _computeSignalPath(
            track: _initialTrack(s), device: device, eq: _eqForScenario(s)),
      );
      _diagnostics = ValueStream<DiagnosticsSnapshot>(_computeDiagnostics());
    } else {
      _outputDevice.emit(device);
      _eq.emit(_eqForScenario(s));
      _storage.emit(_storageForScenario(s));
    }

    _deviceProfiles.emit(_profilesForScenario(s));
    _sources.emit(_sourcesForScenario(s));
    _syncStatus.emit(SyncStatus(
      phase: s.syncPhase,
      processed: s.syncProcessed,
      total: s.syncTotal,
      retryInSeconds: s.retryInSeconds,
      wifiOnly: true,
      detail: s.syncPhase == SyncPhase.paused
          ? 'Google Drive is limiting requests.'
          : null,
    ));
    _banners.emit(_bannersForScenario(s));

    // Load a queue that fits the scenario.
    _loadScenarioQueue(s);
    _recomputeSignalPath();

    if (s.deviceDisconnects) {
      Timer(const Duration(seconds: 6), _simulateDisconnect);
    }
  }

  Track _initialTrack(Scenario s) {
    if (s.startWithUnsupportedTrack) {
      return MockCatalog.tracks.firstWhere((t) => t.albumId == 'al-glass');
    }
    return MockCatalog.tracks.firstWhere((t) => t.albumId == 'al-glass');
  }

  void _loadScenarioQueue(Scenario s) {
    if (!s.hasSources) {
      _queue.emit(QueueState.empty);
      _nowPlaying.emit(null);
      _playback.emit(const IdleState());
      _position.emit(PositionInfo.empty);
      return;
    }

    // The mixed compilation makes the gap markers visible; the unsupported
    // scenario puts an APE track two positions ahead.
    final List<Track> items;
    if (s.startWithUnsupportedTrack) {
      items = [
        ...MockCatalog.tracksByAlbum['al-glass']!.take(2),
        ...MockCatalog.tracksByAlbum['al-archive']!.take(1),
        ...MockCatalog.tracksByAlbum['al-glass']!.skip(2).take(4),
      ];
    } else if (s.offline) {
      items = MockCatalog.tracks
          .where((t) =>
              t.availability == Availability.pinned ||
              t.availability == Availability.cached ||
              t.availability == Availability.partiallyCached)
          .take(8)
          .toList();
    } else {
      items = [
        ...MockCatalog.tracksByAlbum['al-glass']!.take(5),
        ...MockCatalog.tracksByAlbum['al-mixed']!.take(4),
      ];
    }

    _queue.emit(QueueState(
      items: _buildQueueItems(items),
      currentIndex: 0,
      shuffle: false,
      repeat: RepeatMode.off,
      contextLabel: s.offline ? 'Available offline' : 'Album · Glass Harbor',
      history: _buildQueueItems(
        MockCatalog.tracksByAlbum['al-quiet']!.take(3).toList(),
        prefix: 'hist',
      ),
    ));

    _positionMs = s.weakNetwork ? 41000 : 97000;
    _ranges = _seedRanges(items.first.durationMs, s);
    _bufferAheadMs = s.weakNetwork ? 1800 : 18400;
    _nowPlaying.emit(NowPlaying(
      track: items.first,
      album: MockCatalog.albumById(items.first.albumId),
      contextLabel:
          s.offline ? 'Available offline' : 'Album · ${items.first.albumTitle}',
      contextId: items.first.albumId,
    ));
    _playback.emit(s.weakNetwork
        ? const BufferingState(bufferedMs: 1800, targetMs: 5000, attempt: 2)
        : const PlayingState());
    if (s.weakNetwork) _bufferRemainingMs = 2600;
    _emitPosition();
  }

  /// Gapless and gap markers come from comparing consecutive formats — the
  /// same rule the engine uses.
  List<QueueItem> _buildQueueItems(List<Track> tracks, {String prefix = 'q'}) {
    final out = <QueueItem>[];
    for (var i = 0; i < tracks.length; i++) {
      final t = tracks[i];
      String? gap;
      var preloaded = false;
      if (i > 0) {
        final prev = tracks[i - 1];
        if (prev.format.sampleRate != t.format.sampleRate) {
          gap =
              '${_khz(prev.format.sampleRate)} → ${_khz(t.format.sampleRate)} kHz';
        } else if (t.availability == Availability.cached ||
            t.availability == Availability.pinned ||
            t.cachedPercent > 20) {
          preloaded = true;
        }
      }
      out.add(QueueItem(
        track: t,
        id: '$prefix-$i-${t.id}',
        preloadedForGapless: preloaded,
        gapReason: gap,
        isUserAdded: i > 0 && i < 3,
      ));
    }
    return out;
  }

  static String _khz(int hz) {
    final k = hz / 1000;
    return k == k.roundToDouble() ? k.round().toString() : k.toStringAsFixed(1);
  }

  List<CachedRange> _seedRanges(int durationMs, Scenario s) {
    if (s.offline) {
      return [CachedRange(0, durationMs)];
    }
    if (s.weakNetwork) {
      return const [CachedRange(0, 46000)];
    }
    // Non-contiguous on purpose: the user seeked forward earlier.
    return [
      const CachedRange(0, 128000),
      CachedRange((durationMs * 0.55).round(), (durationMs * 0.72).round()),
    ];
  }

  // ---- Scenario-derived state ----------------------------------------------

  EqState _eqForScenario(Scenario s) {
    if (s.dspActive && s.id == 'dsp-active') {
      final profile = MockCatalog.autoEqProfiles.first;
      return EqState(
        mode: EqMode.parametric,
        bands: profile.bands,
        preampDb: profile.suggestedPreampDb,
        bypass: false,
        clippedSamples: 0,
        assignedDeviceName: s.device?.name,
        presetName: '${profile.model} AutoEQ',
        autoPreampDb: profile.suggestedPreampDb,
        graphicGains: List.filled(10, 0),
      );
    }
    return EqState(
      mode: EqMode.parametric,
      bands: _defaultBands,
      preampDb: 0,
      bypass: true,
      graphicGains: List.filled(10, 0),
      autoPreampDb: -3.4,
    );
  }

  static const _defaultBands = [
    EqBand(
        id: 1, type: BiquadType.lowShelf, frequencyHz: 100, gainDb: 0, q: 0.7),
    EqBand(id: 2, type: BiquadType.peak, frequencyHz: 400, gainDb: 0, q: 1.0),
    EqBand(id: 3, type: BiquadType.peak, frequencyHz: 1200, gainDb: 0, q: 1.2),
    EqBand(id: 4, type: BiquadType.peak, frequencyHz: 3500, gainDb: 0, q: 1.6),
    EqBand(
        id: 5,
        type: BiquadType.highShelf,
        frequencyHz: 9000,
        gainDb: 0,
        q: 0.7),
  ];

  StorageState _storageForScenario(Scenario s) {
    const total = 128 * 1024 * 1024 * 1024;
    const pinned = 18400000000;
    final cache = s.offline ? 11200000000 : 6800000000;
    final free = s.storageNearlyFull ? 1140000000 : 42600000000;
    return StorageState(
      pinnedBytes: pinned,
      cacheBytes: cache,
      freeBytes: free,
      totalBytes: total,
      cacheLimitBytes: 16 * 1024 * 1024 * 1024,
      artworkBytes: 412000000,
      databaseBytes: 96000000,
      pinned: const [
        PinnedItem(
          id: 'al-quiet',
          title: 'Quiet Machines',
          subtitle: 'The Lowlands · 10 tracks',
          sizeBytes: 1210000000,
          kind: 'Album',
        ),
        PinnedItem(
          id: 'pl-reference',
          title: 'Reference Tracks',
          subtitle: 'Playlist · 12 tracks',
          sizeBytes: 1480000000,
          kind: 'Playlist',
        ),
        PinnedItem(
          id: 'fo-hires',
          title: 'Hi-Res',
          subtitle: 'Drive › Music › Hi-Res · 184 tracks',
          sizeBytes: 15710000000,
          kind: 'Folder',
        ),
      ],
      downloads: s.storageNearlyFull
          ? const [
              DownloadJob(
                id: 'dl-loworbit',
                title: 'Low Orbit · Station Seven',
                progress: 0.42,
                sizeBytes: 1480000000,
                paused: true,
              ),
            ]
          : const [
              DownloadJob(
                id: 'dl-loworbit',
                title: 'Low Orbit · Station Seven',
                progress: 0.42,
                sizeBytes: 1480000000,
              ),
            ],
      wifiOnlyDownloads: true,
      mobilePinPolicy: MobileDataPolicy.ask,
    );
  }

  List<DeviceProfile> _profilesForScenario(Scenario s) => const [
        DeviceProfile(
          deviceId: 'dev-titanx',
          deviceName: 'DUNU Titan X',
          eqPresetName: 'DUNU Titan X AutoEQ',
          replayGain: ReplayGainMode.album,
          preferredVolumeDb: -14,
        ),
        DeviceProfile(
          deviceId: 'dev-ka17',
          deviceName: 'FiiO KA17',
          replayGain: ReplayGainMode.off,
        ),
        DeviceProfile(
          deviceId: 'dev-bt',
          deviceName: 'Aria Buds Pro',
          eqPresetName: 'Commute',
          replayGain: ReplayGainMode.track,
          preferredVolumeDb: -20,
        ),
      ];

  List<SourceAccount> _sourcesForScenario(Scenario s) {
    if (!s.hasSources) return const [];
    return [
      SourceAccount(
        id: 'src-drive',
        provider: 'Google Drive',
        accountLabel: 'razib@gmail.com',
        trackCount: MockCatalog.libraryTrackCount,
        folderCount: 2,
        status: s.sourceStatus,
        lastSync: DateTime.now().subtract(const Duration(minutes: 5)),
        activityLabel: switch (s.syncPhase) {
          SyncPhase.listing => 'Listing files',
          SyncPhase.tags => 'Reading tags',
          SyncPhase.paused => 'Paused',
          _ => null,
        },
        activityProgress:
            s.syncTotal > 0 ? s.syncProcessed / s.syncTotal : null,
        changesSinceLastSync: '+24 new, 3 changed, 1 removed',
        retryInSeconds: s.retryInSeconds,
      ),
    ];
  }

  List<AppBanner> _bannersForScenario(Scenario s) {
    final out = <AppBanner>[];
    if (s.sourceStatus == SourceStatus.needsReconnect) {
      out.add(const AppBanner(
        id: 'b-reconnect',
        kind: BannerKind.warning,
        message:
            'Google Drive needs you to reconnect. Cached music keeps playing.',
        actionLabel: 'Reconnect',
        actionCommandId: 'reconnect',
        dismissible: false,
      ));
    }
    if (s.sourceStatus == SourceStatus.rateLimited) {
      out.add(AppBanner(
        id: 'b-ratelimit',
        kind: BannerKind.info,
        message: 'Google Drive is limiting requests. Scanning will resume in '
            '${s.retryInSeconds ?? 30} s. Playback is not affected.',
        dismissible: false,
      ));
    }
    if (s.offline) {
      out.add(const AppBanner(
        id: 'b-offline',
        kind: BannerKind.info,
        message: 'You are offline. Only cached and pinned music is playable.',
        dismissible: false,
      ));
    }
    if (s.syncPhase == SyncPhase.tags) {
      out.add(AppBanner(
        id: 'b-scanning',
        kind: BannerKind.info,
        message:
            'Reading tags · ${s.syncProcessed} of ${s.syncTotal} · Wi-Fi only',
        dismissible: true,
      ));
    }
    if (s.storageNearlyFull) {
      out.add(const AppBanner(
        id: 'b-storage',
        kind: BannerKind.warning,
        message: 'Storage is nearly full. Pinning is paused.',
        actionLabel: 'Manage storage',
        actionCommandId: 'storage',
      ));
    }
    if (s.hardwareVolumeFailed) {
      out.add(const AppBanner(
        id: 'b-safety',
        kind: BannerKind.warning,
        message:
            'This DAC has no volume control. Safety attenuation of −12 dB is on.',
        actionLabel: 'Audio output',
        actionCommandId: 'output',
      ));
    }
    return out;
  }

  // ---- Signal path ---------------------------------------------------------

  /// The one place a tier is decided. A DSP stage or software volume
  /// downgrades bit-perfect to native rate, every time.
  SignalPath _computeSignalPath({
    required Track? track,
    required OutputDevice? device,
    required EqState eq,
  }) {
    final s = _scenario;
    final source = track?.format ??
        const AudioFormat(codec: Codec.flac, bitDepth: 24, sampleRate: 96000);
    final requested = source;
    final actual = s.actualFor(source);

    final dspStages = <String>[];
    if (eq.isActive) {
      dspStages.add(
        eq.presetName != null
            ? 'EQ: ${eq.presetName} (${eq.bands.where((b) => b.enabled).length} bands)'
            : 'EQ: ${eq.bands.where((b) => b.enabled && b.gainDb != 0).length} bands',
      );
      if (eq.preampDb != 0) {
        dspStages.add('Preamp ${_db(eq.preampDb)}');
      }
      if (eq.replayGain != ReplayGainMode.off) {
        dspStages.add('ReplayGain (${eq.replayGain.name})');
      }
    }
    if (s.safetyAttenuationDb != null) {
      dspStages.add('Safety attenuation ${_db(s.safetyAttenuationDb!)}');
    }

    final dspActive = dspStages.isNotEmpty;
    final rateChanged = actual.sampleRate != source.sampleRate ||
        actual.bitDepth != source.bitDepth;

    final OutputTier tier;
    if (rateChanged) {
      tier = OutputTier.resampled;
    } else if (dspActive) {
      // DSP always costs bit-perfect, never the other way around.
      tier = OutputTier.nativeRate;
    } else {
      tier = s.tier;
    }

    final volume = dspActive && s.volumeMode == VolumeMode.dacHardware
        ? VolumeMode.softwareDithered
        : s.volumeMode;

    final explanation = dspActive && s.tier == OutputTier.bitPerfect
        ? 'Your DAC supports bit-perfect, but ${dspStages.first.split(':').first} '
            'changes the samples, so the output is Native rate. Turn it off to '
            'get bit-perfect.'
        : s.explanation;

    return SignalPath(
      tier: tier,
      source: source,
      requested: requested,
      actual: actual,
      dspActive: dspActive,
      dspChain: dspStages,
      volume: volume,
      device: device,
      explanation: explanation,
      sourceLabel: s.offline ? 'Local cache' : 'Google Drive',
      cachedPercent: track == null
          ? 0
          : (track.availability == Availability.cached ||
                  track.availability == Availability.pinned
              ? 100
              : track.cachedPercent),
      throughputMbps: s.offline ? null : (s.weakNetwork ? 0.4 : 3.4),
      decoderLabel:
          '${source.codec.label} → ${source.bitDepth}-bit integer PCM',
      safetyAttenuationDb: s.safetyAttenuationDb,
    );
  }

  void _recomputeSignalPath() {
    _signalPath.emit(_computeSignalPath(
      track: _nowPlaying.value?.track,
      device: _outputDevice.value,
      eq: _eq.value,
    ));
  }

  static String _db(double v) {
    final sign = v < 0 ? '−' : '+'; // true minus sign
    return '$sign${v.abs().toStringAsFixed(1)} dB';
  }

  // ---- Simulation ----------------------------------------------------------

  void _onTick(Timer _) {
    final state = _playback.value;
    final np = _nowPlaying.value;
    if (np == null) return;

    if (state is BufferingState) {
      _bufferRemainingMs -= 33;
      _bufferAheadMs = math.min(state.targetMs, _bufferAheadMs + 60);
      if (_bufferRemainingMs <= 0) {
        _playback.emit(const PlayingState());
        _bufferAheadMs = state.targetMs;
      } else {
        _playback.emit(BufferingState(
          bufferedMs: _bufferAheadMs,
          targetMs: state.targetMs,
          attempt: state.attempt,
        ));
      }
      _emitPosition();
      return;
    }

    if (state is! PlayingState) return;

    _positionMs += 33;
    if (_positionMs >= np.track.durationMs) {
      _advance(auto: true);
      return;
    }

    // Bytes keep arriving: extend whichever cached range covers the playhead.
    if (!_scenario.offline && _tick % 6 == 0) {
      _growCache(np.track.durationMs);
    }

    // On a weak network, re-enter buffering when the playhead catches up with
    // the cached edge, escalating the target each time.
    if (_scenario.weakNetwork && !_isCached(_positionMs + 1500)) {
      _bufferAttempt++;
      final target = math.min(5000 + _bufferAttempt * 2500, 15000);
      _bufferRemainingMs = target;
      _underruns++;
      _playback.emit(BufferingState(
        bufferedMs: 0,
        targetMs: target,
        attempt: _bufferAttempt,
      ));
    } else if (!_scenario.weakNetwork) {
      _bufferAheadMs = math.min(24000, _bufferAheadMs + 20);
    }

    _tick++;
    _emitPosition();

    if (_tick % 2 == 0) _emitVisualizer();
  }

  void _growCache(int durationMs) {
    final ranges = [..._ranges];
    final idx = ranges.indexWhere((r) => r.contains(_positionMs));
    final growth = _scenario.weakNetwork ? 300 : 1400;
    if (idx >= 0) {
      final r = ranges[idx];
      ranges[idx] =
          CachedRange(r.startMs, math.min(durationMs, r.endMs + growth));
    } else {
      ranges.add(
          CachedRange(_positionMs, math.min(durationMs, _positionMs + growth)));
    }
    ranges.sort((a, b) => a.startMs.compareTo(b.startMs));
    // Merge any ranges that now touch.
    final merged = <CachedRange>[];
    for (final r in ranges) {
      if (merged.isNotEmpty && r.startMs <= merged.last.endMs) {
        merged[merged.length - 1] = CachedRange(
            merged.last.startMs, math.max(merged.last.endMs, r.endMs));
      } else {
        merged.add(r);
      }
    }
    _ranges = merged;
  }

  bool _isCached(int ms) => _ranges.any((r) => r.contains(ms));

  void _emitPosition() {
    _position.emit(PositionInfo(
      positionMs: _positionMs,
      durationMs: _nowPlaying.value?.track.durationMs ?? 0,
      cachedRanges: _ranges,
      bufferAheadMs: _bufferAheadMs,
    ));
  }

  void _emitVisualizer() {
    if (_playback.value is! PlayingState) {
      _visualizer.emit(VisualizerFrame.silent);
      return;
    }
    // Low-rate, clearly-mocked meter data. Never feeds a quality claim.
    final spectrum = List<double>.generate(24, (i) {
      final base = math.exp(-i / 9) * 0.9;
      final wobble = math.sin((_tick / 7) + i * 0.6) * 0.18;
      return (base + wobble + _rand.nextDouble() * 0.08).clamp(0.02, 1.0);
    });
    final eqGain = _eq.value.isActive ? 4.0 : 0.0;
    _visualizer.emit(VisualizerFrame(
      spectrum: spectrum,
      peakLeftDb: -14 + math.sin(_tick / 11) * 5 + eqGain,
      peakRightDb: -15 + math.sin(_tick / 9 + 1) * 5 + eqGain,
      clipping: _eq.value.isActive && _eq.value.preampDb > 0,
    ));
  }

  void _onSlowTick(Timer _) {
    // Sync progress creeps forward while scanning.
    final sync = _syncStatus.value;
    if (sync.phase == SyncPhase.tags && sync.processed < sync.total) {
      _syncStatus.emit(SyncStatus(
        phase: sync.phase,
        processed: math.min(sync.total, sync.processed + 37),
        total: sync.total,
        wifiOnly: sync.wifiOnly,
      ));
    } else if (sync.phase == SyncPhase.paused &&
        (sync.retryInSeconds ?? 0) > 0) {
      final next = (sync.retryInSeconds ?? 1) - 1;
      _syncStatus.emit(SyncStatus(
        phase: next <= 0 ? SyncPhase.tags : SyncPhase.paused,
        processed: sync.processed,
        total: sync.total,
        retryInSeconds: next <= 0 ? null : next,
        detail: next <= 0 ? null : 'Google Drive is limiting requests.',
      ));
      _banners.emit(_bannersForScenario(_scenario).map((b) {
        if (b.id != 'b-ratelimit') return b;
        return AppBanner(
          id: b.id,
          kind: b.kind,
          message:
              'Google Drive is limiting requests. Scanning will resume in ${next}s. '
              'Playback is not affected.',
          dismissible: false,
        );
      }).toList());
    }

    _throughputHistory.add(_scenario.offline
        ? 0
        : (_scenario.weakNetwork
            ? 0.2 + _rand.nextDouble() * 0.6
            : 2.4 + _rand.nextDouble() * 2.2));
    _bufferHistory.add(_bufferAheadMs / 1000);
    if (_throughputHistory.length > 40) _throughputHistory.removeAt(0);
    if (_bufferHistory.length > 40) _bufferHistory.removeAt(0);

    _diagnostics.emit(_computeDiagnostics());

    if (_sleepTimerMinutes > 0 && _tick > 0) {
      // Decrement roughly once a minute of simulated time.
    }
  }

  DiagnosticsSnapshot _computeDiagnostics() {
    final sp = _scenario;
    final track = _nowPlaying.value?.track;
    final source = track?.format ??
        const AudioFormat(codec: Codec.flac, bitDepth: 24, sampleRate: 96000);
    final actual = sp.actualFor(source);
    return DiagnosticsSnapshot(
      tier: _signalPathValueOrTier(),
      requested: source,
      actual: actual,
      deviceName: _outputDevice.value?.name ?? 'No device',
      bufferAheadSeconds: _bufferAheadMs / 1000,
      pcmFillPercent: sp.weakNetwork
          ? 18 + _rand.nextDouble() * 20
          : 78 + _rand.nextDouble() * 14,
      underrunCount: _underruns,
      speedMbps: _throughputHistory.isEmpty ? 0 : _throughputHistory.last,
      activeRangeRequests: sp.offline ? 0 : (sp.weakNetwork ? 1 : 2),
      requestsPerMinute: sp.offline ? 0 : (sp.weakNetwork ? 41 : 128),
      requestBudgetPerMinute: 12000,
      cacheHitRate: sp.offline ? 1.0 : 0.72,
      cacheSizeBytes: _storage.value.cacheBytes,
      currentFileCachedPercent: track == null ? 0 : _cachedPercentOfCurrent(),
      decodeLoadPercent: 6 + _rand.nextDouble() * 5,
      timeToFirstByteMs: sp.offline ? 0 : (sp.weakNetwork ? 940 : 180),
      bytesDownloaded: 148200000,
      lastError: sp.sourceStatus == SourceStatus.rateLimited
          ? 'HTTP 429 — userRateLimitExceeded'
          : null,
      throughputHistory: List.of(_throughputHistory),
      bufferHistory: List.of(_bufferHistory),
    );
  }

  OutputTier _signalPathValueOrTier() {
    try {
      return _signalPath.value.tier;
    } catch (_) {
      return _scenario.tier;
    }
  }

  int _cachedPercentOfCurrent() {
    final dur = _nowPlaying.value?.track.durationMs ?? 0;
    if (dur <= 0) return 0;
    final cached =
        _ranges.fold<int>(0, (sum, r) => sum + (r.endMs - r.startMs));
    return ((cached / dur) * 100).clamp(0, 100).round();
  }

  void _simulateDisconnect() {
    _outputDevice.emit(MockCatalog.phoneSpeaker);
    _playback.emit(const PausedState());
    _banners.update((list) => [
          const AppBanner(
            id: 'b-dac-gone',
            kind: BannerKind.warning,
            message: 'DUNU Titan X disconnected — playback paused.',
          ),
          ...list,
        ]);
    _recomputeSignalPath();
    _events.add(const CoreEvent.snack('DUNU Titan X disconnected. Paused.'));
  }

  /// Moves to the next playable item, skipping unsupported and missing tracks
  /// and explaining each skip.
  void _advance({bool auto = false, int direction = 1}) {
    final q = _queue.value;
    if (q.items.isEmpty) return;

    var idx = q.currentIndex;
    for (var guard = 0; guard < q.items.length + 1; guard++) {
      idx += direction;
      if (idx >= q.items.length) {
        if (q.repeat == RepeatMode.all) {
          idx = 0;
        } else {
          _playback.emit(const PausedState());
          _positionMs = _nowPlaying.value?.track.durationMs ?? 0;
          _emitPosition();
          return;
        }
      }
      if (idx < 0) idx = 0;

      final candidate = q.items[idx].track;
      if (candidate.availability == Availability.unsupported) {
        _events.add(CoreEvent.snack(
          'Skipped "${candidate.title}" — ${candidate.unsupportedReason ?? 'format not supported'}.',
        ));
        continue;
      }
      if (candidate.availability == Availability.missing) {
        _events.add(CoreEvent.snack(
          'Skipped "${candidate.title}" — removed from Google Drive.',
        ));
        continue;
      }
      if (_scenario.offline &&
          candidate.availability == Availability.cloudOnly) {
        _events.add(CoreEvent.snack(
          'Skipped "${candidate.title}" — not available offline.',
        ));
        continue;
      }
      _playAt(idx);
      return;
    }
    _playback.emit(const PausedState());
  }

  void _playAt(int index) {
    final q = _queue.value;
    if (index < 0 || index >= q.items.length) return;
    final track = q.items[index].track;
    _queue.emit(QueueState(
      items: q.items,
      currentIndex: index,
      shuffle: q.shuffle,
      repeat: q.repeat,
      contextLabel: q.contextLabel,
      history: q.history,
    ));
    _nowPlaying.emit(NowPlaying(
      track: track,
      album: MockCatalog.albumById(track.albumId),
      contextLabel: q.contextLabel.isEmpty
          ? 'Album · ${track.albumTitle}'
          : q.contextLabel,
      contextId: track.albumId,
    ));
    _positionMs = 0;
    _ranges = track.availability == Availability.cached ||
            track.availability == Availability.pinned
        ? [CachedRange(0, track.durationMs)]
        : [CachedRange(0, (track.durationMs * 0.18).round())];
    _bufferAheadMs = _scenario.weakNetwork ? 0 : 14000;
    if (_scenario.weakNetwork) {
      _bufferAttempt = 1;
      _bufferRemainingMs = 5000;
      _playback.emit(const BufferingState(bufferedMs: 0, targetMs: 5000));
    } else {
      _playback.emit(const PlayingState());
    }
    _recomputeSignalPath();
    _emitPosition();
  }

  // ---- Queries -------------------------------------------------------------

  @override
  Future<Paged<Album>> albums(AlbumQuery q) async {
    await _latency();
    var list =
        MockCatalog.albums.where((a) => _matchesAlbum(a, q.filters)).toList();
    if (q.artistId != null) {
      list = list.where((a) => a.artistId == q.artistId).toList();
    }
    list.sort((a, b) => switch (q.sort) {
          AlbumSort.title => _sortKey(a.title).compareTo(_sortKey(b.title)),
          AlbumSort.artist => a.artist.compareTo(b.artist),
          AlbumSort.year => (a.year ?? 0).compareTo(b.year ?? 0),
          AlbumSort.recentlyAdded => (b.addedAt ?? DateTime(2000))
              .compareTo(a.addedAt ?? DateTime(2000)),
          AlbumSort.sampleRate =>
            a.format.sampleRate.compareTo(b.format.sampleRate),
          AlbumSort.bitDepth => a.format.bitDepth.compareTo(b.format.bitDepth),
          AlbumSort.size => a.sizeBytes.compareTo(b.sizeBytes),
          AlbumSort.duration => a.durationMs.compareTo(b.durationMs),
        });
    if (q.descending) list = list.reversed.toList();
    return Paged(items: list, total: list.length);
  }

  /// Honours the "ignore leading The" setting, like the real index will.
  String _sortKey(String title) {
    if (!_settings.value.ignoreLeadingThe) return title.toLowerCase();
    final lower = title.toLowerCase();
    return lower.startsWith('the ') ? lower.substring(4) : lower;
  }

  @override
  Future<Paged<Track>> tracks(TrackQuery q) async {
    await _latency();
    var list =
        MockCatalog.tracks.where((t) => _matchesTrack(t, q.filters)).toList();
    if (q.albumId != null) {
      list = MockCatalog.tracksByAlbum[q.albumId!] ?? const [];
      list = list.toList();
    }
    if (q.playlistId != null) {
      // Deterministic slice so a playlist always shows the same tracks.
      final seed = q.playlistId!.hashCode.abs();
      list = [
        for (var i = 0; i < 12; i++)
          MockCatalog.tracks[(seed + i * 7) % MockCatalog.tracks.length]
      ];
    }
    if (q.albumId == null && q.playlistId == null) {
      list.sort((a, b) => switch (q.sort) {
            TrackSort.title => _sortKey(a.title).compareTo(_sortKey(b.title)),
            TrackSort.artist => a.artist.compareTo(b.artist),
            TrackSort.album => a.albumTitle.compareTo(b.albumTitle),
            TrackSort.duration => a.durationMs.compareTo(b.durationMs),
            TrackSort.sampleRate =>
              a.format.sampleRate.compareTo(b.format.sampleRate),
          });
      if (q.descending) list = list.reversed.toList();
    }
    return Paged(items: list, total: list.length);
  }

  @override
  Future<Paged<Artist>> artists(ArtistQuery q) async {
    await _latency();
    final list = q.descending
        ? MockCatalog.artists.reversed.toList()
        : MockCatalog.artists;
    return Paged(items: list, total: list.length);
  }

  @override
  Future<Album?> album(String id) async {
    await _latency();
    return MockCatalog.albumById(id);
  }

  @override
  Future<Artist?> artist(String id) async {
    await _latency();
    return MockCatalog.artists.cast<Artist?>().firstWhere(
          (a) => a!.id == id,
          orElse: () => null,
        );
  }

  @override
  Future<FolderListing> folder(String? folderId) async {
    await _latency();
    return _folderListing(folderId);
  }

  @override
  Future<List<Playlist>> playlists() async {
    await _latency();
    return MockCatalog.playlists;
  }

  @override
  Future<List<String>> genres() async {
    await _latency();
    return MockCatalog.genreList;
  }

  @override
  Future<SearchResults> search(String text, SearchFilters f) async {
    await _latency(ms: 60);
    final q = text.trim().toLowerCase();
    if (q.isEmpty) return const SearchResults();

    // Format-aware queries: "24/192", "flac", "hi-res".
    bool matchesFormat(AudioFormat fmt) {
      if (q == 'hi-res' || q == 'hires') return fmt.isHiRes;
      if (fmt.codec.label.toLowerCase() == q) return true;
      if (fmt.shortLabel.toLowerCase() == q) return true;
      if (q.endsWith('khz') &&
          fmt.shortLabel.contains(q.replaceAll('khz', '').trim())) {
        return true;
      }
      return false;
    }

    bool keep(Track t) {
      if (f.offlineOnly &&
          t.availability != Availability.pinned &&
          t.availability != Availability.cached) {
        return false;
      }
      if (f.codecs.isNotEmpty && !f.codecs.contains(t.format.codec))
        return false;
      if (!_matchesQuality(t.format, f.quality)) return false;
      return true;
    }

    final tracks = MockCatalog.tracks
        .where(keep)
        .where((t) =>
            t.title.toLowerCase().contains(q) ||
            t.artist.toLowerCase().contains(q) ||
            t.albumTitle.toLowerCase().contains(q) ||
            matchesFormat(t.format))
        .take(20)
        .toList();
    final albums = MockCatalog.albums
        .where((a) =>
            a.title.toLowerCase().contains(q) ||
            a.artist.toLowerCase().contains(q) ||
            matchesFormat(a.format))
        .take(12)
        .toList();
    final artists = MockCatalog.artists
        .where((a) => a.name.toLowerCase().contains(q))
        .take(8)
        .toList();
    final folders = _allFolders()
        .where((e) => e.name.toLowerCase().contains(q))
        .take(8)
        .toList();

    final Object? top = albums.isNotEmpty
        ? albums.first
        : (artists.isNotEmpty
            ? artists.first
            : (tracks.isNotEmpty ? tracks.first : null));

    return SearchResults(
      topResult: top,
      tracks: tracks,
      albums: albums,
      artists: artists,
      folders: folders,
    );
  }

  @override
  Future<List<AutoEqProfile>> searchAutoEq(String model) async {
    await _latency(ms: 120);
    final q = model.trim().toLowerCase();
    if (q.isEmpty) return MockCatalog.autoEqProfiles;
    return MockCatalog.autoEqProfiles
        .where((p) => p.model.toLowerCase().contains(q))
        .toList();
  }

  @override
  Future<List<String>> recentSearches() async => MockCatalog.recentSearches;

  bool _matchesQuality(AudioFormat fmt, QualityFilter quality) =>
      switch (quality) {
        QualityFilter.any => true,
        QualityFilter.hiRes => fmt.isHiRes,
        QualityFilter.cdQuality => fmt.isCdQuality,
        QualityFilter.lossy => !fmt.codec.isLossless,
      };

  bool _matchesAlbum(Album a, LibraryFilters f) {
    if (!f.showUnsupported && !a.format.codec.isSupported) return false;
    if (!_settings.value.showUnsupportedFiles && !a.format.codec.isSupported) {
      return false;
    }
    if (f.codecs.isNotEmpty && !f.codecs.contains(a.format.codec)) return false;
    if (!_matchesQuality(a.format, f.quality)) return false;
    if (f.genre != null && a.genre != f.genre) return false;
    if (!_matchesAvailability(a.availability, f.availability)) return false;
    if (_scenario.offline &&
        f.availability == AvailabilityFilter.any &&
        a.availability == Availability.cloudOnly) {
      // Offline still lists cloud-only albums, just dimmed — do not drop them.
      return true;
    }
    return true;
  }

  bool _matchesTrack(Track t, LibraryFilters f) {
    if (f.artistId != null &&
        MockCatalog.albumById(t.albumId)?.artistId != f.artistId) {
      return false;
    }
    if (!f.showUnsupported && !t.format.codec.isSupported) return false;
    if (!_settings.value.showUnsupportedFiles && !t.format.codec.isSupported) {
      return false;
    }
    if (f.codecs.isNotEmpty && !f.codecs.contains(t.format.codec)) return false;
    if (!_matchesQuality(t.format, f.quality)) return false;
    if (f.genre != null && t.genre != f.genre) return false;
    if (!_matchesAvailability(t.availability, f.availability)) return false;
    return true;
  }

  bool _matchesAvailability(Availability a, AvailabilityFilter f) =>
      switch (f) {
        AvailabilityFilter.any => true,
        AvailabilityFilter.offline => a == Availability.pinned,
        AvailabilityFilter.cached =>
          a == Availability.cached || a == Availability.pinned,
        AvailabilityFilter.cloudOnly => a == Availability.cloudOnly,
      };

  // ---- Folder tree ---------------------------------------------------------

  List<FolderEntry> _allFolders() => const [
        FolderEntry(
            id: 'fo-music', name: 'Music', isDirectory: true, itemCount: 4),
        FolderEntry(
            id: 'fo-hires', name: 'Hi-Res', isDirectory: true, itemCount: 4),
        FolderEntry(
            id: 'fo-lossless',
            name: 'Lossless',
            isDirectory: true,
            itemCount: 2),
        FolderEntry(
            id: 'fo-jazz', name: 'Jazz', isDirectory: true, itemCount: 1),
        FolderEntry(
            id: 'fo-lossy', name: 'Lossy', isDirectory: true, itemCount: 1),
        FolderEntry(
            id: 'fo-archive', name: 'Archive', isDirectory: true, itemCount: 1),
        FolderEntry(id: 'fo-dsd', name: 'DSD', isDirectory: true, itemCount: 1),
        FolderEntry(
            id: 'fo-comp',
            name: 'Compilations',
            isDirectory: true,
            itemCount: 1),
      ];

  /// Folder hierarchy mirroring the catalogue's `folderPath` strings.
  static const _tree = <String, List<String>>{
    'root': ['fo-music'],
    'fo-music': [
      'fo-hires',
      'fo-lossless',
      'fo-jazz',
      'fo-lossy',
      'fo-archive',
      'fo-dsd',
      'fo-comp'
    ],
    'fo-hires': ['al-northern', 'al-glass', 'al-field', 'al-loworbit'],
    'fo-lossless': ['al-quiet', 'al-paper'],
    'fo-jazz': ['al-midnight'],
    'fo-lossy': ['al-concrete'],
    'fo-archive': ['al-archive'],
    'fo-dsd': ['al-sunday'],
    'fo-comp': ['al-mixed'],
  };

  static const _parents = <String, String?>{
    'fo-music': null,
    'fo-hires': 'fo-music',
    'fo-lossless': 'fo-music',
    'fo-jazz': 'fo-music',
    'fo-lossy': 'fo-music',
    'fo-archive': 'fo-music',
    'fo-dsd': 'fo-music',
    'fo-comp': 'fo-music',
  };

  FolderListing _folderListing(String? folderId) {
    final key = folderId ?? 'root';
    final childIds = _tree[key] ?? const [];
    final folders = _allFolders();

    FolderEntry? named(String id) => folders
        .cast<FolderEntry?>()
        .firstWhere((f) => f!.id == id, orElse: () => null);

    final entries = <FolderEntry>[];
    for (final id in childIds) {
      if (id.startsWith('fo-')) {
        final f = named(id);
        if (f == null) continue;
        final albumsInside = (_tree[id] ?? const []).length;
        final bytes = (_tree[id] ?? const [])
            .map((aid) => MockCatalog.albumById(aid)?.sizeBytes ?? 0)
            .fold<int>(0, (a, b) => a + b);
        entries.add(FolderEntry(
          id: id,
          name: f.name,
          isDirectory: true,
          itemCount: albumsInside,
          sizeBytes: bytes,
        ));
      } else {
        // An album folder: show it as a directory containing its tracks.
        final a = MockCatalog.albumById(id);
        if (a == null) continue;
        entries.add(FolderEntry(
          id: 'alfo-$id',
          name: a.title,
          isDirectory: true,
          itemCount: a.trackCount,
          sizeBytes: a.sizeBytes,
        ));
      }
    }

    // Inside an album folder: list the audio files themselves.
    if (key.startsWith('alfo-')) {
      final albumId = key.substring(5);
      for (final t in MockCatalog.tracksByAlbum[albumId] ?? const <Track>[]) {
        entries.add(FolderEntry(
          id: 'file-${t.id}',
          name: '${t.trackNumber.toString().padLeft(2, '0')} - ${t.title}'
              '.${t.format.codec.label.toLowerCase()}',
          isDirectory: false,
          sizeBytes: t.sizeBytes,
          track: t,
        ));
      }
    }

    // Build the breadcrumb by walking up.
    final crumbs = <FolderEntry>[];
    var cursor = key == 'root' ? null : key;
    while (cursor != null) {
      if (cursor.startsWith('alfo-')) {
        final a = MockCatalog.albumById(cursor.substring(5));
        if (a != null) {
          crumbs.insert(
              0, FolderEntry(id: cursor, name: a.title, isDirectory: true));
        }
        // Album folders sit under their genre folder.
        final parent =
            _tree.entries.cast<MapEntry<String, List<String>>?>().firstWhere(
                  (e) => e!.value.contains(cursor!.substring(5)),
                  orElse: () => null,
                );
        cursor = parent?.key;
        continue;
      }
      final f = _allFolders().cast<FolderEntry?>().firstWhere(
            (x) => x!.id == cursor,
            orElse: () => null,
          );
      if (f != null) crumbs.insert(0, f);
      cursor = _parents[cursor];
    }

    return FolderListing(
        folderId: folderId, breadcrumb: crumbs, entries: entries);
  }

  Future<void> _latency({int ms = 40}) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  // ---- Commands ------------------------------------------------------------

  @override
  Future<void> send(PlayerCommand cmd) async {
    switch (cmd) {
      case PlayContext(
          :final trackIds,
          :final startIndex,
          :final contextLabel,
          :final shuffle
        ):
        final tracks =
            trackIds.map(MockCatalog.trackById).whereType<Track>().toList();
        if (tracks.isEmpty) return;
        final ordered = shuffle ? (tracks.toList()..shuffle(_rand)) : tracks;
        _queue.emit(QueueState(
          items: _buildQueueItems(ordered),
          currentIndex: -1,
          shuffle: shuffle,
          repeat: _queue.value.repeat,
          contextLabel: contextLabel,
          history: _queue.value.history,
        ));
        _playAtOrSkip(shuffle ? 0 : startIndex);

      case Pause():
        if (_playback.value is PlayingState)
          _playback.emit(const PausedState());

      case Resume():
        if (_nowPlaying.value != null) _playback.emit(const PlayingState());

      case Seek(:final positionMs):
        _positionMs =
            positionMs.clamp(0, _nowPlaying.value?.track.durationMs ?? 0);
        if (!_isCached(_positionMs) && !_scenario.offline) {
          _bufferAttempt = 1;
          _bufferRemainingMs = 1200;
          _playback.emit(const BufferingState(bufferedMs: 0, targetMs: 3000));
        }
        _emitPosition();

      case Next():
        _advance();

      case Previous():
        if (_positionMs > 4000) {
          _positionMs = 0;
          _emitPosition();
        } else {
          _advance(direction: -1);
        }

      case SetShuffle(:final enabled):
        final q = _queue.value;
        _queue.emit(QueueState(
          items: q.items,
          currentIndex: q.currentIndex,
          shuffle: enabled,
          repeat: q.repeat,
          contextLabel: q.contextLabel,
          history: q.history,
        ));

      case SetRepeat(:final mode):
        final q = _queue.value;
        _queue.emit(QueueState(
          items: q.items,
          currentIndex: q.currentIndex,
          shuffle: q.shuffle,
          repeat: mode,
          contextLabel: q.contextLabel,
          history: q.history,
        ));

      case Enqueue(:final trackIds):
        _insertTracks(trackIds, atEnd: true);

      case PlayNext(:final trackIds):
        _insertTracks(trackIds, atEnd: false);

      case Reorder(:final oldIndex, :final newIndex):
        final q = _queue.value;
        final items = [...q.items];
        if (oldIndex < 0 || oldIndex >= items.length) return;
        final item = items.removeAt(oldIndex);
        items.insert(newIndex.clamp(0, items.length), item);
        var current = q.currentIndex;
        if (oldIndex == current) {
          current = newIndex.clamp(0, items.length - 1);
        } else if (oldIndex < current && newIndex >= current) {
          current--;
        } else if (oldIndex > current && newIndex <= current) {
          current++;
        }
        _queue.emit(QueueState(
          items: _rebuildGaps(items),
          currentIndex: current,
          shuffle: q.shuffle,
          repeat: q.repeat,
          contextLabel: q.contextLabel,
          history: q.history,
        ));

      case RemoveFromQueue(:final itemId):
        final q = _queue.value;
        final idx = q.items.indexWhere((i) => i.id == itemId);
        if (idx < 0) return;
        final items = [...q.items]..removeAt(idx);
        _queue.emit(QueueState(
          items: _rebuildGaps(items),
          currentIndex:
              idx < q.currentIndex ? q.currentIndex - 1 : q.currentIndex,
          shuffle: q.shuffle,
          repeat: q.repeat,
          contextLabel: q.contextLabel,
          history: q.history,
        ));

      case ClearQueue():
        _queue.emit(QueueState(
          items: const [],
          currentIndex: -1,
          shuffle: false,
          repeat: _queue.value.repeat,
          history: _queue.value.history,
        ));
        _nowPlaying.emit(null);
        _playback.emit(const IdleState());
        _position.emit(PositionInfo.empty);

      case ShuffleRemaining():
        final q = _queue.value;
        if (q.currentIndex < 0) return;
        final head = q.items.take(q.currentIndex + 1).toList();
        final tail = q.items.skip(q.currentIndex + 1).toList()..shuffle(_rand);
        _queue.emit(QueueState(
          items: _rebuildGaps([...head, ...tail]),
          currentIndex: q.currentIndex,
          shuffle: true,
          repeat: q.repeat,
          contextLabel: q.contextLabel,
          history: q.history,
        ));

      case SetEqBands(:final bands):
        // Editing a band does not touch the master bypass — that switch
        // stays the user's.
        _eq.emit(_eq.value.copyWith(bands: bands));
        _recomputeSignalPath();

      case SetEqMode(:final mode):
        _eq.emit(_eq.value.copyWith(mode: mode));

      case SetGraphicGains(:final gains):
        _eq.emit(_eq.value.copyWith(graphicGains: gains));
        _recomputeSignalPath();

      case SetBypass(:final bypass):
        _eq.emit(_eq.value.copyWith(bypass: bypass));
        _recomputeSignalPath();

      case SetPreamp(:final db):
        // Clipping meter: positive preamp on a hot master clips.
        final clipped = db > 0 ? (db * 420).round() : 0;
        _eq.emit(_eq.value.copyWith(preampDb: db, clippedSamples: clipped));
        _recomputeSignalPath();

      case SetTone(:final bassDb, :final trebleDb, :final balance, :final mono):
        _eq.emit(_eq.value.copyWith(
          bassDb: bassDb,
          trebleDb: trebleDb,
          balance: balance,
          mono: mono,
        ));
        _recomputeSignalPath();

      case SetReplayGain(:final mode, :final preampDb):
        _eq.emit(
            _eq.value.copyWith(replayGain: mode, replayGainPreampDb: preampDb));
        _settings.emit(_settings.value.copyWith(replayGain: mode));
        _recomputeSignalPath();

      case ApplyAutoEqProfile(:final profileId):
        final p = MockCatalog.autoEqProfiles
            .cast<AutoEqProfile?>()
            .firstWhere((x) => x!.id == profileId, orElse: () => null);
        if (p == null) return;
        _eq.emit(_eq.value.copyWith(
          mode: EqMode.parametric,
          bands: p.bands,
          preampDb: p.suggestedPreampDb,
          bypass: false,
          presetName: '${p.model} AutoEQ',
        ));
        _recomputeSignalPath();
        _events.add(CoreEvent.snack('Applied ${p.model} AutoEQ · preamp '
            '${_db(p.suggestedPreampDb)}'));

      case ImportParametricEq(:final text):
        final parsed = _parseParametricEq(text);
        if (parsed.isEmpty) {
          _events.add(const CoreEvent.snack(
              'No bands found. Expected AutoEQ ParametricEQ.txt format.'));
          return;
        }
        _eq.emit(_eq.value.copyWith(
          mode: EqMode.parametric,
          bands: parsed,
          bypass: false,
          presetName: 'Imported preset',
        ));
        _recomputeSignalPath();
        _events.add(CoreEvent.snack('Imported ${parsed.length} bands.'));

      case AssignEqToDevice(:final deviceId, :final assign):
        _eq.emit(_eq.value.copyWith(
          assignedDeviceName: assign
              ? MockCatalog.knownDevices
                  .firstWhere((d) => d.id == deviceId,
                      orElse: () => MockCatalog.titanX)
                  .name
              : null,
        ));

      case Pin(:final id, :final kind):
        _applyPin(id, kind, pinned: true);

      case Unpin(:final id, :final kind):
        _applyPin(id, kind, pinned: false);

      case SetFavorite(:final trackId, :final favorite):
        final np = _nowPlaying.value;
        if (np != null && np.track.id == trackId) {
          _nowPlaying.emit(NowPlaying(
            track: np.track.copyWith(favorite: favorite),
            album: np.album,
            contextLabel: np.contextLabel,
            contextId: np.contextId,
          ));
        }

      case Rescan():
        _syncStatus.emit(const SyncStatus(
          phase: SyncPhase.listing,
          processed: 0,
          total: MockCatalog.libraryTrackCount,
        ));
        Timer(const Duration(seconds: 2), () {
          _syncStatus.emit(const SyncStatus(
            phase: SyncPhase.tags,
            processed: 240,
            total: MockCatalog.libraryTrackCount,
          ));
        });
        _events.add(const CoreEvent.snack('Rescanning Google Drive.'));

      case ReconnectSource(:final sourceId):
        _sources.emit(_sources.value
            .map((s) => s.id == sourceId
                ? SourceAccount(
                    id: s.id,
                    provider: s.provider,
                    accountLabel: s.accountLabel,
                    trackCount: s.trackCount,
                    folderCount: s.folderCount,
                    status: SourceStatus.upToDate,
                    lastSync: DateTime.now(),
                    changesSinceLastSync: s.changesSinceLastSync,
                  )
                : s)
            .toList());
        _banners
            .emit(_banners.value.where((b) => b.id != 'b-reconnect').toList());
        _events.add(const CoreEvent.snack('Google Drive reconnected.'));

      case RemoveSource(:final sourceId):
        _sources.emit(_sources.value.where((s) => s.id != sourceId).toList());

      case RunSafetyCheck():
        _events.add(const CoreEvent.snack('Safety check complete.'));

      case SetSafetyAttenuation(:final enabled, :final db):
        _settings.emit(_settings.value.copyWith(
          safetyAttenuationEnabled: enabled,
          safetyAttenuationDb: db ?? _settings.value.safetyAttenuationDb,
        ));
        _recomputeSignalPath();

      case SetVolumeDb(:final db):
        _volumeDb = db;

      case SetCacheLimit(:final bytes):
        final s = _storage.value;
        _storage.emit(StorageState(
          pinnedBytes: s.pinnedBytes,
          cacheBytes: math.min(s.cacheBytes, bytes),
          freeBytes: s.freeBytes,
          totalBytes: s.totalBytes,
          cacheLimitBytes: bytes,
          artworkBytes: s.artworkBytes,
          databaseBytes: s.databaseBytes,
          pinned: s.pinned,
          downloads: s.downloads,
          wifiOnlyDownloads: s.wifiOnlyDownloads,
          mobilePinPolicy: s.mobilePinPolicy,
        ));

      case ClearCache():
        final s = _storage.value;
        _storage.emit(StorageState(
          pinnedBytes: s.pinnedBytes,
          cacheBytes: 0,
          freeBytes: s.freeBytes + s.cacheBytes,
          totalBytes: s.totalBytes,
          cacheLimitBytes: s.cacheLimitBytes,
          artworkBytes: s.artworkBytes,
          databaseBytes: s.databaseBytes,
          pinned: s.pinned,
          downloads: s.downloads,
          wifiOnlyDownloads: s.wifiOnlyDownloads,
          mobilePinPolicy: s.mobilePinPolicy,
        ));
        _events.add(const CoreEvent.snack('Cache cleared. Pinned music kept.'));

      case PauseDownload(:final jobId, :final paused):
        final s = _storage.value;
        _storage.emit(StorageState(
          pinnedBytes: s.pinnedBytes,
          cacheBytes: s.cacheBytes,
          freeBytes: s.freeBytes,
          totalBytes: s.totalBytes,
          cacheLimitBytes: s.cacheLimitBytes,
          artworkBytes: s.artworkBytes,
          databaseBytes: s.databaseBytes,
          pinned: s.pinned,
          downloads: s.downloads
              .map((d) => d.id == jobId
                  ? DownloadJob(
                      id: d.id,
                      title: d.title,
                      progress: d.progress,
                      sizeBytes: d.sizeBytes,
                      paused: paused,
                    )
                  : d)
              .toList(),
          wifiOnlyDownloads: s.wifiOnlyDownloads,
          mobilePinPolicy: s.mobilePinPolicy,
        ));

      case DismissBanner(:final bannerId):
        _banners.emit(_banners.value.where((b) => b.id != bannerId).toList());

      case CreatePlaylist(:final name):
        _events.add(CoreEvent.snack('Created playlist "$name".'));

      case SaveQueueAsPlaylist(:final name):
        _events.add(CoreEvent.snack('Saved queue as "$name".'));

      case SetSleepTimer(:final minutes):
        _sleepTimerMinutes = minutes ?? 0;
        _events.add(CoreEvent.snack(minutes == null
            ? 'Sleep timer cancelled.'
            : 'Sleep timer set for $minutes minutes.'));

      case SetSetting(:final key, :final value):
        _settings.emit(_settings.value.withKey(key, value));
        if (key == 'safetyAttenuationEnabled' || key == 'replayGain') {
          _recomputeSignalPath();
        }
    }
  }

  double get volumeDb => _volumeDb;
  int get sleepTimerMinutes => _sleepTimerMinutes;

  void _playAtOrSkip(int index) {
    final q = _queue.value;
    if (q.items.isEmpty) return;
    final target = index.clamp(0, q.items.length - 1);
    final t = q.items[target].track;
    if (t.availability == Availability.unsupported ||
        t.availability == Availability.missing) {
      _queue.emit(QueueState(
        items: q.items,
        currentIndex: target - 1,
        shuffle: q.shuffle,
        repeat: q.repeat,
        contextLabel: q.contextLabel,
        history: q.history,
      ));
      _advance();
      return;
    }
    _playAt(target);
  }

  void _insertTracks(List<String> trackIds, {required bool atEnd}) {
    final q = _queue.value;
    final tracks =
        trackIds.map(MockCatalog.trackById).whereType<Track>().toList();
    if (tracks.isEmpty) return;
    final items = [...q.items];
    final insertAt =
        atEnd ? items.length : (q.currentIndex + 1).clamp(0, items.length);
    final newItems = _buildQueueItems(tracks, prefix: 'add${items.length}')
        .map((i) => QueueItem(
              track: i.track,
              id: i.id,
              preloadedForGapless: i.preloadedForGapless,
              gapReason: i.gapReason,
              isUserAdded: true,
            ))
        .toList();
    items.insertAll(insertAt, newItems);
    _queue.emit(QueueState(
      items: _rebuildGaps(items),
      currentIndex: q.currentIndex,
      shuffle: q.shuffle,
      repeat: q.repeat,
      contextLabel: q.contextLabel,
      history: q.history,
    ));
    _events.add(CoreEvent.snack(atEnd
        ? 'Added ${tracks.length} to queue'
        : 'Playing ${tracks.length} next'));
  }

  /// Gap markers depend on neighbours, so they are recomputed after any
  /// reorder, insert or remove.
  List<QueueItem> _rebuildGaps(List<QueueItem> items) {
    final out = <QueueItem>[];
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      String? gap;
      var preloaded = false;
      if (i > 0) {
        final prev = items[i - 1].track;
        if (prev.format.sampleRate != it.track.format.sampleRate) {
          gap = '${_khz(prev.format.sampleRate)} → '
              '${_khz(it.track.format.sampleRate)} kHz';
        } else if (it.track.cachedPercent > 20) {
          preloaded = true;
        }
      }
      out.add(QueueItem(
        track: it.track,
        id: it.id,
        preloadedForGapless: preloaded,
        gapReason: gap,
        isUserAdded: it.isUserAdded,
      ));
    }
    return out;
  }

  void _applyPin(String id, String kind, {required bool pinned}) {
    final label = switch (kind) {
      'album' => MockCatalog.albumById(id)?.title ?? 'Album',
      'playlist' => MockCatalog.playlists
          .firstWhere((p) => p.id == id,
              orElse: () => MockCatalog.playlists.first)
          .name,
      _ => 'Item',
    };
    _events.add(CoreEvent.snack(
        pinned ? 'Pinning "$label" for offline.' : 'Unpinned "$label".'));
  }

  /// Parses AutoEQ's `ParametricEQ.txt`:
  /// `Filter 1: ON PK Fc 105 Hz Gain 3.4 dB Q 0.70`
  List<EqBand> _parseParametricEq(String text) {
    final bands = <EqBand>[];
    final re = RegExp(
      r'Filter\s+(\d+):\s+(ON|OFF)\s+(PK|LSC|HSC|LPQ|HPQ)\s+Fc\s+([\d.]+)\s*Hz'
      r'(?:\s+Gain\s+(-?[\d.]+)\s*dB)?(?:\s+Q\s+([\d.]+))?',
      caseSensitive: false,
    );
    for (final m in re.allMatches(text)) {
      bands.add(EqBand(
        id: int.parse(m.group(1)!),
        type: switch (m.group(3)!.toUpperCase()) {
          'LSC' => BiquadType.lowShelf,
          'HSC' => BiquadType.highShelf,
          'LPQ' => BiquadType.lowPass,
          'HPQ' => BiquadType.highPass,
          _ => BiquadType.peak,
        },
        frequencyHz: double.parse(m.group(4)!),
        gainDb: double.tryParse(m.group(5) ?? '0') ?? 0,
        q: double.tryParse(m.group(6) ?? '0.7') ?? 0.7,
        enabled: m.group(2)!.toUpperCase() == 'ON',
      ));
    }
    return bands;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _slowTicker?.cancel();
    _playback.close();
    _position.close();
    _nowPlaying.close();
    _signalPath.close();
    _queue.close();
    _outputDevice.close();
    _sources.close();
    _syncStatus.close();
    _banners.close();
    _eq.close();
    _storage.close();
    _diagnostics.close();
    _visualizer.close();
    _deviceProfiles.close();
    _settings.close();
    _events.close();
  }
}

/// One-shot messages that are not state: snackbars, scenario announcements.
class CoreEvent {
  const CoreEvent.snack(this.message) : kind = CoreEventKind.snack;
  const CoreEvent.scenarioChanged(this.message)
      : kind = CoreEventKind.scenarioChanged;

  final CoreEventKind kind;
  final String message;
}

enum CoreEventKind { snack, scenarioChanged }

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:bitdrop/core_api/commands.dart';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/core_live/audio_handler.dart';
import 'package:bitdrop/core_live/live_core.dart';
import 'package:bitdrop/core_live/output_device.dart';
import 'package:bitdrop/core_live/playback_engine.dart';
import 'package:bitdrop/services/bitdrop_output_coordinator.dart';
import 'package:bitdrop/src/rust/api/audio_engine.dart' as rust;
import 'package:flutter_test/flutter_test.dart';

class _RecordingEngine extends PlaybackEngine {
  final controller = StreamController<rust.EngineEvent>.broadcast(sync: true);
  final List<String> playedPaths = [];
  final List<String> stagedPaths = [];
  int resumeCalls = 0;
  int pauseCalls = 0;
  int clearNextCalls = 0;
  bool _playing = false;

  @override
  Stream<rust.EngineEvent> events() => controller.stream;

  @override
  int get position => 1000;

  @override
  bool get isPlaying => _playing;

  @override
  rust.EngineBufferState get buffer => rust.EngineBufferState(
        buffering: false,
        bufferedMs: 5000,
        fetchesInFlight: 0,
        bytesFetched: BigInt.zero,
        streamOpens: 1,
      );

  @override
  void play(String path) {
    playedPaths.add(path);
    _playing = true;
  }

  @override
  void stage(String path) {
    stagedPaths.add(path);
  }

  @override
  void clearNext() {
    clearNextCalls++;
  }

  @override
  void resume() {
    resumeCalls++;
    _playing = true;
  }

  @override
  void pause() {
    pauseCalls++;
    _playing = false;
  }

  @override
  void stop() {
    _playing = false;
  }

  @override
  void seek(int milliseconds) {}
}

class _FakeAudioSession implements AudioSession {
  final noisyController = StreamController<void>.broadcast(sync: true);
  final interruptionController =
      StreamController<AudioInterruptionEvent>.broadcast(sync: true);
  final devicesChangedController =
      StreamController<AudioDevicesChangedEvent>.broadcast(sync: true);

  int setActiveTrueCalls = 0;
  bool nextSetActiveResult = true;

  @override
  Stream<void> get becomingNoisyEventStream => noisyController.stream;

  @override
  Stream<AudioInterruptionEvent> get interruptionEventStream =>
      interruptionController.stream;

  @override
  Stream<AudioDevicesChangedEvent> get devicesChangedEventStream =>
      devicesChangedController.stream;

  @override
  Future<bool> setActive(
    bool active, {
    AVAudioSessionSetActiveOptions? avAudioSessionSetActiveOptions,
    AndroidAudioFocusGainType? androidAudioFocusGainType,
    AndroidAudioAttributes? androidAudioAttributes,
    bool? androidWillPauseWhenDucked,
    AudioSessionConfiguration? fallbackConfiguration,
  }) async {
    if (active) setActiveTrueCalls++;
    return nextSetActiveResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  Future<void> close() async {
    await noisyController.close();
    await interruptionController.close();
    await devicesChangedController.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Batch 1: Safety Attenuation & Software Volume (C-01)', () {
    test('effectiveSoftwareVolumeDb enforces safety ceiling and slider floor',
        () async {
      final engine = _RecordingEngine();
      final handler = BitDropAudioHandler(engine: engine);
      final probe = OutputDeviceProbe(autoPoll: false);
      final core = LiveBitDropCore(handler, outputProbe: probe);

      expect(core.effectiveSoftwareVolumeDb(), 0.0);

      await core
          .send(const SetSafetyAttenuation(enabled: true, db: -12.0));
      expect(core.effectiveSoftwareVolumeDb(), -12.0);

      // Raising slider toward 0 dB must never exceed safety ceiling (-12 dB).
      await core.send(const SetVolumeDb(-3.0));
      expect(core.effectiveSoftwareVolumeDb(), -12.0);

      // Lowering slider below safety ceiling attenuates further (-24 dB).
      await core.send(const SetVolumeDb(-24.0));
      expect(core.effectiveSoftwareVolumeDb(), -24.0);

      // Disabling safety attenuation restores slider level, then 0 dB unity.
      await core.send(const SetSafetyAttenuation(enabled: false));
      expect(core.effectiveSoftwareVolumeDb(), -24.0);

      await core.send(const SetVolumeDb(0.0));
      expect(core.effectiveSoftwareVolumeDb(), 0.0);

      core.dispose();
      await handler.dispose();
      await engine.controller.close();
    });

    test('SignalPath downgrades bitPerfect to nativeRate with safety attenuation',
        () {
      final probe = OutputDeviceProbe(autoPoll: false);
      var swVolDb = -12.0;
      var safetyEnabled = true;

      final coord = BitDropOutputCoordinator(
        outputProbe: probe,
        softwareVolumeDbProvider: () => swVolDb,
        isSafetyAttenuationEnabled: () => safetyEnabled,
        engineOutputStateProvider: () => const rust.EngineOutputState(
          sourceCodec: 'FLAC',
          sourceSampleRate: 96000,
          sourceBits: 24,
          sourceChannels: 2,
          outputSampleRate: 96000,
          dspActive: false,
          hasTrack: true,
          hardwareSampleRate: 96000,
          hardwareFormat: 'PCM_FLOAT',
        ),
      );
      probe.emitForTesting(
        const OutputDevice(
          id: 'android-usb-dac',
          name: 'USB-C DAC',
          type: DeviceType.usb,
          supportedRates: [44100, 48000, 96000],
          bitDepths: [16, 24],
          hardwareVolume: HardwareVolume.no,
          maxTier: OutputTier.bitPerfect,
          supportsBitPerfect: true,
          bitPerfectRates: [44100, 48000, 96000],
        ),
      );

      coord.recomputeSignalPath();
      expect(coord.currentSignalPath.tier, OutputTier.nativeRate);
      expect(coord.currentSignalPath.dspActive, isTrue);
      expect(coord.currentSignalPath.volume, VolumeMode.softwareDithered);
      expect(
        coord.currentSignalPath.dspChain,
        contains('Safety attenuation (-12.0 dB)'),
      );

      // Turning off attenuation restores bit-perfect.
      swVolDb = 0.0;
      safetyEnabled = false;
      coord.recomputeSignalPath();
      expect(coord.currentSignalPath.tier, OutputTier.bitPerfect);
      expect(coord.currentSignalPath.dspActive, isFalse);

      coord.dispose();
    });
  });

  group('Batch 1: Audio Focus & Unplug-During-Load Safety (C-03, C-04)', () {
    const trackA = MediaItem(
      id: '/storage/emulated/0/Music/Artist/Album/01 - Track A.flac',
      title: 'Track A',
      duration: Duration(seconds: 180),
    );

    test('setQueueAndPlay requests audio focus and interruption pauses/resumes only if active',
        () async {
      final engine = _RecordingEngine();
      final session = _FakeAudioSession();
      final handler =
          BitDropAudioHandler(engine: engine, audioSession: session);

      await handler.setQueueAndPlay([trackA], 0);
      expect(session.setActiveTrueCalls, greaterThanOrEqualTo(1));
      expect(handler.playbackState.value.playing, isTrue);

      // Incoming phone call / audio focus loss pauses playback.
      session.interruptionController.add(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await Future<void>.delayed(Duration.zero);
      expect(handler.playbackState.value.playing, isFalse);

      // Call ends -> resumes because it was playing before interruption.
      session.interruptionController.add(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      await Future<void>.delayed(Duration.zero);
      expect(handler.playbackState.value.playing, isTrue);

      // User manually pauses, then an interruption occurs -> must NOT auto-resume!
      await handler.pause();
      expect(handler.playbackState.value.playing, isFalse);

      session.interruptionController.add(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await Future<void>.delayed(Duration.zero);
      session.interruptionController.add(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      await Future<void>.delayed(Duration.zero);
      expect(handler.playbackState.value.playing, isFalse);

      await handler.dispose();
      await session.close();
      await engine.controller.close();
    });

    test('unplugging earphones during async track open prevents speaker blast',
        () async {
      final engine = _RecordingEngine();
      final session = _FakeAudioSession();
      final handler =
          BitDropAudioHandler(engine: engine, audioSession: session);
      final prepareGate = Completer<void>();

      handler.onPrepareOutputFormat = (_, __) => prepareGate.future;

      // Start opening track; pauses inside onPrepareOutputFormat.
      final playFuture = handler.setQueueAndPlay([trackA], 0);
      await Future<void>.delayed(Duration.zero);
      expect(handler.isPlayingOrLoading, isTrue);

      // Earphone disconnects mid-load before _engine.play() has been called!
      session.noisyController.add(null);
      await Future<void>.delayed(Duration.zero);

      // Release format barrier; track MUST NOT start playing!
      prepareGate.complete();
      await playFuture;
      expect(engine.playedPaths, isEmpty);
      expect(handler.playbackState.value.playing, isFalse);

      // Later user taps Play -> must cleanly open the track via play().
      handler.onPrepareOutputFormat = null;
      await handler.play();
      expect(engine.playedPaths, [trackA.id]);
      expect(handler.playbackState.value.playing, isTrue);

      await handler.dispose();
      await session.close();
      await engine.controller.close();
    });
  });

  group('Batch 1: Gapless Toggle, End-of-Queue Resume & Duplicate Queue IDs (C-05, M-02)',
      () {
    const trackA = MediaItem(
      id: '/storage/emulated/0/Music/A.flac',
      title: 'Track A',
      duration: Duration(seconds: 120),
    );
    const trackB = MediaItem(
      id: '/storage/emulated/0/Music/B.flac',
      title: 'Track B',
      duration: Duration(seconds: 120),
    );

    test('disabling gapless prevents staging next track and clears staged',
        () async {
      final engine = _RecordingEngine();
      final handler = BitDropAudioHandler(engine: engine);

      handler.setGaplessEnabled(false);
      await handler.setQueueAndPlay([trackA, trackB], 0);
      await Future<void>.delayed(Duration.zero);
      expect(engine.stagedPaths, isEmpty);

      handler.setGaplessEnabled(true);
      await Future<void>.delayed(Duration.zero);
      expect(engine.stagedPaths, [trackB.id]);

      await handler.dispose();
      await engine.controller.close();
    });

    test('pressing play or single-click after end-of-queue re-opens track cleanly',
        () async {
      final engine = _RecordingEngine();
      final handler = BitDropAudioHandler(engine: engine)
        ..headsetMultiClickEnabled = false;

      await handler.setQueueAndPlay([trackA], 0);
      expect(engine.playedPaths, [trackA.id]);

      // Natural EOF on last track (RepeatMode.off).
      engine.controller.add(rust.EngineEvent.trackEnded(fileId: trackA.id));
      await Future<void>.delayed(Duration.zero);
      expect(handler.playbackState.value.playing, isFalse);

      // Single-press inline button must re-open track via play() instead of resume().
      await handler.click(MediaButton.media);
      expect(engine.playedPaths.length, 2);
      expect(engine.resumeCalls, 0);
      expect(handler.playbackState.value.playing, isTrue);

      await handler.dispose();
      await engine.controller.close();
    });

    test('duplicate tracks in queue advance to index 2 and survive shuffle',
        () async {
      final engine = _RecordingEngine();
      final handler = BitDropAudioHandler(engine: engine);

      await handler.setQueueAndPlay([trackA, trackB, trackA], 1);
      expect(handler.currentIndex, 1);

      // Gapless TrackStarted for the 2nd copy of trackA advances to index 2, NOT 0!
      engine.controller.add(rust.EngineEvent.trackStarted(fileId: trackA.id));
      await Future<void>.delayed(Duration.zero);
      expect(handler.currentIndex, 2);

      // Shuffling a queue with duplicates preserves all 3 entries.
      await handler.setQueueAndPlay([trackA, trackB, trackA], 0, shuffle: true);
      expect(handler.queue.value.length, 3);

      await handler.dispose();
      await engine.controller.close();
    });
  });
}

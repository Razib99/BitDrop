import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/core_live/audio_handler.dart';
import 'package:bitdrop/core_live/live_core.dart';
import 'package:bitdrop/core_live/output_device.dart';
import 'package:bitdrop/core_live/playback_engine.dart';
import 'package:bitdrop/src/rust/api/audio_engine.dart' as rust;
import 'package:flutter_test/flutter_test.dart';

class _FakeEngine extends PlaybackEngine {
  final controller = StreamController<rust.EngineEvent>.broadcast(sync: true);
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
    _playing = true;
  }

  @override
  void resume() {
    _playing = true;
  }

  @override
  void pause() {
    _playing = false;
  }

  @override
  void stop() {
    _playing = false;
  }
}

OutputDevice _makeDevice({
  required String id,
  required String name,
  required DeviceType type,
}) {
  return OutputDevice(
    id: id,
    name: name,
    type: type,
    supportedRates: const [44100, 48000, 96000],
    bitDepths: const [16, 24],
    hardwareVolume: HardwareVolume.unknown,
    maxTier: OutputTier.bitPerfect,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Earphone disconnect and becoming noisy pause behavior', () {
    late _FakeEngine engine;
    late BitDropAudioHandler handler;
    late OutputDeviceProbe probe;
    late LiveBitDropCore core;

    const testItem = MediaItem(
      id: '/mock/track.flac',
      title: 'Test Audiophile Track',
      duration: Duration(seconds: 180),
    );

    setUp(() async {
      engine = _FakeEngine();
      handler = BitDropAudioHandler(engine: engine);
      probe = OutputDeviceProbe(autoPoll: false);
      core = LiveBitDropCore(handler, outputProbe: probe);

      await handler.setQueueAndPlay([testItem], 0);
      await handler.play();
      expect(handler.playbackState.value.playing, isTrue);
    });

    tearDown(() async {
      core.dispose();
      await handler.dispose();
      await engine.controller.close();
    });

    test('USB earphone disconnection pauses playback', () async {
      // 1. Connect USB earphone (e.g. DUNU Titan X Type-C IEM)
      probe.emitForTesting(
        _makeDevice(
          id: 'android-usb-dunu',
          name: 'DUNU Titan X DAC',
          type: DeviceType.usb,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(handler.playbackState.value.playing, isTrue);

      // 2. Disconnect USB earphone -> falls back to built-in phone speaker
      probe.emitForTesting(
        _makeDevice(
          id: 'android-speaker-phone',
          name: 'Phone Speaker',
          type: DeviceType.phoneSpeaker,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      // 3. Playback must be paused
      expect(handler.playbackState.value.playing, isFalse);
    });

    test('Wired 3.5mm headphone disconnection pauses playback', () async {
      // 1. Connect wired analog headphones
      probe.emitForTesting(
        _makeDevice(
          id: 'android-wired-headset',
          name: 'Wired Headphones',
          type: DeviceType.wiredAnalog,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(handler.playbackState.value.playing, isTrue);

      // 2. Unplug 3.5mm jack
      probe.emitForTesting(
        _makeDevice(
          id: 'android-speaker-phone',
          name: 'Phone Speaker',
          type: DeviceType.phoneSpeaker,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      // 3. Playback must be paused
      expect(handler.playbackState.value.playing, isFalse);
    });

    test('Bluetooth earphone disconnection pauses playback', () async {
      // 1. Connect Bluetooth earbuds
      probe.emitForTesting(
        _makeDevice(
          id: 'android-bluetooth-buds',
          name: 'Audiophile TWS',
          type: DeviceType.bluetooth,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(handler.playbackState.value.playing, isTrue);

      // 2. Bluetooth earbuds disconnect/turn off
      probe.emitForTesting(
        _makeDevice(
          id: 'android-speaker-phone',
          name: 'Phone Speaker',
          type: DeviceType.phoneSpeaker,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      // 3. Playback must be paused
      expect(handler.playbackState.value.playing, isFalse);
    });

    test('Connecting earphones while playing does NOT pause playback', () async {
      // 1. Start on phone speaker
      probe.emitForTesting(
        _makeDevice(
          id: 'android-speaker-phone',
          name: 'Phone Speaker',
          type: DeviceType.phoneSpeaker,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(handler.playbackState.value.playing, isTrue);

      // 2. User plugs in USB earphones
      probe.emitForTesting(
        _makeDevice(
          id: 'android-usb-dac',
          name: 'USB-C IEM',
          type: DeviceType.usb,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      // 3. Playback should continue uninterrupted
      expect(handler.playbackState.value.playing, isTrue);
    });

    test('ACTION_AUDIO_BECOMING_NOISY broadcast pauses playback', () async {
      expect(handler.playbackState.value.playing, isTrue);

      // Simulate system ACTION_AUDIO_BECOMING_NOISY event
      probe.simulateBecomingNoisy();
      await Future<void>.delayed(Duration.zero);

      expect(handler.playbackState.value.playing, isFalse);
    });

    test('Disconnection when already paused stays paused safely', () async {
      await handler.pause();
      expect(handler.playbackState.value.playing, isFalse);

      probe.emitForTesting(
        _makeDevice(
          id: 'android-usb-dac',
          name: 'USB-C IEM',
          type: DeviceType.usb,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      probe.emitForTesting(
        _makeDevice(
          id: 'android-speaker-phone',
          name: 'Phone Speaker',
          type: DeviceType.phoneSpeaker,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(handler.playbackState.value.playing, isFalse);
    });
  });
}

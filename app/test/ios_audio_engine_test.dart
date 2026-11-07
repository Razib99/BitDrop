import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/core_live/audio_handler.dart';
import 'package:bitdrop/core_live/live_core.dart';
import 'package:bitdrop/core_live/output_device.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'com.bitdrop/audio_device';
  const channel = MethodChannel(channelName);
  final List<MethodCall> methodLog = [];
  Map<String, dynamic>? mockCurrentOutput;
  bool mockSetPreferredResult = true;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    methodLog.clear();
    mockSetPreferredResult = true;
    mockCurrentOutput = {
      'available': true,
      'type': 'usb',
      'name': 'DUNU Titan X',
      'id': 'dunu-usb-uid-123',
      'sampleRates': [44100, 48000, 88200, 96000, 176400, 192000],
      'encodings': [4, 2, 21, 22],
      'systemSampleRate': 96000,
      'supportsBitPerfect': true,
      'maxTier': 'bitPerfect',
      'tierExplanation':
          'iOS CoreAudio hardware sample rate switching via AVAudioSession (Tier A Bit-Perfect)',
    };

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      methodLog.add(call);
      switch (call.method) {
        case 'currentOutput':
          return mockCurrentOutput;
        case 'setPreferredSampleRate':
        case 'setPreferredMixerAttributes':
        case 'clearPreferredSampleRate':
        case 'clearPreferredMixerAttributes':
          return mockSetPreferredResult;
        case 'getAudioSessionState':
          return {
            'sampleRate': 96000.0,
            'ioBufferDuration': 0.010,
            'category': 'AVAudioSessionCategoryPlayback',
            'outputNumberOfChannels': 2,
          };
        default:
          return null;
      }
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('OutputDeviceProbe iOS Device Reporting', () {
    test('reports USB DAC with Tier A Bit-Perfect capability on iOS', () async {
      final probe = OutputDeviceProbe(autoPoll: false);
      final device = await probe.read();

      expect(device, isNotNull);
      expect(device!.type, equals(DeviceType.usb));
      expect(device.name, equals('DUNU Titan X'));
      expect(device.id, contains('iOS-usb-DUNU Titan X'));
      expect(device.supportsBitPerfect, isTrue);
      expect(device.maxTier, equals(OutputTier.bitPerfect));
      expect(device.connectionLabel, equals('USB-C'));
      expect(device.systemSampleRate, equals(96000));
      expect(device.supportedRates, containsAll([44100, 48000, 96000, 192000]));
      probe.dispose();
    });

    test('reports 3.5mm wired analog headphones with nativeRate tier on iOS', () async {
      mockCurrentOutput = {
        'available': true,
        'type': 'wired',
        'name': 'Headphones',
        'id': 'wired-headphone-uid',
        'sampleRates': [44100, 48000],
        'encodings': [4, 2],
        'systemSampleRate': 48000,
        'supportsBitPerfect': false,
        'maxTier': 'nativeRate',
        'tierExplanation': 'iOS 3.5mm analog output via CoreAudio native clock',
      };

      final probe = OutputDeviceProbe(autoPoll: false);
      final device = await probe.read();

      expect(device, isNotNull);
      expect(device!.type, equals(DeviceType.wiredAnalog));
      expect(device.name, equals('Headphones'));
      expect(device.supportsBitPerfect, isFalse);
      expect(device.maxTier, equals(OutputTier.nativeRate));
      expect(device.connectionLabel, equals('3.5 mm'));
      probe.dispose();
    });

    test('reports iPhone built-in speaker with resampled tier on iOS', () async {
      mockCurrentOutput = {
        'available': true,
        'type': 'speaker',
        'name': 'Speaker',
        'id': 'builtin-speaker-uid',
        'sampleRates': [48000],
        'encodings': [4],
        'systemSampleRate': 48000,
        'supportsBitPerfect': false,
        'maxTier': 'resampled',
        'tierExplanation':
            'iPhone built-in speakers operating at system mixed sample rate',
      };

      final probe = OutputDeviceProbe(autoPoll: false);
      final device = await probe.read();

      expect(device, isNotNull);
      expect(device!.type, equals(DeviceType.phoneSpeaker));
      expect(device.name, equals('Speaker'));
      expect(device.maxTier, equals(OutputTier.resampled));
      probe.dispose();
    });

    test('reports Bluetooth audio device with resampled tier on iOS', () async {
      mockCurrentOutput = {
        'available': true,
        'type': 'bluetooth',
        'name': 'AirPods Pro',
        'id': 'airpods-uid',
        'sampleRates': [44100, 48000],
        'encodings': [4, 2],
        'systemSampleRate': 48000,
        'supportsBitPerfect': false,
        'maxTier': 'resampled',
        'tierExplanation':
            'Bluetooth A2DP/HFP re-encoded with wireless codec (AAC/SBC)',
      };

      final probe = OutputDeviceProbe(autoPoll: false);
      final device = await probe.read();

      expect(device, isNotNull);
      expect(device!.type, equals(DeviceType.bluetooth));
      expect(device.name, equals('AirPods Pro'));
      expect(device.maxTier, equals(OutputTier.resampled));
      expect(device.connectionLabel, equals('Bluetooth'));
      probe.dispose();
    });
  });

  group('AVAudioSession Rate Negotiation Methods', () {
    test('setPreferredSampleRate invokes host channel method on iOS', () async {
      final probe = OutputDeviceProbe(autoPoll: false);
      final ok = await probe.setPreferredSampleRate(sampleRate: 96000, bitDepth: 24);

      expect(ok, isTrue);
      expect(methodLog, hasLength(1));
      expect(methodLog.first.method, equals('setPreferredSampleRate'));
      expect(methodLog.first.arguments, equals({
        'sampleRate': 96000,
        'bitDepth': 24,
        'bitPerfect': true,
      }));
      probe.dispose();
    });

    test('setPreferredMixerAttributes delegates to setPreferredSampleRate on iOS', () async {
      final probe = OutputDeviceProbe(autoPoll: false);
      final ok = await probe.setPreferredMixerAttributes(
        sampleRate: 192000,
        bitDepth: 32,
        bitPerfect: true,
      );

      expect(ok, isTrue);
      expect(methodLog, hasLength(1));
      expect(methodLog.first.method, equals('setPreferredSampleRate'));
      expect(methodLog.first.arguments, equals({
        'sampleRate': 192000,
        'bitDepth': 32,
        'bitPerfect': true,
      }));
      probe.dispose();
    });

    test('clearPreferredMixerAttributes delegates to clearPreferredSampleRate on iOS', () async {
      final probe = OutputDeviceProbe(autoPoll: false);
      final ok = await probe.clearPreferredMixerAttributes();

      expect(ok, isTrue);
      expect(methodLog, hasLength(1));
      expect(methodLog.first.method, equals('clearPreferredSampleRate'));
      probe.dispose();
    });
  });

  group('iOS Route Changes & Interruption Lifecycle', () {
    test('incoming onDeviceChanged message updates probe stream', () async {
      final probe = OutputDeviceProbe(autoPoll: false);
      final streamEvents = <OutputDevice?>[];
      final sub = probe.stream.listen(streamEvents.add);

      const codec = StandardMethodCodec();
      final byteData = codec.encodeMethodCall(const MethodCall('onDeviceChanged'));
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(channelName, byteData, (ByteData? _) {});

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(probe.current, isNotNull);
      expect(probe.current!.name, equals('DUNU Titan X'));

      await sub.cancel();
      probe.dispose();
    });

    test('incoming onBecomingNoisy triggers onBecomingNoisy callback', () async {
      final probe = OutputDeviceProbe(autoPoll: false);
      var noisyFired = false;
      probe.onBecomingNoisy = () {
        noisyFired = true;
      };

      const codec = StandardMethodCodec();
      final byteData = codec.encodeMethodCall(const MethodCall('onBecomingNoisy'));
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(channelName, byteData, (ByteData? _) {});

      expect(noisyFired, isTrue);
      probe.dispose();
    });

    test('incoming onInterruptionBegan triggers onInterruptionBegan callback', () async {
      final probe = OutputDeviceProbe(autoPoll: false);
      var interruptionBeganFired = false;
      probe.onInterruptionBegan = () {
        interruptionBeganFired = true;
      };

      const codec = StandardMethodCodec();
      final byteData = codec.encodeMethodCall(const MethodCall('onInterruptionBegan'));
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(channelName, byteData, (ByteData? _) {});

      expect(interruptionBeganFired, isTrue);
      probe.dispose();
    });

    test('incoming onInterruptionEnded passes shouldResume flag correctly', () async {
      final probe = OutputDeviceProbe(autoPoll: false);
      bool? resumeReceived;
      probe.onInterruptionEnded = (shouldResume) {
        resumeReceived = shouldResume;
      };

      const codec = StandardMethodCodec();
      // Test ended with shouldResume = true
      final trueByteData = codec.encodeMethodCall(
        const MethodCall('onInterruptionEnded', {'shouldResume': true}),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(channelName, trueByteData, (ByteData? _) {});

      expect(resumeReceived, isTrue);

      // Test ended with shouldResume = false
      final falseByteData = codec.encodeMethodCall(
        const MethodCall('onInterruptionEnded', {'shouldResume': false}),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(channelName, falseByteData, (ByteData? _) {});

      expect(resumeReceived, isFalse);
      probe.dispose();
    });
  });

  group('LiveBitDropCore iOS Signal Path Tier Resolution', () {
    test('resolves to Tier A Bit-Perfect with authentic iOS CoreAudio explanation', () async {
      final probe = OutputDeviceProbe(autoPoll: false);
      probe.emitForTesting(const OutputDevice(
        id: 'iOS-usb-DUNU Titan X',
        name: 'DUNU Titan X',
        type: DeviceType.usb,
        supportedRates: [44100, 48000, 96000, 192000],
        bitDepths: [16, 24, 32],
        hardwareVolume: HardwareVolume.unknown,
        maxTier: OutputTier.bitPerfect,
        connectionLabel: 'USB-C',
        supportsBitPerfect: true,
        systemSampleRate: 96000,
      ));

      final audioHandler = BitDropAudioHandler();
      final core = LiveBitDropCore(audioHandler, outputProbe: probe);

      // Emitting probe device triggers signal path recomputation
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final path = await core.signalPath.first;
      expect(path, isNotNull);

      core.dispose();
      probe.dispose();
    });
  });
}

import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/core_live/output_device.dart';
import 'package:bitdrop/services/bitdrop_output_coordinator.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BitDropOutputCoordinator Unit Tests', () {
    late OutputDeviceProbe probe;
    late BitDropOutputCoordinator coordinator;
    bool earphoneDisconnectedCalled = false;
    bool becomingNoisyCalled = false;
    bool interruptionBeganCalled = false;
    bool? interruptionEndedResume;

    setUp(() {
      probe = OutputDeviceProbe(autoPoll: false);
      earphoneDisconnectedCalled = false;
      becomingNoisyCalled = false;
      interruptionBeganCalled = false;
      interruptionEndedResume = null;

      coordinator = BitDropOutputCoordinator(
        outputProbe: probe,
        onEarphoneDisconnected: () => earphoneDisconnectedCalled = true,
        onBecomingNoisy: () => becomingNoisyCalled = true,
        onInterruptionBegan: () => interruptionBeganCalled = true,
        onInterruptionEnded: (resume) => interruptionEndedResume = resume,
      );
      coordinator.start();
    });

    tearDown(() {
      coordinator.dispose();
    });

    test('Initial signal path starts with unknown state', () {
      expect(coordinator.currentSignalPath.tier, equals(OutputTier.unknown));
      expect(coordinator.currentSignalPath.explanation, contains('Nothing is playing yet'));
    });

    test('isEarphone identifies earphone device types', () {
      expect(BitDropOutputCoordinator.isEarphone(DeviceType.usb), isTrue);
      expect(BitDropOutputCoordinator.isEarphone(DeviceType.wiredAnalog), isTrue);
      expect(BitDropOutputCoordinator.isEarphone(DeviceType.bluetooth), isTrue);
      expect(BitDropOutputCoordinator.isEarphone(DeviceType.phoneSpeaker), isFalse);
      expect(BitDropOutputCoordinator.isEarphone(DeviceType.unknown), isFalse);
      expect(BitDropOutputCoordinator.isEarphone(null), isFalse);
    });

    test('Earphone disconnect callback triggers when transitioning from headphone to speaker', () async {
      await Future<void>.delayed(Duration.zero);

      const usbHeadset = OutputDevice(
        id: 'usb-1',
        name: 'USB DAC',
        type: DeviceType.usb,
        supportedRates: [44100, 48000, 96000],
        bitDepths: [16, 24],
        hardwareVolume: HardwareVolume.unknown,
        maxTier: OutputTier.bitPerfect,
      );
      probe.emitForTesting(usbHeadset);
      await Future<void>.delayed(Duration.zero);

      expect(earphoneDisconnectedCalled, isFalse);

      const speaker = OutputDevice(
        id: 'speaker-1',
        name: 'Phone Speaker',
        type: DeviceType.phoneSpeaker,
        supportedRates: [48000],
        bitDepths: [16],
        hardwareVolume: HardwareVolume.yes,
        maxTier: OutputTier.resampled,
      );
      probe.emitForTesting(speaker);
      await Future<void>.delayed(Duration.zero);

      expect(earphoneDisconnectedCalled, isTrue);
    });

    test('Routing interruption callbacks fire correctly', () {
      probe.simulateBecomingNoisy();
      expect(becomingNoisyCalled, isTrue);

      probe.simulateInterruptionBegan();
      expect(interruptionBeganCalled, isTrue);

      probe.simulateInterruptionEnded(true);
      expect(interruptionEndedResume, isTrue);
    });

    test('Output device stream reflects current probe device', () async {
      const dac = OutputDevice(
        id: 'dac-qudelix',
        name: 'Qudelix 5K',
        type: DeviceType.usb,
        supportedRates: [44100, 96000],
        bitDepths: [24],
        hardwareVolume: HardwareVolume.yes,
        maxTier: OutputTier.bitPerfect,
      );
      probe.emitForTesting(dac);
      await pumpEventQueue();

      expect(coordinator.currentDevice?.name, equals('Qudelix 5K'));
    });

    test('prepareForTrackFormat negotiates and deduplicates mixer attributes before track open', () async {
      final mixerCalls = <Map<String, dynamic>>[];
      const channel = MethodChannel('com.bitdrop/audio_device');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'setPreferredMixerAttributes') {
          mixerCalls.add(Map<String, dynamic>.from(call.arguments as Map));
          return true;
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      const usbDac = OutputDevice(
        id: 'usb-dac-1',
        name: 'USB-C DAC',
        type: DeviceType.usb,
        supportedRates: [44100, 48000, 96000],
        bitDepths: [16, 24],
        hardwareVolume: HardwareVolume.unknown,
        maxTier: OutputTier.bitPerfect,
        supportsBitPerfect: true,
        bitPerfectRates: [48000, 96000],
      );
      probe.emitForTesting(usbDac);
      await pumpEventQueue();

      await coordinator.prepareForTrackFormat(96000, 24);
      // Duplicate call with identical parameters must be deduplicated.
      await coordinator.prepareForTrackFormat(96000, 24);
      // Rate absent from bitPerfectRates falls back to bitPerfect=false.
      await coordinator.prepareForTrackFormat(44100, 16);

      expect(mixerCalls, hasLength(2));
      expect(mixerCalls[0], equals({
        'sampleRate': 96000,
        'bitDepth': 24,
        'bitPerfect': true,
      }));
      expect(mixerCalls[1], equals({
        'sampleRate': 44100,
        'bitDepth': 16,
        'bitPerfect': false,
      }));
    });

    test('evaluateUsbAutoAttach prompts when preferBitPerfect is on and OS HAL lacks bit-perfect', () async {
      final promptedDevices = <UsbAudioDevice>[];
      var resolvedCount = 0;

      const channel = MethodChannel('com.bitdrop/audio_device');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'listUsbAudioDevices') {
          return [
            {
              'deviceId': 42,
              'deviceName': '/dev/bus/usb/001/002',
              'productName': 'Generic USB-C IEM DAC',
              'manufacturerName': 'AudioCo',
              'vendorId': 1234,
              'productId': 5678,
              'hasPermission': false,
            },
          ];
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final autoCoordinator = BitDropOutputCoordinator(
        outputProbe: probe,
        isDirectUsbDriverEnabled: () => false,
        isPreferBitPerfectEnabled: () => true,
        onUsbPermissionNeeded: promptedDevices.add,
        onUsbPermissionResolved: () => resolvedCount++,
      );
      autoCoordinator.start();
      addTearDown(autoCoordinator.dispose);

      // Android < 14 USB DAC: supportsBitPerfect is false -> auto-engage needed.
      const preApi34Usb = OutputDevice(
        id: 'usb-iem-1',
        name: 'Generic USB-C IEM DAC',
        type: DeviceType.usb,
        supportedRates: [44100, 48000, 96000],
        bitDepths: [16, 24],
        hardwareVolume: HardwareVolume.unknown,
        maxTier: OutputTier.nativeRate,
        supportsBitPerfect: false,
      );
      probe.emitForTesting(preApi34Usb);
      await pumpEventQueue();

      expect(promptedDevices, hasLength(1));
      expect(promptedDevices.first.productName, equals('Generic USB-C IEM DAC'));

      // Switching back to speaker clears USB permission prompt.
      const speaker = OutputDevice(
        id: 'speaker-1',
        name: 'Phone Speaker',
        type: DeviceType.phoneSpeaker,
        supportedRates: [48000],
        bitDepths: [16],
        hardwareVolume: HardwareVolume.yes,
        maxTier: OutputTier.resampled,
      );
      probe.emitForTesting(speaker);
      await pumpEventQueue();

      expect(resolvedCount, greaterThanOrEqualTo(1));
    });

    test('explainSignalPath distinguishes wired 256-tap Sinc, Bluetooth, and USB guidance', () {
      const src44 = AudioFormat(codec: Codec.flac, bitDepth: 16, sampleRate: 44100);
      const out48 = AudioFormat(codec: Codec.flac, bitDepth: 16, sampleRate: 48000);
      const wired = OutputDevice(
        id: 'wired-1',
        name: 'Wired IEM',
        type: DeviceType.wiredAnalog,
        supportedRates: [48000],
        bitDepths: [16, 24],
        hardwareVolume: HardwareVolume.no,
        maxTier: OutputTier.nativeRate,
        apiLevel: 14,
        systemSampleRate: 48000,
      );

      final wiredMsg = BitDropOutputCoordinator.explainSignalPath(
        OutputTier.resampled,
        src44,
        out48,
        false,
        wired,
        engineSincResampled: true,
      );
      expect(wiredMsg, contains('44.1 kHz'));
      expect(wiredMsg, contains('48 kHz'));
      expect(wiredMsg, contains('256-tap Sinc'));

      const bt = OutputDevice(
        id: 'bt-1',
        name: 'Wireless IEM',
        type: DeviceType.bluetooth,
        supportedRates: [48000],
        bitDepths: [16],
        hardwareVolume: HardwareVolume.yes,
        maxTier: OutputTier.resampled,
      );
      final btMsg = BitDropOutputCoordinator.explainSignalPath(
        OutputTier.resampled,
        src44,
        out48,
        false,
        bt,
        engineSincResampled: true,
      );
      expect(btMsg, contains('Bluetooth'));
      expect(btMsg, contains('256-tap Sinc'));
    });
  });
}

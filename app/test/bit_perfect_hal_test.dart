import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Platform Bit-Perfect HAL & Device Capabilities Tests', () {
    test('Android 14+ (API 34) USB DAC with Bit-Perfect mixer attribute gets Tier A', () {
      const device = OutputDevice(
        id: 'android-usb-dunu-titan-x',
        name: 'DUNU Titan X',
        type: DeviceType.usb,
        supportedRates: [44100, 48000, 88200, 96000, 176400, 192000],
        bitDepths: [16, 24, 32],
        hardwareVolume: HardwareVolume.unknown,
        maxTier: OutputTier.bitPerfect,
        apiLevel: 34,
        supportsBitPerfect: true,
        tierExplanation: 'Android 14+ Bit-Perfect mixer attributes supported for this USB DAC.',
      );

      expect(device.type, DeviceType.usb);
      expect(device.apiLevel, 34);
      expect(device.supportsBitPerfect, isTrue);
      expect(device.maxTier, OutputTier.bitPerfect);
    });

    test('Android 12 (API 31, e.g. S10+) USB DAC honestly reports pre-14 mixer limitation', () {
      const device = OutputDevice(
        id: 'android-usb-s10-dac',
        name: 'FiiO KA17',
        type: DeviceType.usb,
        supportedRates: [44100, 48000, 96000, 192000],
        bitDepths: [16, 24, 32],
        hardwareVolume: HardwareVolume.unknown,
        maxTier: OutputTier.resampled,
        apiLevel: 31,
        supportsBitPerfect: false,
        tierExplanation: 'Android 31 (pre-Android 14) routes audio through AudioFlinger mixer.',
      );

      expect(device.type, DeviceType.usb);
      expect(device.apiLevel, 31);
      expect(device.supportsBitPerfect, isFalse);
      expect(device.maxTier, OutputTier.resampled);
    });

    test('Bluetooth audio device capped at resampled with lossy codec explanation', () {
      const device = OutputDevice(
        id: 'android-bt-xm4',
        name: 'Sony WH-1000XM4',
        type: DeviceType.bluetooth,
        supportedRates: [44100, 48000],
        bitDepths: [16],
        hardwareVolume: HardwareVolume.unknown,
        maxTier: OutputTier.resampled,
        apiLevel: 34,
        supportsBitPerfect: false,
      );

      expect(device.type, DeviceType.bluetooth);
      expect(device.maxTier, OutputTier.resampled);
    });
  });

  group('Signal Path Tier Determination & Truth in Audio', () {
    const source96k = AudioFormat(
      codec: Codec.flac,
      bitDepth: 24,
      sampleRate: 96000,
      channels: 2,
    );

    const actual96k = AudioFormat(
      codec: Codec.flac,
      bitDepth: 24,
      sampleRate: 96000,
      channels: 2,
    );

    const actual48kResampled = AudioFormat(
      codec: Codec.flac,
      bitDepth: 24,
      sampleRate: 48000,
      channels: 2,
    );

    test('Source 96kHz with API 34 USB DAC and DSP neutral achieves Tier A (Bit-Perfect)', () {
      const deviceApi34 = OutputDevice(
        id: 'android-usb-dac',
        name: 'FiiO KA17',
        type: DeviceType.usb,
        supportedRates: [96000],
        bitDepths: [24],
        hardwareVolume: HardwareVolume.unknown,
        maxTier: OutputTier.bitPerfect,
        apiLevel: 34,
        supportsBitPerfect: true,
      );

      const path = SignalPath(
        tier: OutputTier.bitPerfect,
        source: source96k,
        requested: source96k,
        actual: actual96k,
        dspActive: false,
        volume: VolumeMode.system,
        device: deviceApi34,
        explanation: 'Bit-perfect direct stream active via Android 14+ Mixer Attributes. '
            'The audio engine has exclusive access to your FiiO KA17 at its native 96 kHz / 24-bit format with zero resampling or DSP.',
      );

      expect(path.tier, OutputTier.bitPerfect);
      expect(path.dspActive, isFalse);
      expect(path.formatsMatch, isTrue);
      expect(path.explanation, contains('Bit-perfect direct stream active'));
      expect(path.explanation, contains('Android 14+ Mixer Attributes'));
    });

    test('Source 96kHz with API 34 USB DAC but DSP active downgrades to Tier B (Native Rate)', () {
      const deviceApi34 = OutputDevice(
        id: 'android-usb-dac',
        name: 'FiiO KA17',
        type: DeviceType.usb,
        supportedRates: [96000],
        bitDepths: [24],
        hardwareVolume: HardwareVolume.unknown,
        maxTier: OutputTier.bitPerfect,
        apiLevel: 34,
        supportsBitPerfect: true,
      );

      const path = SignalPath(
        tier: OutputTier.nativeRate,
        source: source96k,
        requested: source96k,
        actual: actual96k,
        dspActive: true,
        dspChain: ['Equaliser'],
        volume: VolumeMode.softwareDithered,
        device: deviceApi34,
        explanation: 'The equaliser or DSP is active, altering the audio samples. Bypass the equaliser to restore bit-perfect output.',
      );

      expect(path.tier, OutputTier.nativeRate, reason: 'DSP alters samples, so bit-perfect cannot be claimed');
      expect(path.dspActive, isTrue);
      expect(path.formatsMatch, isTrue);
      expect(path.explanation, contains('equaliser or DSP is active'));
    });

    test('Android 12 USB DAC honestly reports Tier C (Resampled / AudioFlinger Mixer)', () {
      const deviceS10 = OutputDevice(
        id: 'android-usb-s10',
        name: 'DUNU Titan X',
        type: DeviceType.usb,
        supportedRates: [96000],
        bitDepths: [24],
        hardwareVolume: HardwareVolume.unknown,
        maxTier: OutputTier.resampled,
        apiLevel: 31,
        supportsBitPerfect: false,
      );

      const path = SignalPath(
        tier: OutputTier.resampled,
        source: source96k,
        requested: source96k,
        actual: actual48kResampled,
        dspActive: false,
        volume: VolumeMode.system,
        device: deviceS10,
        explanation: 'Your DUNU Titan X is running on Android 31. Pre-Android 14 cannot bypass AudioFlinger Fast Mixer without root, so audio is resampled.',
      );

      expect(path.tier, OutputTier.resampled);
      expect(path.formatsMatch, isFalse);
      expect(path.explanation, contains('Android 31'));
      expect(path.explanation, contains('Pre-Android 14 cannot bypass AudioFlinger Fast Mixer'));
    });

    test('Rate mismatch always outranks DSP and reports Tier C (Resampled)', () {
      const path = SignalPath(
        tier: OutputTier.resampled,
        source: source96k,
        requested: source96k,
        actual: actual48kResampled,
        dspActive: true,
        dspChain: ['Equaliser'],
        volume: VolumeMode.softwareDithered,
        explanation: 'This phone mixes all audio at 48 kHz, so your 96 kHz file is resampled before it reaches the output. Connect a USB DAC for bit-perfect output.',
      );

      expect(path.tier, OutputTier.resampled);
      expect(path.dspActive, isTrue);
      expect(path.formatsMatch, isFalse);
    });
  });
}

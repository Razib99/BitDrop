import 'package:bitdrop/core_api/commands.dart';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/core_mock/mock_core.dart';
import 'package:bitdrop/core_mock/scenarios.dart';
import 'package:flutter_test/flutter_test.dart';

/// The product's central rule: a quality label must never overstate what
/// happened to the samples.
void main() {
  late MockBitDropCore core;

  setUp(() => core = MockBitDropCore(scenario: Scenarios.bitPerfect));
  tearDown(() => core.dispose());

  test('editing the preamp while bypassed does not engage DSP', () async {
    await core.send(const SetPreamp(-6.2));

    // Bypass means bypass: the value is stored but nothing reaches the output,
    // so the tier must not change.
    expect(core.eqValue.preampDb, -6.2);
    expect(core.signalPathValue.dspActive, isFalse);
    expect(core.signalPathValue.tier, OutputTier.bitPerfect);
  });

  test('a bit-perfect device with no DSP reports Bit-perfect', () {
    final path = core.signalPathValue;
    expect(path.tier, OutputTier.bitPerfect);
    expect(path.dspActive, isFalse);
    expect(path.volume, VolumeMode.dacHardware);
    expect(path.formatsMatch, isTrue);
  });

  test('turning on EQ downgrades Bit-perfect to Native rate', () async {
    expect(core.signalPathValue.tier, OutputTier.bitPerfect);

    await core.send(const SetBypass(false));
    await core.send(const SetPreamp(-6.2));

    final path = core.signalPathValue;
    expect(path.tier, OutputTier.nativeRate,
        reason: 'DSP alters samples, so bit-perfect must not be claimed');
    expect(path.dspActive, isTrue);
    expect(path.volume, VolumeMode.softwareDithered);
    expect(path.dspChain, isNotEmpty);
  });

  test('bypassing the EQ restores Bit-perfect', () async {
    await core.send(const SetBypass(false));
    await core.send(const SetPreamp(-6.2));
    expect(core.signalPathValue.tier, OutputTier.nativeRate);

    await core.send(const SetBypass(true));

    expect(core.signalPathValue.tier, OutputTier.bitPerfect);
    expect(core.signalPathValue.dspActive, isFalse);
  });

  test('a resampling platform reports Resampled with the real rate', () {
    final c = MockBitDropCore(scenario: Scenarios.resampled);
    addTearDown(c.dispose);

    final path = c.signalPathValue;
    expect(path.tier, OutputTier.resampled);
    expect(path.actual.sampleRate, 48000);
    expect(path.formatsMatch, isFalse,
        reason: 'the negotiated rate differs from the requested rate');
  });

  test('resampling outranks DSP in the verdict', () async {
    final c = MockBitDropCore(scenario: Scenarios.resampled);
    addTearDown(c.dispose);

    await c.send(const SetBypass(false));
    await c.send(const SetPreamp(-3));

    // Both a rate change and DSP are in play; the rate change is the more
    // severe truth, so it must win.
    expect(c.signalPathValue.tier, OutputTier.resampled);
    expect(c.signalPathValue.dspActive, isTrue);
  });

  test('safety attenuation prevents a bit-perfect claim', () {
    final c = MockBitDropCore(scenario: Scenarios.noHardwareVolume);
    addTearDown(c.dispose);

    final path = c.signalPathValue;
    expect(path.tier, isNot(OutputTier.bitPerfect));
    expect(path.dspActive, isTrue);
    expect(path.safetyAttenuationDb, -12.0);
  });

  test('iOS never reports better than Native rate', () {
    final c = MockBitDropCore(scenario: Scenarios.iosNativeRate);
    addTearDown(c.dispose);

    expect(c.signalPathValue.tier, OutputTier.nativeRate);
  });

  test('every scenario produces a plain-language explanation', () {
    for (final s in Scenarios.all) {
      final c = MockBitDropCore(scenario: s);
      expect(c.signalPathValue.explanation, isNotEmpty,
          reason: 'scenario "${s.id}" must explain its verdict');
      c.dispose();
    }
  });

  test('AudioFormat.effectiveBitrateKbps computes PCM rate or preserves custom bitrate', () {
    const cd = AudioFormat(codec: Codec.flac, bitDepth: 16, sampleRate: 44100);
    expect(cd.effectiveBitrateKbps, 1411);

    const hiRes = AudioFormat(codec: Codec.flac, bitDepth: 24, sampleRate: 96000);
    expect(hiRes.effectiveBitrateKbps, 4608);

    const ultraHiRes = AudioFormat(codec: Codec.flac, bitDepth: 24, sampleRate: 192000);
    expect(ultraHiRes.effectiveBitrateKbps, 9216);

    const mp3 = AudioFormat(codec: Codec.mp3, bitDepth: 16, sampleRate: 44100, bitrateKbps: 320);
    expect(mp3.effectiveBitrateKbps, 320);
  });

  test('SignalPath reports honest bitrates in bit-perfect and resampled scenarios', () {
    final bp = core.signalPathValue;
    // The playing track in Scenarios.bitPerfect is 24/192: 24 * 192000 * 2 / 1000 = 9216 kbps
    expect(bp.actual.sampleRate, 192000);
    expect(bp.actual.effectiveBitrateKbps, 9216);

    final resampledCore = MockBitDropCore(scenario: Scenarios.resampled);
    addTearDown(resampledCore.dispose);
    final resampledPath = resampledCore.signalPathValue;
    // Resampled scenario outputs 24-bit 48000 Hz: 24 * 48000 * 2 / 1000 = 2304 kbps
    expect(resampledPath.actual.sampleRate, 48000);
    expect(resampledPath.actual.effectiveBitrateKbps, 2304);
  });
}

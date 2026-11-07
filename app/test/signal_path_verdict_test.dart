import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/theme/app_theme.dart';
import 'package:bitdrop/widgets/signal_path_diagram.dart';
import 'package:bitdrop/features/now_playing/now_playing_screen.dart';

import 'package:bitdrop/l10n/app_localizations.dart';

void main() {
  Widget wrapWithTheme(Widget child) {
    return MaterialApp(
      theme: AppTheme.dark(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );
  }

  const dacDeviceS10 = OutputDevice(
    id: 'android-usb-dunu',
    name: 'DUNU Titan X',
    type: DeviceType.usb,
    supportedRates: [44100, 48000, 96000, 192000],
    bitDepths: [16, 24],
    hardwareVolume: HardwareVolume.yes,
    apiLevel: 31,
    supportsBitPerfect: false,
    systemSampleRate: 48000,
  );

  const dacDeviceBitPerfect = OutputDevice(
    id: 'android-usb-dunu-bp',
    name: 'DUNU Titan X',
    type: DeviceType.usb,
    supportedRates: [44100, 48000, 96000, 192000],
    bitDepths: [16, 24],
    hardwareVolume: HardwareVolume.yes,
    apiLevel: 34,
    supportsBitPerfect: true,
    systemSampleRate: 48000,
  );

  group('Signal Path Reporting & Hardware Rate Disentanglement', () {
    testWidgets(
        'Case 1: Bit-Perfect Tier A renders emerald badge with source rate/bit-depth',
        (tester) async {
      const source =
          AudioFormat(codec: Codec.flac, bitDepth: 24, sampleRate: 96000);
      const path = SignalPath(
        tier: OutputTier.bitPerfect,
        source: source,
        requested: source,
        actual: source,
        dspActive: false,
        volume: VolumeMode.dacHardware,
        device: dacDeviceBitPerfect,
        explanation: 'Bit-perfect direct stream active.',
      );

      await tester.pumpWidget(wrapWithTheme(
        const Column(
          children: [
            NowPlayingSignalChip(signal: path),
            SignalPathDiagram(path: path),
          ],
        ),
      ));

      expect(find.text('BIT-PERFECT'), findsOneWidget);
      expect(find.text('Bit-Perfect'), findsOneWidget);
      expect(find.text('96 kHz / 24-bit'), findsWidgets);
      expect(find.textContaining('Direct bit-perfect access'), findsOneWidget);
    });

    testWidgets(
        'Case 2: Native Rate + 64-Bit DSP renders cyan badge with Native {sr} kHz',
        (tester) async {
      const source =
          AudioFormat(codec: Codec.flac, bitDepth: 24, sampleRate: 48000);
      const path = SignalPath(
        tier: OutputTier.nativeRate,
        source: source,
        requested: source,
        actual: source,
        dspActive: true,
        dspChain: ['Equaliser'],
        volume: VolumeMode.softwareDithered,
        device: dacDeviceS10,
        explanation: 'Audio is running at native 48 kHz. Equaliser active.',
      );

      await tester.pumpWidget(wrapWithTheme(
        const Column(
          children: [
            NowPlayingSignalChip(signal: path),
            SignalPathDiagram(path: path),
          ],
        ),
      ));

      expect(find.text('64-BIT DSP'), findsOneWidget);
      expect(find.text('64-Bit DSP'), findsOneWidget);
      expect(find.text('Native 48 kHz'), findsWidgets);
    });

    testWidgets(
        'Case 3: Native Rate · Android Mixed renders neutral/sky blue badge and NEVER says Resampled 44.1 -> 44.1',
        (tester) async {
      const source =
          AudioFormat(codec: Codec.flac, bitDepth: 16, sampleRate: 44100);
      const path = SignalPath(
        tier: OutputTier.nativeRate,
        source: source,
        requested: source,
        actual: source,
        dspActive: false,
        volume: VolumeMode.system,
        device: dacDeviceS10,
        explanation:
            'Your DUNU Titan X is running at native 44 kHz, routed through Android 31 system mixer (AudioFlinger).',
      );

      await tester.pumpWidget(wrapWithTheme(
        const Column(
          children: [
            NowPlayingSignalChip(signal: path),
            SignalPathDiagram(path: path),
          ],
        ),
      ));

      // Must show Native Rate badge
      expect(find.text('NATIVE RATE (44.1 kHz)'), findsOneWidget);
      expect(find.text('Native Rate (44.1 kHz)'), findsOneWidget);
      expect(find.text('Android Mixed'), findsWidgets);

      // Must NEVER display "Resampled 44.1 -> 44.1" or "44.1 -> 44.1 kHz"
      expect(find.textContaining('44.1 → 44.1'), findsNothing);
      expect(find.textContaining('Resampled · 44.1 → 44.1'), findsNothing);
    });

    testWidgets(
        'Case 4: Resampled 44.1 -> 48 kHz renders amber badge with rate transition',
        (tester) async {
      const source =
          AudioFormat(codec: Codec.flac, bitDepth: 16, sampleRate: 44100);
      const actual =
          AudioFormat(codec: Codec.flac, bitDepth: 16, sampleRate: 48000);
      const path = SignalPath(
        tier: OutputTier.resampled,
        source: source,
        requested: source,
        actual: actual,
        dspActive: false,
        volume: VolumeMode.system,
        device: dacDeviceS10,
        explanation:
            'This phone mixes all audio at 48 kHz, so your 44 kHz file is resampled.',
      );

      await tester.pumpWidget(wrapWithTheme(
        const Column(
          children: [
            NowPlayingSignalChip(signal: path),
            SignalPathDiagram(path: path),
          ],
        ),
      ));

      expect(find.text('RESAMPLED'), findsOneWidget);
      expect(find.text('Resampled'), findsOneWidget);
      expect(find.text('44.1 → 48 kHz'), findsWidgets);
    });

    testWidgets(
        'Device node clearly separates DAC Hardware Capability from OS Routing Ceiling',
        (tester) async {
      const source =
          AudioFormat(codec: Codec.flac, bitDepth: 16, sampleRate: 44100);
      const path = SignalPath(
        tier: OutputTier.nativeRate,
        source: source,
        requested: source,
        actual: source,
        dspActive: false,
        volume: VolumeMode.system,
        device: dacDeviceS10,
        explanation: 'Test explanation',
      );

      await tester
          .pumpWidget(wrapWithTheme(const SignalPathDiagram(path: path)));

      // Verifies hardware capability up to 192 kHz / 24-bit with OS routing ceiling Android 31
      expect(
        find.textContaining(
            'Hardware supports up to 192 kHz / 24-bit · Routed via Android 31 system mixer'),
        findsOneWidget,
      );
    });

    testWidgets(
        'Output node renders "Native rate · System mixed" on untouched OS-routed stream',
        (tester) async {
      const source =
          AudioFormat(codec: Codec.flac, bitDepth: 16, sampleRate: 44100);
      const path = SignalPath(
        tier: OutputTier.nativeRate,
        source: source,
        requested: source,
        actual: source,
        dspActive: false,
        volume: VolumeMode.system,
        device: dacDeviceS10,
        explanation: 'Routed via Android mixer without resampling.',
      );

      await tester
          .pumpWidget(wrapWithTheme(const SignalPathDiagram(path: path)));

      expect(find.text('Native rate · System mixed'), findsOneWidget);
    });

    testWidgets(
        'Output node renders "Native rate · 64-bit DSP" when DSP equaliser is active',
        (tester) async {
      const source =
          AudioFormat(codec: Codec.flac, bitDepth: 24, sampleRate: 48000);
      const path = SignalPath(
        tier: OutputTier.nativeRate,
        source: source,
        requested: source,
        actual: source,
        dspActive: true,
        dspChain: ['Equaliser'],
        volume: VolumeMode.softwareDithered,
        device: dacDeviceS10,
        explanation: 'Audio is running at native 48 kHz with equaliser.',
      );

      await tester
          .pumpWidget(wrapWithTheme(const SignalPathDiagram(path: path)));

      expect(find.text('Native rate · 64-bit DSP'), findsOneWidget);
    });

    testWidgets(
        'DSD signal path renders DoP v1.1 bitstream framing for direct bit-perfect USB',
        (tester) async {
      const source =
          AudioFormat(codec: Codec.dsf, bitDepth: 1, sampleRate: 2822400);
      const actual =
          AudioFormat(codec: Codec.dsf, bitDepth: 24, sampleRate: 176400);
      const path = SignalPath(
        tier: OutputTier.bitPerfect,
        source: source,
        requested: source,
        actual: actual,
        dspActive: false,
        volume: VolumeMode.dacHardware,
        device: dacDeviceBitPerfect,
        decoderLabel: 'DSD64 Bitstream -> DoP v1.1 Framing',
        explanation:
            'Bit-perfect direct DSD stream active via User-Space USB Audio (Tier D) with DoP v1.1 framing.',
      );

      await tester
          .pumpWidget(wrapWithTheme(const SignalPathDiagram(path: path)));

      expect(find.text('Bit-Perfect'), findsOneWidget);
      expect(find.text('DSD64 Bitstream -> DoP v1.1 Framing'), findsOneWidget);
      expect(
        find.textContaining(
            'Bit-perfect direct DSD stream active via User-Space USB Audio (Tier D) with DoP v1.1 framing.'),
        findsOneWidget,
      );
    });

    testWidgets(
        'DSD signal path renders polyphase FIR decimation when playing via PCM engine',
        (tester) async {
      const source =
          AudioFormat(codec: Codec.dsf, bitDepth: 1, sampleRate: 2822400);
      const actual =
          AudioFormat(codec: Codec.dsf, bitDepth: 24, sampleRate: 176400);
      const path = SignalPath(
        tier: OutputTier.bitPerfect,
        source: source,
        requested: source,
        actual: actual,
        dspActive: false,
        volume: VolumeMode.dacHardware,
        device: dacDeviceBitPerfect,
        decoderLabel: 'DSD64 -> 176.4 kHz / 24-bit Polyphase FIR Decimation',
        explanation:
            'DSD 1-bit stream decimated to 176.4 kHz / 24-bit PCM using 64-bit polyphase sinc FIR filter.',
      );

      await tester
          .pumpWidget(wrapWithTheme(const SignalPathDiagram(path: path)));

      expect(find.text('DSD64 -> 176.4 kHz / 24-bit Polyphase FIR Decimation'),
          findsOneWidget);
      expect(
        find.textContaining(
            'DSD 1-bit stream decimated to 176.4 kHz / 24-bit PCM'),
        findsOneWidget,
      );
    });
  });
}

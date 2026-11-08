import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/theme/app_theme.dart';
import 'package:bitdrop/widgets/signal_path_diagram.dart';
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

  group('Hardware Telemetry Inspector Tests', () {
    testWidgets('Renders Tier D direct usbfs telemetry with endpoint details',
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
        device: OutputDevice(
          id: 'android-usb-fiio',
          name: 'FiiO KA17',
          type: DeviceType.usb,
          supportedRates: [44100, 48000, 96000, 192000, 384000, 768000],
          bitDepths: [16, 24, 32],
          hardwareVolume: HardwareVolume.yes,
          connectionLabel: 'USB-C',
          supportsBitPerfect: true,
        ),
        explanation: 'Direct USB (Tier D) bit-perfect stream.',
      );

      await tester.pumpWidget(wrapWithTheme(
        const SignalPathDiagram(path: path),
      ));

      expect(find.text('HARDWARE TELEMETRY INSPECTOR'), findsOneWidget);
      expect(find.text('TIER D USBFS'), findsOneWidget);
      expect(find.text('FiiO KA17'), findsWidgets);
      expect(find.text('USB-C'), findsWidgets);
      expect(find.text('Endpoint Pacing Mode'), findsOneWidget);
      expect(find.text('Live URB Underruns'), findsOneWidget);
      expect(find.text('DAC Hardware Register (Lossless)'), findsOneWidget);
      expect(find.text('MATCH'), findsOneWidget);
    });

    testWidgets(
        'Renders Android 14+ MIXER_BEHAVIOR_BIT_PERFECT attributes with sample rates',
        (tester) async {
      const source =
          AudioFormat(codec: Codec.flac, bitDepth: 24, sampleRate: 192000);
      const path = SignalPath(
        tier: OutputTier.bitPerfect,
        source: source,
        requested: source,
        actual: source,
        dspActive: false,
        volume: VolumeMode.softwareDithered,
        device: OutputDevice(
          id: 'android-usb-dunu',
          name: 'DUNU Titan X',
          type: DeviceType.usb,
          supportedRates: [44100, 48000, 96000, 192000],
          bitDepths: [16, 24],
          hardwareVolume: HardwareVolume.unknown,
          connectionLabel: 'USB-C',
          apiLevel: 34,
          supportsBitPerfect: true,
          bitPerfectRates: [44100, 48000, 96000, 192000],
        ),
        explanation: 'Android 14+ bit-perfect output.',
      );

      await tester.pumpWidget(wrapWithTheme(
        const SignalPathDiagram(path: path),
      ));

      expect(find.text('HARDWARE TELEMETRY INSPECTOR'), findsOneWidget);
      expect(find.text('API 34 BIT-PERFECT'), findsOneWidget);
      expect(find.text('MIXER_BEHAVIOR_BIT_PERFECT'), findsOneWidget);
      expect(find.text('Bit-Perfect Rates'), findsOneWidget);
      expect(find.text('44.1, 48, 96, 192 kHz'), findsWidgets);
      expect(find.text('Double-Precision f64 TPDF Dithered'), findsOneWidget);
    });

    testWidgets('Renders System Mixer info with rate mismatch badge',
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
        device: OutputDevice(
          id: 'android-speaker',
          name: 'Phone Speaker',
          type: DeviceType.phoneSpeaker,
          supportedRates: [48000],
          bitDepths: [16],
          hardwareVolume: HardwareVolume.yes,
          apiLevel: 33,
          supportsBitPerfect: false,
          systemSampleRate: 48000,
        ),
        explanation: 'Resampled to 48 kHz by system.',
      );

      await tester.pumpWidget(wrapWithTheme(
        const SignalPathDiagram(path: path),
      ));

      expect(find.text('HARDWARE TELEMETRY INSPECTOR'), findsOneWidget);
      expect(find.text('SYSTEM MIXER'), findsOneWidget);
      expect(find.text('Android 33 AudioFlinger (48000 Hz)'), findsOneWidget);
      expect(find.text('MISMATCH'), findsOneWidget);
    });
  });
}

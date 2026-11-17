import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/core_api/settings.dart';
import 'package:bitdrop/features/output/output_screen.dart';
import 'package:bitdrop/l10n/app_localizations.dart';
import 'package:bitdrop/providers/core_providers.dart';
import 'package:bitdrop/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget wrapScreen({
    OutputDevice? device,
    SignalPath? signal,
    List<DeviceProfile> profiles = const [],
    AppSettings settings = const AppSettings(),
  }) {
    return ProviderScope(
      overrides: [
        outputDeviceProvider.overrideWith((ref) => Stream.value(device)),
        signalPathProvider.overrideWith(
          (ref) => Stream.value(
            signal ??
                const SignalPath(
                  tier: OutputTier.unknown,
                  source: AudioFormat(codec: Codec.flac, bitDepth: 0, sampleRate: 0),
                  requested:
                      AudioFormat(codec: Codec.flac, bitDepth: 0, sampleRate: 0),
                  actual: AudioFormat(codec: Codec.flac, bitDepth: 0, sampleRate: 0),
                  dspActive: false,
                  volume: VolumeMode.system,
                  explanation: 'Idle',
                ),
          ),
        ),
        deviceProfilesProvider.overrideWith((ref) => Stream.value(profiles)),
        settingsProvider.overrideWith((ref) => Stream.value(settings)),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const OutputScreen(),
      ),
    );
  }

  group('OutputScreen Tests', () {
    testWidgets('Shows Direct USB unlock CTA for non-bit-perfect USB DAC without mock leakage',
        (tester) async {
      const usbDac = OutputDevice(
        id: 'android-usb-Moondrop Dawn Pro',
        name: 'Moondrop Dawn Pro',
        type: DeviceType.usb,
        supportedRates: [44100, 48000, 96000],
        bitDepths: [16, 24],
        hardwareVolume: HardwareVolume.unknown,
        maxTier: OutputTier.nativeRate,
        connectionLabel: 'USB-C',
      );
      const src = AudioFormat(codec: Codec.flac, bitDepth: 16, sampleRate: 44100);
      const out = AudioFormat(codec: Codec.flac, bitDepth: 16, sampleRate: 48000);
      const path = SignalPath(
        tier: OutputTier.resampled,
        source: src,
        requested: src,
        actual: out,
        dspActive: false,
        volume: VolumeMode.system,
        device: usbDac,
        explanation: 'Resampled through Android mixer.',
      );

      await tester.pumpWidget(wrapScreen(
        device: usbDac,
        signal: path,
        profiles: const [
          DeviceProfile(
            deviceId: 'android-usb-Moondrop Dawn Pro',
            deviceName: 'Moondrop Dawn Pro',
            replayGain: ReplayGainMode.off,
          ),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('Unlock Direct USB Bit-Perfect'), findsOneWidget);
      expect(find.text('Moondrop Dawn Pro'), findsWidgets);
      expect(find.text('Schiit Hel'), findsNothing);
      expect(find.text('Qudelix 5K'), findsNothing);
    });

    testWidgets('Shows neutral prompt when no profiles saved and no device connected',
        (tester) async {
      await tester.pumpWidget(wrapScreen());
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Saved devices'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Saved devices'), findsOneWidget);
      expect(
        find.textContaining('Connect any IEM, headphone, or USB DAC'),
        findsOneWidget,
      );
    });
  });
}

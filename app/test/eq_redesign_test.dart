import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/core_mock/mock_core.dart';
import 'package:bitdrop/features/equalizer/equalizer_screen.dart';
import 'package:bitdrop/l10n/app_localizations.dart';
import 'package:bitdrop/providers/core_providers.dart';
import 'package:bitdrop/theme/app_theme.dart';
import 'package:bitdrop/util/biquad.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Pultec Bass Contour & Smart Headroom Biquad Math', () {
    test('fromTone adds 185 Hz mud dip only for positive bass boost', () {
      final flat = Biquad.fromTone(0.0, 0.0);
      expect(flat, isEmpty);

      final cut = Biquad.fromTone(-4.0, 0.0);
      expect(cut.length, 1);

      final boost = Biquad.fromTone(6.0, 2.0, bassFreqHz: 65.0);
      expect(boost.length, 3);
      expect(boost[0].type, BiquadType.lowShelf);
      expect(boost[0].frequencyHz, 65.0);
      expect(boost[1].type, BiquadType.peak);
      expect(boost[1].frequencyHz, 185.0);
      expect(boost[1].gainDb, lessThan(0.0));
      expect(boost[2].type, BiquadType.highShelf);

      // Verify net boost at 35 Hz exceeds 185 Hz (tight punchy bass without mud)
      final subGain = Biquad.combinedDb(boost, 35.0);
      final mudGain = Biquad.combinedDb(boost, 185.0);
      expect(subGain, greaterThan(4.5));
      expect(subGain - mudGain, greaterThan(2.5));
    });

    test('fromGraphicGains converts band 0 to 38 Hz LowShelf and preserves 25 Hz',
        () {
      final gains = [6.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
      final bands = Biquad.fromGraphicGains(gains, Biquad.isoGraphicCenters);
      expect(bands.length, 10);
      expect(bands[0].type, BiquadType.lowShelf);
      expect(bands[0].frequencyHz, 38.0);
      expect(bands[0].q, 0.75);
      expect(bands[1].q, 1.15);

      expect(Biquad.combinedDb(bands, 25.0), greaterThan(4.5));
    });

    test('composeBands runs Tone Contour simultaneously with Graphic EQ', () {
      const state = EqState(
        mode: EqMode.graphic,
        bands: [],
        preampDb: 0.0,
        bypass: false,
        bassDb: 6.0,
        trebleDb: 2.0,
        graphicGains: [2.0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      );
      final composed = Biquad.composeBands(state);
      // 3 tone bands (shelf + mud dip + treble) + 10 graphic bands = 13
      expect(composed.length, 13);
      expect(Biquad.combinedDb(composed, 30.0), greaterThan(6.5));
    });

    test('smartHeadroomDb applies ~25% trim on bass boosts unlike strict peak',
        () {
      final toneOnly = Biquad.fromTone(8.0, 0.0);
      final smart = Biquad.smartHeadroomDb(toneOnly);
      final strict = Biquad.suggestedPreamp(toneOnly);

      expect(smart, greaterThan(-2.5));
      expect(smart, lessThan(-1.5));
      expect(strict, lessThan(-7.0));
      expect(smart - strict, greaterThan(5.0));
    });
  });

  group('Redesigned Studio EqualizerScreen Widget', () {
    testWidgets(
        'renders Tone Contour deck, Headroom cycling pill, and Deep Bass preset',
        (tester) async {
      final core = MockBitDropCore();
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [coreProvider.overrideWithValue(core)],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: AppTheme.light(),
              home: const EqualizerScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Tone Contour'), findsOneWidget);
        expect(find.text('40 Hz'), findsOneWidget);
        expect(find.text('65 Hz'), findsOneWidget);
        expect(find.text('85 Hz'), findsOneWidget);
        expect(find.text('Headroom: Smart'), findsOneWidget);

        // Cycle headroom Smart -> Strict -> Off
        await tester.tap(find.text('Headroom: Smart'));
        await tester.pumpAndSettle();
        expect(find.text('Headroom: Strict'), findsOneWidget);

        await tester.tap(find.text('Headroom: Strict'));
        await tester.pumpAndSettle();
        expect(find.text('Headroom: Off'), findsOneWidget);

        // Switch bass shelf corner to 40 Hz sub-bass
        await tester.ensureVisible(find.text('40 Hz'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('40 Hz'));
        await tester.pumpAndSettle();
        final eqAfterFreq = await core.eq.first;
        expect(eqAfterFreq.bassFreqHz, 40.0);

        // Scroll down to Quick Presets and tap Deep Bass
        await tester.scrollUntilVisible(
          find.text('Deep Bass'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(find.text('Deep Bass'), findsOneWidget);
        await tester.tap(find.text('Deep Bass'));
        await tester.pumpAndSettle();
        final eqAfterPreset = await core.eq.first;
        expect(eqAfterPreset.bassDb, 6.5);
        expect(eqAfterPreset.trebleDb, 1.0);
      } finally {
        core.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  });
}

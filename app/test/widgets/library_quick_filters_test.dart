import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/core_api/queries.dart';
import 'package:bitdrop/core_mock/mock_core.dart';
import 'package:bitdrop/features/library/library_screen.dart';
import 'package:bitdrop/l10n/app_localizations.dart';
import 'package:bitdrop/providers/core_providers.dart';
import 'package:bitdrop/theme/app_theme.dart';
import 'package:bitdrop/widgets/rows.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('QualityFilter.lossless & LibraryFilters matchers', () {
    const cdFlac =
        AudioFormat(codec: Codec.flac, bitDepth: 16, sampleRate: 44100);
    const hiResFlac =
        AudioFormat(codec: Codec.flac, bitDepth: 24, sampleRate: 96000);
    const cdAlac =
        AudioFormat(codec: Codec.alac, bitDepth: 16, sampleRate: 44100);
    const wav = AudioFormat(codec: Codec.wav, bitDepth: 24, sampleRate: 48000);
    const dsd =
        AudioFormat(codec: Codec.dsf, bitDepth: 1, sampleRate: 2822400);
    const mp3 = AudioFormat(
      codec: Codec.mp3,
      bitDepth: 16,
      sampleRate: 44100,
      bitrateKbps: 320,
    );
    const aac = AudioFormat(
      codec: Codec.aac,
      bitDepth: 16,
      sampleRate: 44100,
      bitrateKbps: 256,
    );
    const ape = AudioFormat(codec: Codec.ape, bitDepth: 16, sampleRate: 44100);

    test('QualityFilter.lossless matches all supported lossless formats', () {
      expect(QualityFilter.lossless.matches(cdFlac), isTrue);
      expect(QualityFilter.lossless.matches(hiResFlac), isTrue);
      expect(QualityFilter.lossless.matches(cdAlac), isTrue);
      expect(QualityFilter.lossless.matches(wav), isTrue);
      expect(QualityFilter.lossless.matches(dsd), isTrue);

      expect(QualityFilter.lossless.matches(mp3), isFalse);
      expect(QualityFilter.lossless.matches(aac), isFalse);
      expect(QualityFilter.lossless.matches(ape), isFalse);
    });

    test('QualityFilter.hiRes excludes standard 16/44.1 CD lossless', () {
      expect(QualityFilter.hiRes.matches(hiResFlac), isTrue);
      expect(QualityFilter.hiRes.matches(dsd), isTrue);
      expect(QualityFilter.hiRes.matches(cdFlac), isFalse);
      expect(QualityFilter.hiRes.matches(mp3), isFalse);
    });

    test('AvailabilityFilter.cached includes cached and pinned only', () {
      expect(AvailabilityFilter.cached.matches(Availability.cached), isTrue);
      expect(AvailabilityFilter.cached.matches(Availability.pinned), isTrue);
      expect(
          AvailabilityFilter.cached.matches(Availability.cloudOnly), isFalse);
    });
  });

  group('LibraryScreen quick-filter bar', () {
    late MockBitDropCore core;

    setUp(() {
      core = MockBitDropCore();
    });

    tearDown(() {
      core.dispose();
    });

    Future<ProviderContainer> pumpLibrary(WidgetTester tester) async {
      final container = ProviderContainer(
        overrides: [
          coreProvider.overrideWithValue(core),
          libraryTabProvider.overrideWith((ref) => LibraryTab.tracks),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: LibraryScreen()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      return container;
    }

    testWidgets('shows All, Lossless, Hi-Res, On Device chips and filters tracks',
        (tester) async {
      final container = await pumpLibrary(tester);

      expect(find.text('All'), findsOneWidget);
      expect(find.text('Lossless'), findsOneWidget);
      expect(find.text('Hi-Res'), findsOneWidget);
      expect(find.text('On Device'), findsOneWidget);

      // Tap Lossless -> filters to supported lossless tracks only
      await tester.tap(find.text('Lossless'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        container.read(libraryFiltersProvider).quality,
        QualityFilter.lossless,
      );
      final losslessRows = tester.widgetList<TrackRow>(find.byType(TrackRow));
      expect(losslessRows, isNotEmpty);
      for (final row in losslessRows) {
        expect(row.track.format.codec.isLossless, isTrue);
        expect(row.track.format.codec.isSupported, isTrue);
      }

      // Tap Hi-Res -> switches to Hi-Res quality filter
      await tester.tap(find.text('Hi-Res'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        container.read(libraryFiltersProvider).quality,
        QualityFilter.hiRes,
      );
      final hiResRows = tester.widgetList<TrackRow>(find.byType(TrackRow));
      expect(hiResRows, isNotEmpty);
      for (final row in hiResRows) {
        expect(row.track.format.isHiRes, isTrue);
      }

      // Compose with On Device -> filters to cached or pinned Hi-Res tracks
      await tester.tap(find.text('On Device'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        container.read(libraryFiltersProvider).availability,
        AvailabilityFilter.cached,
      );
      for (final row in tester.widgetList<TrackRow>(find.byType(TrackRow))) {
        expect(row.track.format.isHiRes, isTrue);
        expect(
          row.track.availability == Availability.cached ||
              row.track.availability == Availability.pinned,
          isTrue,
        );
      }

      // Tap All -> resets all active filters
      await tester.tap(find.text('All'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(container.read(libraryFiltersProvider).isActive, isFalse);
    });
  });
}

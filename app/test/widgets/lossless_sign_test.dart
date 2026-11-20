import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/l10n/app_localizations.dart';
import 'package:bitdrop/theme/app_theme.dart';
import 'package:bitdrop/widgets/indicators.dart';
import 'package:bitdrop/widgets/rows.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      );

  Track makeTrack(AudioFormat format) => Track(
        id: 't-${format.codec.name}-${format.sampleRate}',
        title: 'Sample Track',
        artist: 'Artist',
        albumId: 'a1',
        albumTitle: 'Album',
        durationMs: 210000,
        format: format,
        availability: Availability.cached,
        sizeBytes: 25000000,
        artwork: const Artwork(seed: 1, dominantColor: 0xFF223344),
        folderPath: 'Music',
      );

  group('Lossless & Hi-Res track list indicators', () {
    testWidgets('CD Lossless FLAC shows LosslessWaveGlyph in TrackRow and FormatBadge',
        (tester) async {
      final track = makeTrack(
        const AudioFormat(codec: Codec.flac, bitDepth: 16, sampleRate: 44100),
      );
      await tester.pumpWidget(wrap(TrackRow(track: track)));

      // Both subtitle inline sign and right-hand FormatBadge show LosslessWaveGlyph
      expect(find.byType(LosslessWaveGlyph), findsNWidgets(2));
      expect(find.byIcon(Icons.diamond_rounded), findsNothing);
      expect(find.byIcon(Icons.diamond_outlined), findsNothing);
      expect(find.text('16/44.1'), findsOneWidget);
    });

    testWidgets('Hi-Res FLAC 24/96 shows diamond glyphs without CD wave glyph',
        (tester) async {
      final track = makeTrack(
        const AudioFormat(codec: Codec.flac, bitDepth: 24, sampleRate: 96000),
      );
      await tester.pumpWidget(wrap(TrackRow(track: track)));

      expect(find.byIcon(Icons.diamond_rounded), findsOneWidget);
      expect(find.byIcon(Icons.diamond_outlined), findsOneWidget);
      expect(find.byType(LosslessWaveGlyph), findsNothing);
      expect(find.text('24/96'), findsOneWidget);
    });

    testWidgets('Lossy MP3 320k shows no lossless or Hi-Res sign',
        (tester) async {
      final track = makeTrack(
        const AudioFormat(
          codec: Codec.mp3,
          bitDepth: 16,
          sampleRate: 44100,
          bitrateKbps: 320,
        ),
      );
      await tester.pumpWidget(wrap(TrackRow(track: track)));

      expect(find.byType(LosslessWaveGlyph), findsNothing);
      expect(find.byIcon(Icons.diamond_rounded), findsNothing);
      expect(find.byIcon(Icons.diamond_outlined), findsNothing);
      expect(find.text('320 kbps'), findsOneWidget);
    });
  });
}

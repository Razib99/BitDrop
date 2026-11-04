import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/l10n/app_localizations.dart';
import 'package:bitdrop/theme/app_theme.dart';
import 'package:bitdrop/widgets/indicators.dart';
import 'package:bitdrop/widgets/rows.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _buildWrapper(Widget child) {
  return MaterialApp(
    theme: AppTheme.dark(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Center(child: child),
    ),
  );
}

void main() {
  const dummyTrack = Track(
    id: 'track-test-1',
    title: 'Dancing In The Dark',
    artist: 'Mira Okafor',
    albumId: 'album-1',
    albumTitle: 'Glass Harbor',
    trackNumber: 3,
    discNumber: 1,
    durationMs: 240000,
    sizeBytes: 1024 * 1024 * 20,
    artwork: Artwork(seed: 42, dominantColor: 0xFF223344),
    format: AudioFormat(
      codec: Codec.flac,
      bitDepth: 24,
      sampleRate: 96000,
      channels: 2,
    ),
    availability: Availability.cached,
  );

  testWidgets('MiniBarsIndicator builds and animates', (tester) async {
    await tester.pumpWidget(_buildWrapper(const MiniBarsIndicator(isDancing: true)));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(MiniBarsIndicator), findsOneWidget);
  });

  testWidgets('TrackRow renders MiniBarsIndicator on artwork when isPlaying is true', (tester) async {
    await tester.pumpWidget(_buildWrapper(
      const TrackRow(
        track: dummyTrack,
        isPlaying: true,
        isDancing: true,
        showArt: true,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(MiniBarsIndicator), findsOneWidget);
    expect(find.text('Dancing In The Dark'), findsOneWidget);
  });

  testWidgets('TrackRow does not render MiniBarsIndicator when isPlaying is false', (tester) async {
    await tester.pumpWidget(_buildWrapper(
      const TrackRow(
        track: dummyTrack,
        isPlaying: false,
        showArt: true,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(MiniBarsIndicator), findsNothing);
  });

  testWidgets('TrackRow replaces track number with MiniBarsIndicator when showTrackNumber is true and isPlaying is true', (tester) async {
    await tester.pumpWidget(_buildWrapper(
      const TrackRow(
        track: dummyTrack,
        isPlaying: true,
        isDancing: true,
        showTrackNumber: true,
        showArt: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(MiniBarsIndicator), findsOneWidget);
    // Track number '3' should be replaced by MiniBarsIndicator
    expect(find.text('3'), findsNothing);
  });
}

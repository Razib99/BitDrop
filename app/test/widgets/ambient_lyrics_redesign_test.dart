import 'package:bitdrop/core_api/bitdrop_core.dart';
import 'package:bitdrop/core_api/commands.dart';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/features/now_playing/ambient_lyrics_view.dart';
import 'package:bitdrop/l10n/app_localizations.dart';
import 'package:bitdrop/providers/core_providers.dart';
import 'package:bitdrop/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingCore extends Fake implements BitDropCore {
  final List<PlayerCommand> commands = [];

  @override
  Future<void> send(PlayerCommand cmd) async {
    commands.add(cmd);
  }
}

void main() {
  const track = Track(
    id: 'lyrics-track-1',
    title: 'Starless',
    artist: 'King Crimson',
    albumId: 'red',
    albumTitle: 'Red',
    durationMs: 742000,
    format: AudioFormat(codec: Codec.flac, bitDepth: 24, sampleRate: 96000),
    availability: Availability.cached,
    sizeBytes: 120000000,
    artwork: Artwork(seed: 42, dominantColor: 0xFF990000),
  );

  Widget wrap(
    Widget child, {
    required _RecordingCore core,
    required TrackLyrics lyrics,
    int positionMs = 0,
  }) =>
      ProviderScope(
        overrides: [
          coreProvider.overrideWithValue(core),
          lyricsProvider(track).overrideWith((ref) => lyrics),
          positionProvider.overrideWith(
            (ref) => Stream.value(
              PositionInfo(positionMs: positionMs, durationMs: 742000),
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SizedBox(height: 420, child: child)),
        ),
      );

  group('Phase 3 Step 1: AmbientLyricsView foundation', () {
    testWidgets('uses ShaderMask edge fade and tap-to-seek sends Seek command',
        (tester) async {
      final core = _RecordingCore();
      const lyrics = TrackLyrics(
        synced: true,
        lines: [
          LyricLine(timestampMs: 0, text: 'Sundown dazzling day'),
          LyricLine(timestampMs: 45000, text: 'Gold through my eyes'),
          LyricLine(timestampMs: 70000, text: ''),
          LyricLine(timestampMs: 90000, text: 'Starless and bible black'),
        ],
        plainLyrics: '',
      );

      await tester.pumpWidget(
        wrap(
          const AmbientLyricsView(track: track),
          core: core,
          lyrics: lyrics,
          positionMs: 50000,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ShaderMask), findsOneWidget);
      expect(find.byType(ImageFiltered), findsOneWidget);
      expect(find.byKey(const Key('lyrics_break_breather')), findsOneWidget);

      await tester.tap(find.text('Starless and bible black'));
      await tester.pump();

      expect(
        core.commands,
        contains(predicate<PlayerCommand>(
            (c) => c is Seek && c.positionMs == 90000)),
      );
    });

    testWidgets('shows Sync pill after manual scroll and hides when tapped',
        (tester) async {
      final core = _RecordingCore();
      final lines = [
        for (int i = 0; i < 30; i++)
          LyricLine(timestampMs: i * 5000, text: 'Lyric line number $i'),
      ];
      final lyrics = TrackLyrics(synced: true, lines: lines, plainLyrics: '');

      await tester.pumpWidget(
        wrap(
          const AmbientLyricsView(track: track),
          core: core,
          lyrics: lyrics,
          positionMs: 12000,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Sync'), findsNothing);

      // Perform a manual drag on the lyrics scroll view
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -180),
      );
      await tester.pump();

      expect(find.text('Sync'), findsOneWidget);

      // Tap Sync pill -> resumes auto-follow & dismisses pill
      await tester.tap(find.text('Sync'));
      await tester.pumpAndSettle();

      expect(find.text('Sync'), findsNothing);
    });

    testWidgets('shows pre-intro animated breather before first vocal timestamp',
        (tester) async {
      final core = _RecordingCore();
      const lyrics = TrackLyrics(
        synced: true,
        lines: [
          LyricLine(timestampMs: 8000, text: 'First vocal line'),
          LyricLine(timestampMs: 16000, text: 'Second vocal line'),
        ],
        plainLyrics: '',
      );

      await tester.pumpWidget(
        wrap(
          const AmbientLyricsView(track: track),
          core: core,
          lyrics: lyrics,
          positionMs: 1500,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('lyrics_pre_intro_breather')),
        findsOneWidget,
      );
    });
  });
}

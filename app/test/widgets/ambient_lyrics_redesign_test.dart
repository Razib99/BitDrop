import 'package:bitdrop/core_api/bitdrop_core.dart';
import 'package:bitdrop/core_api/commands.dart';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/features/now_playing/ambient_lyrics_view.dart';
import 'package:bitdrop/l10n/app_localizations.dart';
import 'package:bitdrop/providers/core_providers.dart';
import 'package:bitdrop/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingCore extends Fake implements BitDropCore {
  final List<PlayerCommand> commands = [];
  final List<bool> forceRefreshCalls = [];

  @override
  Future<void> send(PlayerCommand cmd) async {
    commands.add(cmd);
  }

  @override
  Future<TrackLyrics?> lyrics(Track track, {bool forceRefresh = false}) async {
    forceRefreshCalls.add(forceRefresh);
    return const TrackLyrics(
      synced: true,
      source: 'lrclib',
      lines: [
        LyricLine(timestampMs: 0, text: 'First line'),
      ],
      plainLyrics: 'First line',
    );
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

    testWidgets(
        'renders source pill, adjusts sync offset, and shifts tap-to-seek',
        (tester) async {
      final core = _RecordingCore();
      const lyrics = TrackLyrics(
        synced: true,
        source: 'lrclib',
        lines: [
          LyricLine(timestampMs: 0, text: 'Line one'),
          LyricLine(timestampMs: 10000, text: 'Line two'),
        ],
        plainLyrics: '',
      );

      await tester.pumpWidget(
        wrap(
          const AmbientLyricsView(track: track),
          core: core,
          lyrics: lyrics,
          positionMs: 1000,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('LRCLIB'), findsOneWidget);
      expect(find.text('0.0s'), findsOneWidget);

      // Tap '+' twice -> +0.5s (+500ms)
      await tester.tap(find.byKey(const Key('lyrics_offset_plus')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('lyrics_offset_plus')));
      await tester.pump();
      expect(find.text('+0.5s'), findsOneWidget);

      // Tap line at 10000ms -> seeks to 9500ms (10000 - 500)
      await tester.tap(find.text('Line two'));
      await tester.pump();
      expect(
        core.commands,
        contains(
          predicate<PlayerCommand>((c) => c is Seek && c.positionMs == 9500),
        ),
      );

      // Tap center label -> resets offset to 0.0s
      await tester.tap(find.byKey(const Key('lyrics_offset_value')));
      await tester.pump();
      expect(find.text('0.0s'), findsOneWidget);
    });

    testWidgets('re-search button invalidates lyricsProvider and retries fetch',
        (tester) async {
      var fetchCount = 0;
      final core = _RecordingCore();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            coreProvider.overrideWithValue(core),
            lyricsProvider(track).overrideWith((ref) {
              fetchCount++;
              return null;
            }),
            positionProvider.overrideWith(
              (ref) =>
                  Stream.value(const PositionInfo(positionMs: 0, durationMs: 1000)),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.dark(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: SizedBox(height: 420, child: AmbientLyricsView(track: track)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(fetchCount, 1);
      expect(find.text('Re-search lyrics'), findsOneWidget);

      await tester.tap(find.byKey(const Key('lyrics_retry_button')));
      await tester.pumpAndSettle();

      expect(fetchCount, 2);
    });

    testWidgets(
        'refresh button triggers forceRefresh: true through core.lyrics',
        (tester) async {
      final core = _RecordingCore();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            coreProvider.overrideWithValue(core),
            positionProvider.overrideWith(
              (ref) => Stream.value(
                  const PositionInfo(positionMs: 0, durationMs: 1000)),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.dark(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: SizedBox(height: 420, child: AmbientLyricsView(track: track)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(core.forceRefreshCalls, [false]);

      await tester.tap(find.byKey(const Key('lyrics_refresh_button')));
      await tester.pumpAndSettle();

      expect(core.forceRefreshCalls, [false, true]);
    });

    testWidgets('cycles font scale and copies lyrics to clipboard',
        (tester) async {
      final core = _RecordingCore();
      String? copiedText;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      const lyrics = TrackLyrics(
        synced: true,
        source: 'embedded',
        lines: [
          LyricLine(timestampMs: 0, text: 'Sundown dazzling day'),
          LyricLine(timestampMs: 5000, text: ''),
          LyricLine(timestampMs: 10000, text: 'Gold through my eyes'),
        ],
        plainLyrics: '',
      );

      final container = ProviderContainer(
        overrides: [
          coreProvider.overrideWithValue(core),
          lyricsProvider(track).overrideWith((ref) => lyrics),
          positionProvider.overrideWith(
            (ref) => Stream.value(
                const PositionInfo(positionMs: 0, durationMs: 60000)),
          ),
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
            home: const Scaffold(
              body: SizedBox(height: 420, child: AmbientLyricsView(track: track)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(container.read(lyricsFontScaleProvider), 1.0);
      await tester.tap(find.byKey(const Key('lyrics_font_scale_button')));
      await tester.pump();
      expect(container.read(lyricsFontScaleProvider), 1.2);

      await tester.tap(find.byKey(const Key('lyrics_font_scale_button')));
      await tester.pump();
      expect(container.read(lyricsFontScaleProvider), 0.85);

      await tester.tap(find.byKey(const Key('lyrics_copy_button')));
      await tester.pumpAndSettle();

      expect(copiedText, 'Sundown dazzling day\nGold through my eyes');
      expect(find.text('Lyrics copied'), findsOneWidget);
    });
  });
}

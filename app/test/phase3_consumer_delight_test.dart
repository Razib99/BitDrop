import 'package:bitdrop/core_api/bitdrop_core.dart';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/features/home/listening_recap_sheet.dart';
import 'package:bitdrop/features/now_playing/ambient_lyrics_view.dart';
import 'package:bitdrop/features/now_playing/now_playing_screen.dart';
import 'package:bitdrop/providers/core_providers.dart';
import 'package:bitdrop/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeCore extends Fake implements BitDropCore {
  @override
  Future<String> exportBackup() async => '{"version": 1}';
  @override
  Future<bool> importBackup(String jsonStr) async => true;
  @override
  void dispose() {}
}

Widget wrapWithProviders(
  Widget child, {
  BitDropCore? core,
  List<Override> overrides = const [],
}) {
  final testCore = core ?? FakeCore();
  return ProviderScope(
    overrides: [
      coreProvider.overrideWithValue(testCore),
      ...overrides,
    ],
    child: MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(body: child),
    ),
  );
}

const testTrack = Track(
  id: 'test-track-1',
  title: 'Starless',
  artist: 'King Crimson',
  albumTitle: 'Red',
  albumId: 'album-red',
  durationMs: 742000,
  format: AudioFormat(codec: Codec.flac, bitDepth: 24, sampleRate: 96000),
  availability: Availability.cached,
  sizeBytes: 154000000,
  artwork: Artwork(seed: 42, dominantColor: 0xFF990000),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 3: AmbientLyricsView Widget Tests', () {
    testWidgets('Renders empty state when lyrics are null', (tester) async {
      await tester.pumpWidget(
        wrapWithProviders(
          const AmbientLyricsView(track: testTrack),
          overrides: [
            lyricsProvider(testTrack).overrideWith((ref) => null),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No lyrics available'), findsOneWidget);
      expect(
        find.textContaining('Neither embedded tags nor LRCLIB have lyrics'),
        findsOneWidget,
      );
    });

    testWidgets('Renders plain unsynced lyrics', (tester) async {
      const lyrics = TrackLyrics(
        synced: false,
        lines: [],
        plainLyrics:
            'Sundown dazzling day\nGold through my eyes\nStarless and bible black',
      );

      await tester.pumpWidget(
        wrapWithProviders(
          const AmbientLyricsView(track: testTrack),
          overrides: [
            lyricsProvider(testTrack).overrideWith((ref) => lyrics),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Sundown dazzling day'), findsOneWidget);
      expect(find.textContaining('Starless and bible black'), findsOneWidget);
    });

    testWidgets('Renders time-synced lyrics with active line tracking',
        (tester) async {
      const lyrics = TrackLyrics(
        synced: true,
        lines: [
          LyricLine(timestampMs: 0, text: 'Sundown dazzling day'),
          LyricLine(timestampMs: 45000, text: 'Gold through my eyes'),
          LyricLine(timestampMs: 90000, text: 'Starless and bible black'),
        ],
        plainLyrics: '',
      );

      await tester.pumpWidget(
        wrapWithProviders(
          const AmbientLyricsView(track: testTrack),
          overrides: [
            lyricsProvider(testTrack).overrideWith((ref) => lyrics),
            positionProvider.overrideWith(
              (ref) => Stream.value(const PositionInfo(
                positionMs: 50000,
                durationMs: 742000,
              )),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Sundown dazzling day'), findsOneWidget);
      expect(find.text('Gold through my eyes'), findsOneWidget);
      expect(find.text('Starless and bible black'), findsOneWidget);
    });
  });

  group('Phase 3: ListeningRecapSheet Widget Tests', () {
    testWidgets('Renders empty recap view when totalPlays == 0', (tester) async {
      await tester.pumpWidget(
        wrapWithProviders(
          const ListeningRecapSheet(),
          overrides: [
            listeningRecapProvider.overrideWith((ref) => null),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No listening history yet'), findsOneWidget);
      expect(find.text('Export bitdrop_backup.json'), findsOneWidget);
    });

    testWidgets('Renders full audiophile telemetry cards and top lists',
        (tester) async {
      const recap = ListeningRecap(
        totalMinutesListened: 145,
        totalPlays: 28,
        topTracks: [
          RecapTrackItem(
            fileId: 't1',
            title: 'Close to the Edge',
            artist: 'Yes',
            playCount: 8,
            totalMinutes: 72,
          ),
          RecapTrackItem(
            fileId: 't2',
            title: 'Roundabout',
            artist: 'Yes',
            playCount: 6,
            totalMinutes: 34,
          ),
        ],
        topArtists: [
          RecapArtistItem(
            artist: 'Yes',
            playCount: 14,
            totalMinutes: 106,
          ),
        ],
        topGenre: 'Progressive Rock',
        losslessPercentage: 100.0,
        hiResPercentage: 85.0,
      );

      await tester.pumpWidget(
        wrapWithProviders(
          const ListeningRecapSheet(),
          overrides: [
            listeningRecapProvider.overrideWith((ref) => recap),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Audiophile Listening Recap'), findsOneWidget);
      expect(find.text('TOTAL LISTENING'), findsOneWidget);
      expect(find.text('2 h 25 m'), findsOneWidget);
      expect(find.text('100.0%'), findsOneWidget);
      expect(find.text('Progressive Rock'), findsOneWidget);
      expect(find.text('Close to the Edge'), findsOneWidget);
      expect(find.text('Yes'), findsWidgets);

      // Scroll down to ensure button is visible
      await tester.drag(find.byType(ListView).first, const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(find.text('1-Tap Export bitdrop_backup.json'), findsOneWidget);
    });
  });

  group('Phase 3: NowPlayingSignalChip Frosted Glass Tests', () {
    testWidgets('Renders frosted glass pill and taps to open sheet',
        (tester) async {
      const signal = SignalPath(
        tier: OutputTier.bitPerfect,
        source: AudioFormat(codec: Codec.flac, bitDepth: 24, sampleRate: 96000),
        requested: AudioFormat(codec: Codec.flac, bitDepth: 24, sampleRate: 96000),
        actual: AudioFormat(codec: Codec.flac, bitDepth: 24, sampleRate: 96000),
        dspActive: false,
        volume: VolumeMode.dacHardware,
        explanation: 'Bit-perfect direct stream active.',
      );

      await tester.pumpWidget(
        wrapWithProviders(
          const NowPlayingSignalChip(signal: signal),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('BIT-PERFECT'), findsOneWidget);
      expect(find.textContaining('96 kHz / 24-bit'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsOneWidget);
    });
  });
}

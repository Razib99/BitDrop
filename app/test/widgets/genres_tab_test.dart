import 'package:bitdrop/core_api/bitdrop_core.dart';
import 'package:bitdrop/core_api/commands.dart';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/core_api/queries.dart';
import 'package:bitdrop/features/library/library_screen.dart';
import 'package:bitdrop/l10n/app_localizations.dart';
import 'package:bitdrop/providers/core_providers.dart';
import 'package:bitdrop/theme/app_theme.dart';
import 'package:bitdrop/widgets/artwork.dart';
import 'package:bitdrop/widgets/rows.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeGenresCore extends Fake implements BitDropCore {
  final List<PlayerCommand> sentCommands = [];

  final testGenres = [
    const Genre(
      name: 'Electronic',
      trackCount: 42,
      albumCount: 6,
      artworkPaths: [
        '/art/e1.img',
        '/art/e2.img',
        '/art/e3.img',
        '/art/e4.img',
      ],
      primaryArtwork: '/art/e1.img',
    ),
    const Genre(
      name: 'Ambient',
      trackCount: 15,
      albumCount: 3,
      artworkPaths: [
        '/art/a1.img',
      ],
      primaryArtwork: '/art/a1.img',
    ),
    const Genre(
      name: 'Classical',
      trackCount: 28,
      albumCount: 4,
      artworkPaths: [],
    ),
  ];

  @override
  Future<List<String>> genres() async =>
      testGenres.map((g) => g.name).toList();

  @override
  Future<List<Genre>> genreDetails() async => testGenres;

  @override
  Future<Paged<Track>> tracks(TrackQuery q) async {
    return const Paged(
      items: [
        Track(
          id: 't-1',
          title: 'Track 1',
          artist: 'Artist 1',
          albumTitle: 'Album 1',
          albumId: 'al-1',
          durationMs: 200000,
          format: AudioFormat(
            codec: Codec.flac,
            bitDepth: 24,
            sampleRate: 96000,
            channels: 2,
          ),
          availability: Availability.cloudOnly,
          sizeBytes: 20000000,
          artwork: Artwork(seed: 1, dominantColor: 0xFF00BCD4),
        ),
      ],
      total: 1,
    );
  }

  @override
  Future<void> send(PlayerCommand cmd) async {
    sentCommands.add(cmd);
  }
}

void main() {
  Widget buildApp({
    required BitDropCore core,
    bool grid = true,
    GenreSort sort = GenreSort.trackCount,
  }) {
    return ProviderScope(
      overrides: [
        coreProvider.overrideWithValue(core),
        libraryTabProvider.overrideWith((ref) => LibraryTab.genres),
        libraryGridViewProvider.overrideWith((ref) => grid),
        genreSortProvider.overrideWith((ref) => sort),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: LibraryScreen()),
      ),
    );
  }

  group('Genres Tab with 2x2 Mosaic Cards Tests', () {
    testWidgets('Renders 2x2 mosaic quadrant artwork when 4 artworks available',
        (tester) async {
      const genre4 = Genre(
        name: 'Progressive Rock',
        trackCount: 20,
        albumCount: 4,
        artworkPaths: ['/a1.img', '/a2.img', '/a3.img', '/a4.img'],
      );

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: Center(
            child: GenreMosaicArtwork(genre: genre4, size: 200),
          ),
        ),
      ));

      expect(find.byType(GenreMosaicArtwork), findsOneWidget);
      expect(find.byType(AlbumArtwork), findsNWidgets(4));
    });

    testWidgets('Renders procedural fallback when no artworks available',
        (tester) async {
      const genre0 = Genre(
        name: 'Chiptune',
        trackCount: 5,
        albumCount: 1,
        artworkPaths: [],
      );

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: Center(
            child: GenreMosaicArtwork(genre: genre0, size: 200),
          ),
        ),
      ));

      expect(find.byType(GenreMosaicArtwork), findsOneWidget);
      expect(find.text('C'), findsOneWidget);
      expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);
    });

    testWidgets('Renders Grid view with GenreCards and badge counts',
        (tester) async {
      final fakeCore = _FakeGenresCore();
      await tester.pumpWidget(buildApp(core: fakeCore, grid: true));
      await tester.pumpAndSettle();

      expect(find.byType(GenreCard), findsNWidgets(3));
      expect(find.text('Electronic'), findsOneWidget);
      expect(find.text('42 tracks · 6 albums'), findsOneWidget);
      expect(find.text('Ambient'), findsOneWidget);
      expect(find.text('15 tracks · 3 albums'), findsOneWidget);
      expect(find.text('Classical'), findsOneWidget);
      expect(find.text('28 tracks · 4 albums'), findsOneWidget);
    });

    testWidgets('Renders List view with GenreRows when grid is false',
        (tester) async {
      final fakeCore = _FakeGenresCore();
      await tester.pumpWidget(buildApp(core: fakeCore, grid: false));
      await tester.pumpAndSettle();

      expect(find.byType(GenreRow), findsNWidgets(3));
      expect(find.text('Electronic'), findsOneWidget);
      expect(find.text('42 tracks · 6 albums'), findsOneWidget);
    });

    testWidgets('1-tap Play All and Shuffle dispatch PlayContext',
        (tester) async {
      final fakeCore = _FakeGenresCore();
      await tester.pumpWidget(buildApp(core: fakeCore, grid: false));
      await tester.pumpAndSettle();

      // Tap Play All button for Electronic
      final playButtons = find.byIcon(Icons.play_arrow);
      expect(playButtons, findsWidgets);
      await tester.tap(playButtons.first);
      await tester.pumpAndSettle();

      expect(fakeCore.sentCommands.isNotEmpty, isTrue);
      final cmd = fakeCore.sentCommands.last as PlayContext;
      expect(cmd.contextId, 'genre_Electronic');
      expect(cmd.shuffle, isFalse);

      // Tap Shuffle button for Electronic
      final shuffleButtons = find.byIcon(Icons.shuffle);
      expect(shuffleButtons, findsWidgets);
      await tester.tap(shuffleButtons.first);
      await tester.pumpAndSettle();

      final shuffleCmd = fakeCore.sentCommands.last as PlayContext;
      expect(shuffleCmd.contextId, 'genre_Electronic');
      expect(shuffleCmd.shuffle, isTrue);
    });
  });
}

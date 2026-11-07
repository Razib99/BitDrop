import 'package:bitdrop/core_api/bitdrop_core.dart';
import 'package:bitdrop/core_api/commands.dart';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/core_api/queries.dart';
import 'package:bitdrop/core_live/cloud_library.dart';
import 'package:bitdrop/features/folders/folder_browser.dart';
import 'package:bitdrop/l10n/app_localizations.dart';
import 'package:bitdrop/providers/core_providers.dart';
import 'package:bitdrop/src/rust/cloud/db.dart' as rust_db;
import 'package:bitdrop/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCore extends Fake implements BitDropCore {
  final List<PlayerCommand> sentCommands = [];
  String? queriedFolderId;
  String? queriedGenre;

  @override
  Future<List<String>> genres() async => ['Ambient', 'Classical', 'Electronic'];

  @override
  Future<FolderListing> folder(String? folderId) async {
    queriedFolderId = folderId;
    if (folderId == 'Music/Hi-Res') {
      return const FolderListing(
        folderId: 'Music/Hi-Res',
        breadcrumb: [
          FolderEntry(id: 'Music', name: 'Music', isDirectory: true),
          FolderEntry(id: 'Music/Hi-Res', name: 'Hi-Res', isDirectory: true),
        ],
        entries: [
          FolderEntry(
            id: 'track-101',
            name: 'Ode to Joy.flac',
            isDirectory: false,
            sizeBytes: 45000000,
            track: Track(
              id: 'track-101',
              title: 'Ode to Joy',
              artist: 'Beethoven',
              albumTitle: 'Symphony No. 9',
              albumId: 'al-9',
              durationMs: 340000,
              format: AudioFormat(
                codec: Codec.flac,
                bitDepth: 24,
                sampleRate: 96000,
                channels: 2,
              ),
              availability: Availability.cloudOnly,
              sizeBytes: 45000000,
              artwork: Artwork(seed: 123, dominantColor: 0xFF2E5A7A),
            ),
          ),
        ],
      );
    }

    return const FolderListing(
      folderId: null,
      breadcrumb: [],
      entries: [
        FolderEntry(
          id: 'Music',
          name: 'Music',
          isDirectory: true,
          itemCount: 4,
          sizeBytes: 150000000,
        ),
        FolderEntry(
          id: 'Podcasts',
          name: 'Podcasts',
          isDirectory: true,
          itemCount: 2,
          sizeBytes: 80000000,
        ),
      ],
    );
  }

  @override
  Future<void> send(PlayerCommand cmd) async {
    sentCommands.add(cmd);
  }

  @override
  Future<Paged<Album>> albums(AlbumQuery q) async {
    queriedGenre = q.filters.genre;
    final all = [
      const Album(
        id: 'al-1',
        title: 'Selected Ambient Works',
        artist: 'Aphex Twin',
        artistId: 'art-1',
        trackCount: 10,
        durationMs: 3600000,
        sizeBytes: 500000000,
        format: AudioFormat(
          codec: Codec.flac,
          bitDepth: 16,
          sampleRate: 44100,
          channels: 2,
        ),
        availability: Availability.cloudOnly,
        artwork: Artwork(seed: 1, dominantColor: 0xFF1C2C3A),
        genre: 'Ambient',
      ),
      const Album(
        id: 'al-2',
        title: 'Moonlight Sonata',
        artist: 'Beethoven',
        artistId: 'art-2',
        trackCount: 3,
        durationMs: 900000,
        sizeBytes: 150000000,
        format: AudioFormat(
          codec: Codec.flac,
          bitDepth: 24,
          sampleRate: 96000,
          channels: 2,
        ),
        availability: Availability.cloudOnly,
        artwork: Artwork(seed: 2, dominantColor: 0xFF2E5A7A),
        genre: 'Classical',
      ),
    ];

    if (q.filters.genre != null && q.filters.genre!.isNotEmpty) {
      final filtered = all
          .where((a) => a.genre?.toLowerCase() == q.filters.genre!.toLowerCase())
          .toList();
      return Paged(items: filtered, total: filtered.length);
    }
    return Paged(items: all, total: all.length);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CloudLibrary trackFromRow mapping', () {
    test('correctly maps CloudTrackRow fields into Track', () {
      final row = rust_db.CloudTrackRow(
        fileId: 'flac-drive-001',
        name: '01 - Track Title.flac',
        folderPath: 'Music/Jazz',
        title: 'Take Five',
        artist: 'Dave Brubeck',
        album: 'Time Out',
        albumArtist: 'The Dave Brubeck Quartet',
        genre: 'Jazz',
        year: 1959,
        trackNumber: 1,
        discNumber: 1,
        durationMs: 324000,
        sampleRate: 96000,
        channels: 2,
        bitsPerSample: 24,
        sizeBytes: BigInt.from(65000000),
        artworkPath: '/data/user/0/cache/art.jpg',
        tagsRead: true,
      );

      final track = CloudLibrary.trackFromRow(row);
      expect(track.id, 'flac-drive-001');
      expect(track.title, 'Take Five');
      expect(track.artist, 'Dave Brubeck');
      expect(track.albumTitle, 'Time Out');
      expect(track.genre, 'Jazz');
      expect(track.year, 1959);
      expect(track.trackNumber, 1);
      expect(track.format.codec, Codec.flac);
      expect(track.format.bitDepth, 24);
      expect(track.format.sampleRate, 96000);
      expect(track.sizeBytes, 65000000);
      expect(track.artwork.uri, '/data/user/0/cache/art.jpg');
      expect(track.folderPath, 'Music/Jazz');
      expect(track.tagsPending, isFalse);
    });
  });

  group('Genres & Folder Browser UI', () {
    late _FakeCore fakeCore;

    setUp(() {
      fakeCore = _FakeCore();
    });

    testWidgets('genresProvider fetches list from core', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            coreProvider.overrideWithValue(fakeCore),
          ],
          child: Consumer(
            builder: (context, ref, _) {
              final async = ref.watch(genresProvider);
              return async.when(
                data: (genres) => MaterialApp(
                  home: Column(
                    children: genres.map((g) => Text(g)).toList(),
                  ),
                ),
                loading: () => const SizedBox(),
                error: (e, _) => const SizedBox(),
              );
            },
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.text('Ambient'), findsOneWidget);
      expect(find.text('Classical'), findsOneWidget);
      expect(find.text('Electronic'), findsOneWidget);
    });

    testWidgets('FolderBrowser displays directories and breadcrumb navigation',
        (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            coreProvider.overrideWithValue(fakeCore),
          ],
          child: MaterialApp(
            theme: AppTheme.dark(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: const Scaffold(
              body: FolderBrowser(),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Root directories
      expect(find.text('Music'), findsOneWidget);
      expect(find.text('Podcasts'), findsOneWidget);
      expect(find.text('Favourites'), findsOneWidget);

      // Tap on Music folder
      await tester.tap(find.text('Music'));
      await tester.pumpAndSettle();

      expect(fakeCore.queriedFolderId, 'Music');
    });

    testWidgets('Tapping play folder sends PlayContext with empty trackIds for recursive playback',
        (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            coreProvider.overrideWithValue(fakeCore),
          ],
          child: MaterialApp(
            theme: AppTheme.dark(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: const Scaffold(
              body: FolderBrowser(),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Find the play button on the Music folder row
      final playIcon = find.widgetWithIcon(IconButton, Icons.play_arrow);
      expect(playIcon, findsWidgets);

      await tester.tap(playIcon.first);
      await tester.pumpAndSettle();

      expect(fakeCore.sentCommands, isNotEmpty);
      final playCmd = fakeCore.sentCommands.whereType<PlayContext>().first;
      expect(playCmd.contextId, 'Music');
      expect(playCmd.trackIds, isEmpty);
      expect(playCmd.contextLabel, 'Folder · Music');
    });

    testWidgets('AlbumQuery filters albums by genre', (tester) async {
      final albums = await fakeCore.albums(
        const AlbumQuery(filters: LibraryFilters(genre: 'Classical')),
      );

      expect(albums.items.length, 1);
      expect(albums.items.first.title, 'Moonlight Sonata');
      expect(albums.items.first.genre, 'Classical');
    });
  });
}

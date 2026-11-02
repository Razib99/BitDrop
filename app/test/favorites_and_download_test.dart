import 'dart:io';

import 'package:bitdrop/core_api/commands.dart';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/queries.dart';
import 'package:bitdrop/core_live/audio_handler.dart';
import 'package:bitdrop/core_live/cloud_library.dart';
import 'package:bitdrop/core_live/live_core.dart';
import 'package:bitdrop/core_mock/mock_core.dart';
import 'package:bitdrop/features/library/library_screen.dart';
import 'package:bitdrop/features/storage/google_drive_service.dart';
import 'package:bitdrop/l10n/app_localizations.dart';
import 'package:bitdrop/providers/core_providers.dart';
import 'package:bitdrop/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeDriveService extends Fake implements GoogleDriveService {
  @override
  bool get isSignedIn => true;
}

class _TestCloudLibrary extends CloudLibrary {
  _TestCloudLibrary({
    required super.drive,
    required super.dbPath,
    required super.cacheDir,
  });

  @override
  Future<void> open() async {}

  @override
  Future<void> scan({List<DriveFolder>? only}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Favorites and Download Core Logic', () {
    late MockBitDropCore core;

    setUp(() {
      core = MockBitDropCore();
    });

    tearDown(() {
      core.dispose();
    });

    test('Favoriting a track adds it to Favourites album', () async {
      final initialTracks = await core.tracks(const TrackQuery());
      expect(initialTracks.items, isNotEmpty);
      final testTrack = initialTracks.items.first;

      // Initially favorites album has 0 tracks
      var albums = await core.albums(const AlbumQuery());
      var favAlbum = albums.items.firstWhere((a) => a.id == 'album-favorites');
      expect(favAlbum.title, 'Favourites');
      expect(favAlbum.trackCount, 0);

      // Favorite testTrack
      await core.send(SetFavorite(trackId: testTrack.id, favorite: true));

      // Favourites album now has 1 track
      albums = await core.albums(const AlbumQuery());
      favAlbum = albums.items.firstWhere((a) => a.id == 'album-favorites');
      expect(favAlbum.trackCount, 1);

      // Fetch tracks from album-favorites
      final favTracks =
          await core.tracks(const TrackQuery(albumId: 'album-favorites'));
      expect(favTracks.items.length, 1);
      expect(favTracks.items.first.id, testTrack.id);
      expect(favTracks.items.first.favorite, isTrue);

      // Unfavorite
      await core.send(SetFavorite(trackId: testTrack.id, favorite: false));

      final emptyFavTracks =
          await core.tracks(const TrackQuery(albumId: 'album-favorites'));
      expect(emptyFavTracks.items, isEmpty);
    });

    test('Single-track download via Pin/Unpin', () async {
      final initialTracks = await core.tracks(const TrackQuery());
      final testTrack = initialTracks.items.first;

      // Pin track
      await core.send(Pin(id: testTrack.id, kind: 'track'));

      final updatedTracks = await core.tracks(const TrackQuery());
      final pinnedTrack =
          updatedTracks.items.firstWhere((t) => t.id == testTrack.id);
      expect(pinnedTrack.availability, Availability.pinned);

      // Unpin track
      await core.send(Unpin(id: testTrack.id, kind: 'track'));

      final unpinnedTracks = await core.tracks(const TrackQuery());
      final unpinnedTrack =
          unpinnedTracks.items.firstWhere((t) => t.id == testTrack.id);
      expect(unpinnedTrack.availability, isNot(Availability.pinned));
    });

    test('Whole album download via Pin/Unpin', () async {
      final albums = await core.albums(const AlbumQuery());
      final testAlbum = albums.items.firstWhere((a) => a.id != 'album-favorites');

      // Pin album
      await core.send(Pin(id: testAlbum.id, kind: 'album'));

      final albumTracks =
          await core.tracks(TrackQuery(albumId: testAlbum.id));
      expect(albumTracks.items, isNotEmpty);
      for (final t in albumTracks.items) {
        expect(t.availability, Availability.pinned);
      }

      // Unpin album
      await core.send(Unpin(id: testAlbum.id, kind: 'album'));

      final unpinnedAlbumTracks =
          await core.tracks(TrackQuery(albumId: testAlbum.id));
      for (final t in unpinnedAlbumTracks.items) {
        expect(t.availability, isNot(Availability.pinned));
      }
    });
  });

  group('LiveBitDropCore Cache Purge on Unpin', () {
    late Directory tempDir;
    late Directory cacheDir;
    late BitDropAudioHandler handler;
    late LiveBitDropCore liveCore;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('bitdrop_unpin_test_');
      cacheDir = Directory('${tempDir.path}/cache')..createSync();
      handler = BitDropAudioHandler();
      final fakeDrive = _FakeDriveService();
      final testCloud = _TestCloudLibrary(
        drive: fakeDrive,
        dbPath: '${tempDir.path}/db.sqlite',
        cacheDir: cacheDir.path,
      );
      liveCore = LiveBitDropCore(
        handler,
        cloudLibrary: testCloud,
        chunkCacheDir: cacheDir.path,
      );
    });

    tearDown(() async {
      liveCore.dispose();
      await handler.stop();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('Unpinning track deletes its .sparse and .idx files and restores cloudOnly', () async {
      const trackId = 'track_test_123';
      final sparseFile = File('${cacheDir.path}/$trackId.sparse')..writeAsStringSync('sparse-data');
      final idxFile = File('${cacheDir.path}/$trackId.idx')..writeAsStringSync('0\n1\n');

      expect(sparseFile.existsSync(), isTrue);
      expect(idxFile.existsSync(), isTrue);

      // Pin track
      await liveCore.send(const Pin(id: trackId, kind: 'track'));
      // Favorite it too
      await liveCore.send(const SetFavorite(trackId: trackId, favorite: true));

      // Now unpin track
      await liveCore.send(const Unpin(id: trackId, kind: 'track'));

      // Verify files are deleted
      expect(sparseFile.existsSync(), isFalse);
      expect(idxFile.existsSync(), isFalse);

      // Verify favorite status was preserved
      final favAlbum = await liveCore.tracks(const TrackQuery(albumId: 'album-favorites'));
      final found = favAlbum.items.where((t) => t.id == trackId);
      if (found.isNotEmpty) {
        expect(found.first.favorite, isTrue);
        expect(found.first.availability, Availability.cloudOnly);
      }
    });

    test('Unpinning album deletes all tracks sparse and idx files', () async {
      const albumId = 'al-northern';
      final sparse1 = File('${cacheDir.path}/al-northern-t1.sparse')..writeAsStringSync('data');
      final idx1 = File('${cacheDir.path}/al-northern-t1.idx')..writeAsStringSync('0\n');
      final sparse2 = File('${cacheDir.path}/al-northern-t2.sparse')..writeAsStringSync('data');
      final idx2 = File('${cacheDir.path}/al-northern-t2.idx')..writeAsStringSync('0\n');

      expect(sparse1.existsSync(), isTrue);
      expect(sparse2.existsSync(), isTrue);

      await liveCore.send(const Pin(id: albumId, kind: 'album'));
      await liveCore.send(const Unpin(id: albumId, kind: 'album'));

      expect(sparse1.existsSync(), isFalse);
      expect(idx1.existsSync(), isFalse);
      expect(sparse2.existsSync(), isFalse);
      expect(idx2.existsSync(), isFalse);
    });

    test('SetCacheLimit updates limit and reflects in storage state', () async {
      await liveCore.send(const SetCacheLimit(4 * 1000000000));
      final s = await liveCore.storage.first;
      expect(s.cacheLimitBytes, 4 * 1000000000);
    });
  });

  group('Scroll Retention Widget Tests', () {
    testWidgets('Toggling favorite preserves scroll position in tracks list',
        (tester) async {
      final mock = MockBitDropCore();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            coreProvider.overrideWithValue(mock),
            libraryTabProvider.overrideWith((ref) => LibraryTab.tracks),
          ],
          child: MaterialApp(
            theme: AppTheme.dark(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: const Scaffold(body: LibraryScreen()),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));

      // Find the track list ListView
      final listFinder =
          find.byKey(const PageStorageKey('library_tracks_list'));
      expect(listFinder, findsOneWidget);

      // Scroll down by 300 pixels
      await tester.drag(listFinder, const Offset(0, -300));
      await tester.pump(const Duration(milliseconds: 150));

      final scrollableFinder =
          find.descendant(of: listFinder, matching: find.byType(Scrollable));
      final scrollPositionBefore =
          tester.state<ScrollableState>(scrollableFinder).position.pixels;
      expect(scrollPositionBefore, greaterThan(200));

      // Tap favorite button on a visible track
      final favButton = find.byTooltip('Favourite').first;
      await tester.tap(favButton);
      await tester.pump(const Duration(milliseconds: 150));

      // Verify scroll position was NOT reset to 0!
      var scrollPositionAfter =
          tester.state<ScrollableState>(scrollableFinder).position.pixels;
      expect(scrollPositionAfter, equals(scrollPositionBefore));

      // Tap download button on a visible track
      final downloadButton = find.byTooltip('Download for offline').first;
      await tester.tap(downloadButton);
      await tester.pump(const Duration(milliseconds: 150));

      // Verify scroll position is STILL preserved!
      scrollPositionAfter =
          tester.state<ScrollableState>(scrollableFinder).position.pixels;
      expect(scrollPositionAfter, equals(scrollPositionBefore));

      mock.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
    });
  });
}

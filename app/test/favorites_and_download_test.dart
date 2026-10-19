import 'package:bitdrop/core_api/commands.dart';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/queries.dart';
import 'package:bitdrop/core_mock/mock_core.dart';
import 'package:bitdrop/l10n/app_localizations.dart';
import 'package:bitdrop/theme/app_theme.dart';
import 'package:bitdrop/widgets/indicators.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  group('AvailabilityGlyph Widget Tests', () {
    testWidgets('Renders download_done (ticked) for cached and pinned',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: const Scaffold(
            body: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AvailabilityGlyph(availability: Availability.cached),
                  AvailabilityGlyph(availability: Availability.pinned),
                  AvailabilityGlyph(
                    availability: Availability.cloudOnly,
                    showCloudOnly: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Should find two download_done icons (for cached and pinned)
      expect(find.byIcon(Icons.download_done), findsNWidgets(2));

      // Should find download_outlined icon for cloudOnly
      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
    });
  });
}

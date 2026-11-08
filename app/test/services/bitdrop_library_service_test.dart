import 'dart:io';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/core_api/queries.dart';
import 'package:bitdrop/services/bitdrop_library_service.dart';
import 'package:bitdrop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    const soPath =
        '/home/razib/Desktop/BitDrop/app/rust/target/debug/librust_lib_bitdrop.so';
    if (File(soPath).existsSync()) {
      try {
        await RustLib.init(externalLibrary: ExternalLibrary.open(soPath));
      } catch (_) {}
    }
  });

  group('BitDropLibraryService Unit Tests', () {
    late Directory tempDir;
    late BitDropLibraryService service;
    bool favoritesChangedCalled = false;
    bool pinnedChangedCalled = false;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('bitdrop_lib_test_');
    favoritesChangedCalled = false;
    pinnedChangedCalled = false;

    service = BitDropLibraryService(
      chunkCacheDir: '${tempDir.path}/chunks',
      artworkCacheDir: '${tempDir.path}/artwork',
      onFavoritesChanged: () => favoritesChangedCalled = true,
      onPinnedChanged: () => pinnedChangedCalled = true,
    );
    await service.init();
  });

  tearDown(() async {
    service.dispose();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('Initial storage state is initialized', () {
    expect(service.currentStorage.cacheLimitBytes, equals(2 * 1024 * 1024 * 1024));
    expect(service.currentStorage.pinnedBytes, equals(0));
    expect(service.syncStatus, emits(SyncStatus.idle));
  });

  test('setFavorite toggles favorites and fires notification', () async {
    const trackId = 'mock-track-1';
    await service.setFavorite(trackId: trackId, favorite: true);

    expect(service.favoriteTrackIds.contains(trackId), isTrue);
    expect(favoritesChangedCalled, isTrue);

    await service.setFavorite(trackId: trackId, favorite: false);
    expect(service.favoriteTrackIds.contains(trackId), isFalse);
  });

  test('pin and unpin manage pinned track IDs', () async {
    const trackId = 'mock-track-pinned';
    await service.pin(id: trackId, kind: 'track');

    expect(service.pinnedTrackIds.contains(trackId), isTrue);
    expect(pinnedChangedCalled, isTrue);

    await service.unpin(id: trackId, kind: 'track');
    expect(service.pinnedTrackIds.contains(trackId), isFalse);
  });

  test('pin and unpin manage pinned album IDs', () async {
    const albumId = 'mock-album-pinned';
    await service.pin(id: albumId, kind: 'album');

    expect(service.pinnedAlbumIds.contains(albumId), isTrue);

    await service.unpin(id: albumId, kind: 'album');
    expect(service.pinnedAlbumIds.contains(albumId), isFalse);
  });

  test('enrichTrack applies favorite and pinned flags', () async {
    const track = Track(
      id: 'test-track-123',
      title: 'Test Song',
      artist: 'Artist',
      albumTitle: 'Album',
      albumId: 'album-1',
      durationMs: 180000,
      format: AudioFormat(codec: Codec.flac, bitDepth: 16, sampleRate: 44100),
      sizeBytes: 25000000,
      availability: Availability.cloudOnly,
      artwork: Artwork(seed: 1, dominantColor: 0xFF000000),
    );

    await service.setFavorite(trackId: track.id, favorite: true);
    final favEnriched = service.enrichTrack(track);
    expect(favEnriched.favorite, isTrue);
    expect(favEnriched.availability, equals(Availability.cloudOnly));

    await service.pin(id: track.id, kind: 'track');
    final pinnedEnriched = service.enrichTrack(track);
    expect(pinnedEnriched.availability, equals(Availability.pinned));
  });

  test('Recent searches can be recorded, retrieved, and cleared', () async {
    await service.recordRecentSearch('Miles Davis');
    await service.recordRecentSearch('John Coltrane');

    var list = await service.recentSearches();
    expect(list.first, equals('John Coltrane'));
    expect(list.contains('Miles Davis'), isTrue);

    await service.removeRecentSearch('Miles Davis');
    list = await service.recentSearches();
    expect(list.contains('Miles Davis'), isFalse);

    await service.clearRecentSearches();
    list = await service.recentSearches();
    expect(list, isEmpty);
  });

  test('search finds matching tracks and albums from catalog', () async {
    final results = await service.search(
      'FLAC',
      const SearchFilters(),
    );

    expect(results.tracks, isNotEmpty);
    expect(results.tracks.any((t) => t.format.codec == Codec.flac), isTrue);
  });
  });
}

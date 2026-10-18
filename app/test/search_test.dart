import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/core_api/queries.dart';
import 'package:bitdrop/core_mock/mock_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late MockBitDropCore core;

  setUp(() {
    core = MockBitDropCore();
  });

  tearDown(() {
    core.dispose();
  });

  group('Search functionality', () {
    test('empty query returns empty results', () async {
      final res = await core.search('', const SearchFilters());
      expect(res.isEmpty, isTrue);
      expect(res.tracks, isEmpty);
      expect(res.albums, isEmpty);
    });

    test('searches tracks by title keyword', () async {
      final res = await core.search('a', const SearchFilters());
      expect(res.isNotEmpty, isTrue);
      expect(res.tracks, isNotEmpty);
    });

    test('format-aware search: hi-res finds only hi-res tracks', () async {
      final res = await core.search('hi-res', const SearchFilters());
      expect(res.tracks, isNotEmpty);
      for (final t in res.tracks) {
        expect(t.format.isHiRes, isTrue);
      }
    });

    test('format-aware search: 24/96 matches exact format', () async {
      final res = await core.search('24/96', const SearchFilters());
      expect(res.tracks, isNotEmpty);
      for (final t in res.tracks) {
        expect(t.format.shortLabel, '24/96');
      }
    });

    test('quality filter hiRes excludes standard CD tracks', () async {
      const filters = SearchFilters(quality: QualityFilter.hiRes);
      final res = await core.search('flac', filters);
      expect(res.tracks, isNotEmpty);
      for (final t in res.tracks) {
        expect(t.format.isHiRes, isTrue);
      }
    });

    test('codec filter flac returns only FLAC tracks', () async {
      const filters = SearchFilters(codecs: {Codec.flac});
      final res = await core.search('a', filters);
      expect(res.tracks, isNotEmpty);
      for (final t in res.tracks) {
        expect(t.format.codec, Codec.flac);
      }
    });

    test('offlineOnly filter returns only cached or pinned tracks', () async {
      const filters = SearchFilters(offlineOnly: true);
      final res = await core.search('a', filters);
      for (final t in res.tracks) {
        expect(
          t.availability == Availability.cached ||
              t.availability == Availability.pinned,
          isTrue,
        );
      }
    });

    test('topResult is populated when matches exist', () async {
      final res = await core.search('flac', const SearchFilters());
      expect(res.topResult, isNotNull);
    });
  });
}

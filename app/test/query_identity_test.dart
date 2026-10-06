import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/queries.dart';
import 'package:flutter_test/flutter_test.dart';

/// Query objects are used as Riverpod `family` keys. Without value equality a
/// rebuild allocates a brand-new provider that re-runs its future forever, so
/// the list never leaves its loading state.
void main() {
  test('identical AlbumQuery values are the same family key', () {
    const a = AlbumQuery(sort: AlbumSort.year, descending: true);
    const b = AlbumQuery(sort: AlbumSort.year, descending: true);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });

  test('a differing AlbumQuery is a different key', () {
    const a = AlbumQuery(sort: AlbumSort.year);
    const b = AlbumQuery(sort: AlbumSort.title);
    expect(a, isNot(b));
  });

  test('filters compare by value, including the codec set', () {
    const a = AlbumQuery(
      filters: LibraryFilters(codecs: {Codec.flac, Codec.alac}),
    );
    const b = AlbumQuery(
      filters: LibraryFilters(codecs: {Codec.alac, Codec.flac}),
    );
    expect(a, b, reason: 'set order must not matter');
    expect(a.hashCode, b.hashCode);

    const c = AlbumQuery(filters: LibraryFilters(codecs: {Codec.flac}));
    expect(a, isNot(c));
  });

  test('TrackQuery, ArtistQuery and SearchFilters compare by value', () {
    expect(const TrackQuery(albumId: 'x'), const TrackQuery(albumId: 'x'));
    expect(
        const TrackQuery(albumId: 'x'), isNot(const TrackQuery(albumId: 'y')));
    expect(const ArtistQuery(limit: 10), const ArtistQuery(limit: 10));
    expect(
      const SearchFilters(quality: QualityFilter.hiRes),
      const SearchFilters(quality: QualityFilter.hiRes),
    );
    expect(
      const SearchFilters(offlineOnly: true),
      isNot(const SearchFilters()),
    );
  });
}

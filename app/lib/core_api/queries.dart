import 'package:flutter/foundation.dart';

import 'enums.dart';
import 'models.dart';

enum AlbumSort {
  title,
  artist,
  year,
  recentlyAdded,
  sampleRate,
  bitDepth,
  size,
  duration
}

enum TrackSort { title, artist, album, duration, sampleRate }

enum QualityFilter { any, lossless, hiRes, cdQuality, lossy }

enum AvailabilityFilter { any, offline, cached, cloudOnly }

extension QualityFilterMatcher on QualityFilter {
  /// Compact display label used in filter chips and summaries.
  String get shortLabel => switch (this) {
        QualityFilter.any => 'All',
        QualityFilter.lossless => 'Lossless',
        QualityFilter.hiRes => 'Hi-Res',
        QualityFilter.cdQuality => 'CD',
        QualityFilter.lossy => 'Lossy',
      };

  /// True when [format] satisfies this quality tier.
  bool matches(AudioFormat format) => switch (this) {
        QualityFilter.any => true,
        QualityFilter.lossless =>
          format.codec.isSupported && format.codec.isLossless,
        QualityFilter.hiRes => format.isHiRes,
        QualityFilter.cdQuality => format.isCdQuality,
        QualityFilter.lossy => !format.codec.isLossless,
      };
}

extension AvailabilityFilterMatcher on AvailabilityFilter {
  /// Compact display label used in filter summaries.
  String get shortLabel => switch (this) {
        AvailabilityFilter.any => 'All',
        AvailabilityFilter.offline => 'Pinned',
        AvailabilityFilter.cached => 'On device',
        AvailabilityFilter.cloudOnly => 'Cloud only',
      };

  /// True when [availability] satisfies this filter.
  bool matches(Availability availability) => switch (this) {
        AvailabilityFilter.any => true,
        AvailabilityFilter.offline => availability == Availability.pinned,
        AvailabilityFilter.cached =>
          availability == Availability.cached ||
              availability == Availability.pinned,
        AvailabilityFilter.cloudOnly => availability == Availability.cloudOnly,
      };
}

/// Shared filter payload for library queries and search.
@immutable
class LibraryFilters {
  const LibraryFilters({
    this.codecs = const {},
    this.quality = QualityFilter.any,
    this.availability = AvailabilityFilter.any,
    this.showUnsupported = true,
    this.genre,
    this.artistId,
  });

  final Set<Codec> codecs;
  final QualityFilter quality;
  final AvailabilityFilter availability;
  final bool showUnsupported;
  final String? genre;
  final String? artistId;

  bool get isActive =>
      codecs.isNotEmpty ||
      quality != QualityFilter.any ||
      availability != AvailabilityFilter.any ||
      !showUnsupported ||
      genre != null;

  int get activeCount =>
      (codecs.isNotEmpty ? 1 : 0) +
      (quality != QualityFilter.any ? 1 : 0) +
      (availability != AvailabilityFilter.any ? 1 : 0) +
      (!showUnsupported ? 1 : 0) +
      (genre != null ? 1 : 0);

  /// True when [album] passes every active criterion in this filter set.
  bool matchesAlbum(Album album, {bool showUnsupportedSetting = true}) {
    if (!showUnsupported && !album.format.codec.isSupported) return false;
    if (!showUnsupportedSetting && !album.format.codec.isSupported) {
      return false;
    }
    if (codecs.isNotEmpty && !codecs.contains(album.format.codec)) return false;
    if (!quality.matches(album.format)) return false;
    if (genre != null &&
        genre!.isNotEmpty &&
        album.genre?.toLowerCase() != genre!.toLowerCase()) {
      return false;
    }
    if (!availability.matches(album.availability)) return false;
    return true;
  }

  /// True when [track] passes every active criterion in this filter set.
  bool matchesTrack(
    Track track, {
    bool showUnsupportedSetting = true,
    String? resolvedArtistId,
  }) {
    if (artistId != null && resolvedArtistId != artistId) {
      return false;
    }
    if (!showUnsupported && !track.format.codec.isSupported) return false;
    if (!showUnsupportedSetting && !track.format.codec.isSupported) {
      return false;
    }
    if (codecs.isNotEmpty && !codecs.contains(track.format.codec)) return false;
    if (!quality.matches(track.format)) return false;
    if (genre != null &&
        genre!.isNotEmpty &&
        track.genre?.toLowerCase() != genre!.toLowerCase()) {
      return false;
    }
    if (!availability.matches(track.availability)) return false;
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is LibraryFilters &&
      _sameSet(other.codecs, codecs) &&
      other.quality == quality &&
      other.availability == availability &&
      other.showUnsupported == showUnsupported &&
      other.genre == genre &&
      other.artistId == artistId;

  @override
  int get hashCode => Object.hash(
        Object.hashAllUnordered(codecs),
        quality,
        availability,
        showUnsupported,
        genre,
        artistId,
      );

  LibraryFilters copyWith({
    Set<Codec>? codecs,
    QualityFilter? quality,
    AvailabilityFilter? availability,
    bool? showUnsupported,
    String? genre,
    bool clearGenre = false,
    String? artistId,
  }) =>
      LibraryFilters(
        codecs: codecs ?? this.codecs,
        quality: quality ?? this.quality,
        availability: availability ?? this.availability,
        showUnsupported: showUnsupported ?? this.showUnsupported,
        genre: clearGenre ? null : (genre ?? this.genre),
        artistId: artistId ?? this.artistId,
      );
}

@immutable
class AlbumQuery {
  const AlbumQuery({
    this.sort = AlbumSort.title,
    this.descending = false,
    this.filters = const LibraryFilters(),
    this.offset = 0,
    this.limit = 200,
    this.artistId,
  });

  final AlbumSort sort;
  final bool descending;
  final LibraryFilters filters;
  final int offset;
  final int limit;
  final String? artistId;

  @override
  bool operator ==(Object other) =>
      other is AlbumQuery &&
      other.sort == sort &&
      other.descending == descending &&
      other.filters == filters &&
      other.offset == offset &&
      other.limit == limit &&
      other.artistId == artistId;

  @override
  int get hashCode =>
      Object.hash(sort, descending, filters, offset, limit, artistId);

  AlbumQuery copyWith({
    AlbumSort? sort,
    bool? descending,
    LibraryFilters? filters,
    int? offset,
    int? limit,
    String? artistId,
  }) =>
      AlbumQuery(
        sort: sort ?? this.sort,
        descending: descending ?? this.descending,
        filters: filters ?? this.filters,
        offset: offset ?? this.offset,
        limit: limit ?? this.limit,
        artistId: artistId ?? this.artistId,
      );
}

@immutable
class TrackQuery {
  const TrackQuery({
    this.sort = TrackSort.title,
    this.descending = false,
    this.filters = const LibraryFilters(),
    this.offset = 0,
    this.limit = 300,
    this.albumId,
    this.playlistId,
  });

  final TrackSort sort;
  final bool descending;
  final LibraryFilters filters;
  final int offset;
  final int limit;
  final String? albumId;
  final String? playlistId;

  @override
  bool operator ==(Object other) =>
      other is TrackQuery &&
      other.sort == sort &&
      other.descending == descending &&
      other.filters == filters &&
      other.offset == offset &&
      other.limit == limit &&
      other.albumId == albumId &&
      other.playlistId == playlistId;

  @override
  int get hashCode => Object.hash(
      sort, descending, filters, offset, limit, albumId, playlistId);

  TrackQuery copyWith({
    TrackSort? sort,
    bool? descending,
    LibraryFilters? filters,
    int? offset,
    int? limit,
  }) =>
      TrackQuery(
        sort: sort ?? this.sort,
        descending: descending ?? this.descending,
        filters: filters ?? this.filters,
        offset: offset ?? this.offset,
        limit: limit ?? this.limit,
        albumId: albumId,
        playlistId: playlistId,
      );
}

@immutable
class ArtistQuery {
  const ArtistQuery(
      {this.offset = 0, this.limit = 200, this.descending = false});
  final int offset;
  final int limit;
  final bool descending;

  @override
  bool operator ==(Object other) =>
      other is ArtistQuery &&
      other.offset == offset &&
      other.limit == limit &&
      other.descending == descending;

  @override
  int get hashCode => Object.hash(offset, limit, descending);
}

@immutable
class SearchFilters {
  const SearchFilters({
    this.codecs = const {},
    this.quality = QualityFilter.any,
    this.offlineOnly = false,
  });

  final Set<Codec> codecs;
  final QualityFilter quality;
  final bool offlineOnly;

  bool get isActive =>
      codecs.isNotEmpty || quality != QualityFilter.any || offlineOnly;

  @override
  bool operator ==(Object other) =>
      other is SearchFilters &&
      _sameSet(other.codecs, codecs) &&
      other.quality == quality &&
      other.offlineOnly == offlineOnly;

  @override
  int get hashCode =>
      Object.hash(Object.hashAllUnordered(codecs), quality, offlineOnly);

  SearchFilters copyWith({
    Set<Codec>? codecs,
    QualityFilter? quality,
    bool? offlineOnly,
  }) =>
      SearchFilters(
        codecs: codecs ?? this.codecs,
        quality: quality ?? this.quality,
        offlineOnly: offlineOnly ?? this.offlineOnly,
      );
}

/// Set equality without pulling in a collection dependency.
bool _sameSet<T>(Set<T> a, Set<T> b) =>
    a.length == b.length && a.every(b.contains);

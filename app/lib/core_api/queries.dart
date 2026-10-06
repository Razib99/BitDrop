import 'package:flutter/foundation.dart';

import 'enums.dart';

enum AlbumSort { title, artist, year, recentlyAdded, sampleRate, bitDepth, size, duration }

enum TrackSort { title, artist, album, duration, sampleRate }

enum QualityFilter { any, hiRes, cdQuality, lossy }

enum AvailabilityFilter { any, offline, cached, cloudOnly }

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
  const ArtistQuery({this.offset = 0, this.limit = 200, this.descending = false});
  final int offset;
  final int limit;
  final bool descending;
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

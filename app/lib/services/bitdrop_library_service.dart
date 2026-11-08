import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:rxdart/rxdart.dart';

import '../core_api/enums.dart';
import '../core_api/models.dart';
import '../core_api/queries.dart';
import '../core_mock/catalog.dart';
import '../core_live/cloud_library.dart';
import '../src/rust/api/cloud_library.dart' as rust_cache;

/// Manages local audio library indexing, cloud sync (Google Drive, WebDAV),
/// track/album/artist/folder/genre queries, search, and cached audio storage.
class BitDropLibraryService {
  final CloudLibrary? _cloud;
  final String? _chunkCacheDir;
  final String? _artworkCacheDir;
  final Future<String?> Function()? accessTokenProvider;
  final Track? Function()? nowPlayingTrackProvider;

  final Map<String, Track> _realTracks = {};
  Album? _realAlbum;

  final Set<String> _favoriteTrackIds = {};
  final Set<String> _pinnedTrackIds = {};
  final Set<String> _pinnedAlbumIds = {};

  final _syncStatus = BehaviorSubject<SyncStatus>.seeded(SyncStatus.idle);
  final _defaultSources = BehaviorSubject<List<SourceAccount>>.seeded(const []);
  final _storage = BehaviorSubject<StorageState>.seeded(_emptyStorage);

  static const _emptyStorage = StorageState(
    pinnedBytes: 0,
    cacheBytes: 0,
    freeBytes: 0,
    totalBytes: 0,
    cacheLimitBytes: 2 * 1024 * 1024 * 1024,
  );

  int _cachedTrackCount = 0;
  int get cachedTrackCount => _cachedTrackCount;
  int _cacheLimitBytes = 2 * 1024 * 1024 * 1024;
  List<String>? _recentSearchesList;

  StreamSubscription<SyncStatus>? _cloudStatusSub;

  void Function(String oldId, String newId)? onFileReplaced;
  void Function(List<String> prunedIds)? onFilesPruned;
  void Function()? onFavoritesChanged;
  void Function()? onPinnedChanged;

  BitDropLibraryService({
    CloudLibrary? cloudLibrary,
    String? chunkCacheDir,
    String? artworkCacheDir,
    this.accessTokenProvider,
    this.nowPlayingTrackProvider,
    this.onFileReplaced,
    this.onFilesPruned,
    this.onFavoritesChanged,
    this.onPinnedChanged,
  })  : _cloud = cloudLibrary,
        _chunkCacheDir = chunkCacheDir,
        _artworkCacheDir = artworkCacheDir;

  Stream<SyncStatus> get syncStatus => _syncStatus.stream;
  Stream<List<SourceAccount>> get sources =>
      _cloud?.sourceAccounts ?? _defaultSources.stream;
  Stream<StorageState> get storage => _storage.stream;
  StorageState get currentStorage => _storage.value;

  CloudLibrary? get cloud => _cloud;
  String? get chunkCacheDir => _chunkCacheDir;
  String? get artworkCacheDir => _artworkCacheDir;

  Set<String> get favoriteTrackIds => Set.unmodifiable(_favoriteTrackIds);
  Set<String> get pinnedTrackIds => Set.unmodifiable(_pinnedTrackIds);
  Set<String> get pinnedAlbumIds => Set.unmodifiable(_pinnedAlbumIds);

  List<Album> get _cloudAlbums => _cloud?.currentAlbums ?? const [];
  List<Track> get _cloudTracks => _cloud?.currentTracks ?? const [];

  List<String> get _chunkDirs {
    final chunks = _chunkCacheDir;
    final artwork = _artworkCacheDir;
    return [
      if (chunks != null) chunks,
      if (artwork != null) artwork.replaceFirst(RegExp(r'/artwork/?$'), ''),
    ];
  }

  File? get _favoritesFile {
    final dir = _chunkCacheDir;
    if (dir == null) return null;
    final parent = Directory(dir).parent;
    return File('${parent.path}/favorites.json');
  }

  File? get _pinnedFile {
    final dir = _chunkCacheDir;
    if (dir == null) return null;
    final parent = Directory(dir).parent;
    return File('${parent.path}/pinned.json');
  }

  File? get _recentSearchesFile {
    final dir = _chunkCacheDir;
    if (dir == null) return null;
    final parent = Directory(dir).parent;
    return File('${parent.path}/recent_searches.json');
  }

  Future<void> init() async {
    _cloudStatusSub = _cloud?.status.listen(_syncStatus.add);
    await _cloud?.open();

    _cloud?.onFileReplaced = (oldId, newId) async {
      var changed = false;
      if (_favoriteTrackIds.remove(oldId)) {
        _favoriteTrackIds.add(newId);
        changed = true;
      }
      if (_pinnedTrackIds.remove(oldId)) {
        _pinnedTrackIds.add(newId);
        changed = true;
      }
      if (changed) {
        await saveFavorites();
        await savePinned();
      }
      onFileReplaced?.call(oldId, newId);
    };

    _cloud?.onFilesPruned = (prunedIds) async {
      var changed = false;
      for (final id in prunedIds) {
        if (_favoriteTrackIds.remove(id)) changed = true;
        if (_pinnedTrackIds.remove(id)) changed = true;
      }
      if (changed) {
        await saveFavorites();
        await savePinned();
      }
      onFilesPruned?.call(prunedIds);
    };

    await loadFavoritesAndPinned();
    await refreshStorage();
  }

  Future<void> loadFavoritesAndPinned() async {
    try {
      final favFile = _favoritesFile;
      if (favFile != null && await favFile.exists()) {
        final text = await favFile.readAsString();
        final raw = jsonDecode(text);
        if (raw is List) {
          _favoriteTrackIds.addAll(raw.map((e) => e.toString()));
        }
      }
    } catch (e) {
      debugPrint('[library] failed to read favorites: $e');
    }

    try {
      final pinFile = _pinnedFile;
      if (pinFile != null && await pinFile.exists()) {
        final text = await pinFile.readAsString();
        final raw = jsonDecode(text);
        if (raw is Map) {
          if (raw['tracks'] is List) {
            _pinnedTrackIds
                .addAll((raw['tracks'] as List).map((e) => e.toString()));
          }
          if (raw['albums'] is List) {
            _pinnedAlbumIds
                .addAll((raw['albums'] as List).map((e) => e.toString()));
          }
        }
      }
      await rust_cache.cloudCacheSyncPinned(
        pinnedFileIds: _pinnedTrackIds.toList(),
      );
    } catch (e) {
      debugPrint('[library] failed to read pinned: $e');
    }
  }

  Future<void> saveFavorites() async {
    final file = _favoritesFile;
    if (file == null) return;
    try {
      await file.writeAsString(jsonEncode(_favoriteTrackIds.toList()));
    } catch (e) {
      debugPrint('[library] failed to write favorites: $e');
    }
    onFavoritesChanged?.call();
  }

  Future<void> savePinned() async {
    final file = _pinnedFile;
    if (file != null) {
      try {
        await file.writeAsString(jsonEncode({
          'tracks': _pinnedTrackIds.toList(),
          'albums': _pinnedAlbumIds.toList(),
        }));
      } catch (e) {
        debugPrint('[library] failed to write pinned: $e');
      }
    }
    try {
      await rust_cache.cloudCacheSyncPinned(
        pinnedFileIds: _pinnedTrackIds.toList(),
      );
    } catch (e) {
      debugPrint('[library] failed to sync pinned to rust: $e');
    }
    onPinnedChanged?.call();
  }

  static bool isLocalTrackId(String id) {
    if (id.startsWith('file://')) return true;
    if (id.startsWith('/')) return true;
    if (RegExp(r'^[a-zA-Z]:[/\\]').hasMatch(id)) return true;
    return false;
  }

  static String stripFileUri(String id) {
    if (id.startsWith('file://')) {
      try {
        return Uri.parse(id).toFilePath();
      } catch (_) {
        return id.replaceFirst('file://', '');
      }
    }
    return id;
  }

  Track? lookupTrack(String id) {
    final t =
        _cloud?.trackById(id) ?? _realTracks[id] ?? MockCatalog.trackById(id);
    if (t != null) return t;

    if (isLocalTrackId(id)) {
      try {
        final filePath = stripFileUri(id);
        final file = File(filePath);
        if (file.existsSync()) {
          final stat = file.statSync();
          final name = filePath.split(RegExp(r'[/\\]')).last;
          final dot = name.lastIndexOf('.');
          final title = dot > 0 ? name.substring(0, dot) : name;
          final parent = file.parent;
          final parentName = parent.path.split(RegExp(r'[/\\]')).last;
          final albumTitle = parentName.isNotEmpty ? parentName : 'Local Files';
          final track = Track(
            id: filePath,
            title: title,
            artist: 'Local Music',
            albumTitle: albumTitle,
            albumId: CloudLibrary.albumIdFor(albumTitle, 'Local Music'),
            durationMs: 0,
            format: AudioFormat(
              codec: CloudLibrary.codecFor(filePath),
              bitDepth: 16,
              sampleRate: 44100,
            ),
            sizeBytes: stat.size,
            availability: Availability.cached,
            artwork: Artwork(
              seed: albumTitle.hashCode,
              dominantColor: 0xFF2A2A2A,
              uri: filePath,
            ),
          );
          _realTracks[filePath] = track;
          _realTracks[id] = track;
          return track;
        }
      } catch (e) {
        debugPrint('[library] lookupTrack fallback error for $id: $e');
      }
    }
    return null;
  }

  bool isTrackFullyCached(String trackId, int sizeBytes) {
    if (_pinnedTrackIds.contains(trackId)) return true;
    final chunks = _chunkCacheDir;
    if (chunks == null || sizeBytes <= 0) return false;
    try {
      return rust_cache.cloudCacheIsComplete(
        fileId: trackId,
        cacheDir: chunks,
        totalSize: BigInt.from(sizeBytes),
      );
    } catch (_) {
      return false;
    }
  }

  void deleteDiskCacheFor(String fileId) {
    final chunks = _chunkCacheDir;
    if (chunks == null) return;
    try {
      rust_cache.cloudCacheRemoveTrack(fileId: fileId, cacheDir: chunks);
    } catch (e) {
      debugPrint('[storage] failed to remove chunk cache for $fileId: $e');
    }
  }

  Track enrichTrack(Track t) {
    final isFav = _favoriteTrackIds.contains(t.id);
    final isPinned = _pinnedTrackIds.contains(t.id);
    var avail = t.availability;
    if (isPinned) {
      avail = Availability.pinned;
    } else if (isTrackFullyCached(t.id, t.sizeBytes)) {
      avail = Availability.cached;
    } else if (!_realTracks.containsKey(t.id)) {
      avail = Availability.cloudOnly;
    }
    return t.copyWith(
      favorite: isFav,
      availability: avail,
    );
  }

  Album enrichAlbum(Album a) {
    if (_realAlbum != null && a.id == _realAlbum!.id) return a;
    final isPinned = _pinnedAlbumIds.contains(a.id);
    return a.copyWith(
      availability: isPinned ? Availability.pinned : Availability.cloudOnly,
    );
  }

  List<Track> get allCandidateTracks => [
        ..._cloudTracks,
        ..._realTracks.values,
        ...MockCatalog.tracks,
      ];

  Album favoritesAlbum() {
    final favTracks = allCandidateTracks
        .where((t) => _favoriteTrackIds.contains(t.id))
        .map(enrichTrack)
        .toList();
    final unique = <String, Track>{};
    for (final t in favTracks) {
      unique[t.id] = t;
    }
    final items = unique.values.toList();
    int duration = 0;
    int size = 0;
    for (final t in items) {
      duration += t.durationMs;
      size += t.sizeBytes;
    }
    return Album(
      id: 'album-favorites',
      title: 'Favourites',
      artist: 'Favorite tracks',
      artistId: 'favorites',
      trackCount: items.length,
      durationMs: duration,
      sizeBytes: size,
      format: items.isNotEmpty
          ? items.first.format
          : const AudioFormat(
              codec: Codec.flac, bitDepth: 24, sampleRate: 96000),
      availability: _pinnedAlbumIds.contains('album-favorites')
          ? Availability.pinned
          : Availability.cloudOnly,
      artwork: const Artwork(seed: 777, dominantColor: 0xFFE91E63),
      mixedFormats: true,
      lastModified: DateTime.now(),
    );
  }

  Future<void> refreshStorage() async {
    final chunks = _chunkCacheDir;
    if (chunks == null) return;
    try {
      final usage = await rust_cache.cacheUsage(
        chunkDirs: _chunkDirs,
        artworkDir: _artworkCacheDir ?? '',
      );
      _cachedTrackCount = usage.trackCount;

      int pinnedBytes = 0;
      int cacheBytes = usage.audioBytes.toInt();
      int cacheLimitBytes = _cacheLimitBytes;

      try {
        final activeTrack = nowPlayingTrackProvider?.call();
        final stats = await rust_cache.cloudCacheGetStats(
          pinnedFileIds: _pinnedTrackIds.toList(),
          activeFileId: activeTrack?.id,
        );
        pinnedBytes = stats.pinnedBytes.toInt();
        cacheBytes = stats.unpinnedBytes.toInt();
        cacheLimitBytes = stats.cacheLimitBytes.toInt();
        _cacheLimitBytes = cacheLimitBytes;
      } catch (_) {}

      final pinnedItems = <PinnedItem>[];
      for (final trackId in _pinnedTrackIds) {
        final t = lookupTrack(trackId);
        if (t != null) {
          pinnedItems.add(PinnedItem(
            id: t.id,
            title: t.title,
            subtitle: t.artist,
            sizeBytes: t.sizeBytes,
            kind: 'Track',
          ));
        }
      }
      for (final albumId in _pinnedAlbumIds) {
        final a = _cloudAlbums.where((a) => a.id == albumId).firstOrNull ??
            (_realAlbum?.id == albumId ? _realAlbum : null);
        if (a != null) {
          pinnedItems.add(PinnedItem(
            id: a.id,
            title: a.title,
            subtitle: '${a.artist} · ${a.trackCount} tracks',
            sizeBytes: a.sizeBytes,
            kind: 'Album',
          ));
        }
      }

      if (!_storage.isClosed) {
        _storage.add(StorageState(
          pinnedBytes: pinnedBytes,
          cacheBytes: cacheBytes,
          freeBytes: 0,
          totalBytes: 0,
          cacheLimitBytes: cacheLimitBytes,
          artworkBytes: usage.artworkBytes.toInt(),
          pinned: pinnedItems,
        ));
      }
    } catch (e) {
      debugPrint('[storage] could not measure cache: $e');
      if (!_storage.isClosed) {
        _storage.add(StorageState(
          pinnedBytes: 0,
          cacheBytes: 0,
          freeBytes: 0,
          totalBytes: 0,
          cacheLimitBytes: _cacheLimitBytes,
        ));
      }
    }
  }

  Future<void> setCacheLimit(int bytes) async {
    _cacheLimitBytes = bytes;
    try {
      await rust_cache.cloudCacheSetLimit(limitBytes: BigInt.from(bytes));
      final chunks = _chunkCacheDir;
      if (chunks != null) {
        final activeTrack = nowPlayingTrackProvider?.call();
        await rust_cache.cloudCachePruneNow(
          chunkDir: chunks,
          pinnedFileIds: _pinnedTrackIds.toList(),
          activeFileId: activeTrack?.id,
        );
      }
    } catch (e) {
      debugPrint('[storage] failed to set cache limit: $e');
    }
    await refreshStorage();
  }

  Future<void> clearCache() async {
    final chunks = _chunkCacheDir;
    if (chunks != null) {
      try {
        final freed = await rust_cache.clearAudioCache(chunkDirs: _chunkDirs);
        debugPrint('[storage] cleared $freed bytes of streamed audio');
      } catch (e) {
        debugPrint('[storage] failed to clear cache: $e');
      }
      await refreshStorage();
    }
  }

  Future<void> downloadTrack(String trackId) async {
    final track = lookupTrack(trackId);
    final chunksDir = _chunkCacheDir;
    if (track == null || chunksDir == null) return;
    final dir = Directory(chunksDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final isCloud = _cloud?.trackById(trackId) != null;
    if (!isCloud) return;

    try {
      final token = await accessTokenProvider?.call();
      if (token == null) {
        debugPrint('[download] no access token available for $trackId');
        return;
      }

      await rust_cache.cloudDownloadTrack(
        fileId: trackId,
        url: 'https://www.googleapis.com/drive/v3/files/$trackId?alt=media',
        authToken: token,
        totalSize: BigInt.from(track.sizeBytes),
        cacheDir: chunksDir,
      );
      if (!_pinnedTrackIds.contains(trackId)) deleteDiskCacheFor(trackId);
      await refreshStorage();
    } catch (e) {
      debugPrint('[download] error downloading track $trackId: $e');
    }
  }

  Future<void> downloadAlbum(String albumId) async {
    final tracks = albumId == 'album-favorites'
        ? allCandidateTracks
            .where((t) => _favoriteTrackIds.contains(t.id))
            .toList()
        : allCandidateTracks.where((t) => t.albumId == albumId).toList();
    for (final t in tracks) {
      _pinnedTrackIds.add(t.id);
    }
    await savePinned();
    for (final t in tracks) {
      await downloadTrack(t.id);
    }
  }

  Future<void> setFavorite({
    required String trackId,
    required bool favorite,
  }) async {
    if (favorite) {
      _favoriteTrackIds.add(trackId);
    } else {
      _favoriteTrackIds.remove(trackId);
    }
    await saveFavorites();
  }

  Future<void> pin({required String id, required String kind}) async {
    if (kind == 'track') {
      _pinnedTrackIds.add(id);
      await savePinned();
      unawaited(downloadTrack(id));
    } else if (kind == 'album' || kind == 'playlist') {
      _pinnedAlbumIds.add(id);
      await savePinned();
      unawaited(downloadAlbum(id));
    }
  }

  Future<void> unpin({required String id, required String kind}) async {
    if (kind == 'track') {
      _pinnedTrackIds.remove(id);
      deleteDiskCacheFor(id);
      await savePinned();
      await refreshStorage();
    } else if (kind == 'album' || kind == 'playlist') {
      _pinnedAlbumIds.remove(id);
      final albumTracks = id == 'album-favorites'
          ? allCandidateTracks
              .where((t) => _favoriteTrackIds.contains(t.id))
              .toList()
          : allCandidateTracks.where((t) => t.albumId == id).toList();
      for (final t in albumTracks) {
        _pinnedTrackIds.remove(t.id);
        deleteDiskCacheFor(t.id);
      }
      await savePinned();
      await refreshStorage();
    }
  }

  Future<void> rescan({String? sourceId}) async {
    if (_cloud != null) {
      await _cloud.scan();
    }
  }

  Future<Paged<Album>> albums(AlbumQuery q) async {
    final favAlbum = favoritesAlbum();
    var items = <Album>[
      if (q.artistId == null) favAlbum,
      ..._cloudAlbums.map(enrichAlbum),
      if (_realAlbum != null) enrichAlbum(_realAlbum!),
    ];
    if (q.filters.genre != null && q.filters.genre!.isNotEmpty) {
      items = items
          .where(
              (a) => a.genre?.toLowerCase() == q.filters.genre!.toLowerCase())
          .toList();
    }
    return Paged(items: items, total: items.length);
  }

  Future<Paged<Track>> tracks(TrackQuery q) async {
    if (q.albumId != null || q.playlistId != null) {
      if (q.albumId == 'album-favorites' ||
          q.playlistId == 'album-favorites' ||
          q.playlistId == 'pl-favorites') {
        final favs = allCandidateTracks
            .where((t) => _favoriteTrackIds.contains(t.id))
            .map(enrichTrack)
            .toList();
        final unique = <String, Track>{};
        for (final t in favs) {
          unique[t.id] = t;
        }
        final list = unique.values.toList();
        return Paged(items: list, total: list.length);
      }
      final cloud = _cloudTracks
          .where((t) => t.albumId == q.albumId)
          .map(enrichTrack)
          .toList();
      if (cloud.isNotEmpty) return Paged(items: cloud, total: cloud.length);
      final real = _realTracks.values
          .where((t) => t.albumId == q.albumId)
          .map(enrichTrack)
          .toList();
      if (real.isNotEmpty) return Paged(items: real, total: real.length);
      if (q.albumId == 'real-music') {
        return Paged(
            items: _realTracks.values.map(enrichTrack).toList(),
            total: _realTracks.length);
      }
      return const Paged(items: [], total: 0);
    }

    final items = <Track>[
      ..._cloudTracks.map(enrichTrack),
      ..._realTracks.values.map(enrichTrack),
    ];
    return Paged(items: items, total: items.length);
  }

  Future<Album?> album(String id) async {
    if (id == 'album-favorites') return favoritesAlbum();
    for (final a in _cloudAlbums) {
      if (a.id == id) return enrichAlbum(a);
    }
    if (_realAlbum != null && (_realAlbum!.id == id || id == 'real-music')) {
      return enrichAlbum(_realAlbum!);
    }
    return null;
  }

  Future<Paged<Artist>> artists(ArtistQuery q) async {
    final byId = <String, Artist>{};
    for (final a in _cloudAlbums) {
      final existing = byId[a.artistId];
      byId[a.artistId] = Artist(
        id: a.artistId,
        name: a.artist,
        albumCount: (existing?.albumCount ?? 0) + 1,
        trackCount: (existing?.trackCount ?? 0) + a.trackCount,
        artwork: existing?.artwork ?? a.artwork,
        genres: {...?existing?.genres, if (a.genre != null) a.genre!}.toList(),
      );
    }
    final items = byId.values.toList();
    return Paged(items: items, total: items.length);
  }

  Future<Artist?> artist(String id) async {
    final all = await artists(const ArtistQuery());
    for (final a in all.items) {
      if (a.id == id) return a;
    }
    return null;
  }

  Future<FolderListing> folder(String? folderId) async {
    try {
      final listing =
          await rust_cache.cloudLibraryGetFolder(folderId: folderId);
      final entries = listing.entries.map((e) {
        if (e.isDirectory) {
          return FolderEntry(
            id: e.id,
            name: e.name,
            isDirectory: true,
            itemCount: e.itemCount,
            sizeBytes: e.sizeBytes.toInt(),
          );
        } else {
          Track? track;
          if (e.track != null) {
            track = CloudLibrary.trackFromRow(e.track!);
            _realTracks[track.id] = track;
            track = enrichTrack(track);
          } else {
            track = lookupTrack(e.id);
            if (track != null) {
              track = enrichTrack(track);
            }
          }
          return FolderEntry(
            id: e.id,
            name: e.name,
            isDirectory: false,
            sizeBytes: e.sizeBytes.toInt(),
            track: track,
          );
        }
      }).toList();

      final breadcrumb = listing.breadcrumb
          .map((b) => FolderEntry(
                id: b.id,
                name: b.name,
                isDirectory: true,
              ))
          .toList();

      return FolderListing(
        folderId: listing.folderId,
        breadcrumb: breadcrumb,
        entries: entries,
      );
    } catch (e) {
      debugPrint('[library] failed to get folder $folderId: $e');
      return FolderListing(
        folderId: folderId,
        breadcrumb: const [],
        entries: const [],
      );
    }
  }

  Future<List<Playlist>> playlists() async {
    final favTracks = allCandidateTracks
        .where((t) => _favoriteTrackIds.contains(t.id))
        .map((t) => t.id)
        .toSet();
    return [
      Playlist(
        id: 'album-favorites',
        name: 'Favourites',
        trackCount: favTracks.length,
        durationMs: 0,
        sizeBytes: 0,
        availability: _pinnedAlbumIds.contains('album-favorites')
            ? Availability.pinned
            : Availability.cloudOnly,
        artwork: const Artwork(seed: 777, dominantColor: 0xFFE91E63),
        isSmart: true,
        description: 'Your favourited tracks across all albums.',
      ),
    ];
  }

  Future<List<Genre>> genreDetails() async {
    try {
      final list = await rust_cache.cloudLibraryGetGenres();
      if (list.isNotEmpty) {
        return list.map((g) {
          final paths = g.artworkPath
              .split(';')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty && !s.contains('unknown_artist__unknown_album'))
              .toList();
          return Genre(
            name: g.genre,
            trackCount: g.trackCount,
            albumCount: g.albumCount > 0 ? g.albumCount : (g.trackCount > 0 ? 1 : 0),
            artworkPaths: paths,
            primaryArtwork: paths.isNotEmpty ? paths.first : null,
          );
        }).toList();
      }
    } catch (e) {
      debugPrint('[library] failed to get genre details: $e');
    }

    final map = <String, List<Track>>{};
    for (final t in allCandidateTracks) {
      if (t.genre != null && t.genre!.trim().isNotEmpty) {
        final parts = t.genre!
            .split(RegExp(r'[;,/]'))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty);
        for (final p in parts) {
          map.putIfAbsent(p, () => []).add(t);
        }
      }
    }

    if (map.isNotEmpty) {
      final out = <Genre>[];
      final sortedKeys = map.keys.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      for (final k in sortedKeys) {
        final tracks = map[k]!;
        final albums = tracks.map((t) => t.albumId).toSet().length;
        final arts = tracks
            .map((t) => t.artwork.uri)
            .whereType<String>()
            .where((u) => u.isNotEmpty && !u.contains('unknown_artist__unknown_album'))
            .toSet()
            .take(4)
            .toList();
        out.add(Genre(
          name: k,
          trackCount: tracks.length,
          albumCount: albums > 0 ? albums : 1,
          artworkPaths: arts,
          primaryArtwork: arts.isNotEmpty ? arts.first : null,
        ));
      }
      return out;
    }

    return MockCatalog.genreList.map((name) {
      return Genre(
        name: name,
        trackCount: 12,
        albumCount: 2,
        artworkPaths: const [],
      );
    }).toList();
  }

  Future<List<String>> genres() async {
    final details = await genreDetails();
    if (details.isNotEmpty) {
      return details.map((g) => g.name).toList();
    }
    return MockCatalog.genreList;
  }

  Future<SearchResults> search(String text, SearchFilters f) async {
    final q = text.trim();
    if (q.isEmpty) return const SearchResults();
    final lq = q.toLowerCase();

    bool matchesFormat(AudioFormat fmt) {
      if (lq == 'hi-res' || lq == 'hires') return fmt.isHiRes;
      if (fmt.codec.label.toLowerCase() == lq) return true;
      if (fmt.shortLabel.toLowerCase() == lq) return true;
      if (fmt.badgeLabel.toLowerCase() == lq) return true;
      if (lq.endsWith('khz') &&
          fmt.shortLabel
              .toLowerCase()
              .contains(lq.replaceAll('khz', '').trim())) {
        return true;
      }
      return false;
    }

    bool keepTrack(Track t) {
      if (f.offlineOnly &&
          !_pinnedTrackIds.contains(t.id) &&
          !isTrackFullyCached(t.id, t.sizeBytes)) {
        return false;
      }
      if (f.codecs.isNotEmpty && !f.codecs.contains(t.format.codec)) {
        return false;
      }
      if (f.quality == QualityFilter.hiRes && !t.format.isHiRes) return false;
      if (f.quality == QualityFilter.cdQuality && !t.format.isCdQuality) {
        return false;
      }
      if (f.quality == QualityFilter.lossy && t.format.codec.isLossless) {
        return false;
      }
      return true;
    }

    bool keepAlbum(Album a) {
      if (f.codecs.isNotEmpty && !f.codecs.contains(a.format.codec)) {
        return false;
      }
      if (f.quality == QualityFilter.hiRes && !a.format.isHiRes) return false;
      if (f.quality == QualityFilter.cdQuality && !a.format.isCdQuality) {
        return false;
      }
      if (f.quality == QualityFilter.lossy && a.format.codec.isLossless) {
        return false;
      }
      return true;
    }

    final ftsTracks =
        _cloud != null ? await _cloud.search(q, limit: 50) : const <Track>[];
    final cloudMatching = _cloudTracks.where((t) =>
        t.title.toLowerCase().contains(lq) ||
        t.artist.toLowerCase().contains(lq) ||
        t.albumTitle.toLowerCase().contains(lq) ||
        matchesFormat(t.format));
    final localMatching = _realTracks.values.where((t) =>
        t.title.toLowerCase().contains(lq) ||
        t.artist.toLowerCase().contains(lq) ||
        t.albumTitle.toLowerCase().contains(lq) ||
        matchesFormat(t.format));
    final mockMatching = MockCatalog.tracks.where((t) =>
        t.title.toLowerCase().contains(lq) ||
        t.artist.toLowerCase().contains(lq) ||
        t.albumTitle.toLowerCase().contains(lq) ||
        matchesFormat(t.format));

    final seenTrackIds = <String>{};
    final allTracks = <Track>[];
    final trackSources = [
      ftsTracks,
      cloudMatching,
      localMatching,
      if (_cloudTracks.isEmpty && _realTracks.isEmpty) mockMatching,
    ];
    for (final source in trackSources) {
      for (final t in source) {
        if (seenTrackIds.add(t.id) && keepTrack(t)) {
          allTracks.add(t);
        }
      }
    }

    final seenAlbumIds = <String>{};
    final allAlbums = <Album>[];
    final favAlbum = favoritesAlbum();
    final candidateAlbums = [
      if (favAlbum.trackCount > 0) favAlbum,
      ..._cloudAlbums.map(enrichAlbum),
      if (_realAlbum != null) enrichAlbum(_realAlbum!),
      if (_cloudAlbums.isEmpty && _realAlbum == null)
        ...MockCatalog.albums.map(enrichAlbum),
    ];
    for (final a in candidateAlbums) {
      if (seenAlbumIds.add(a.id) && keepAlbum(a)) {
        if (a.title.toLowerCase().contains(lq) ||
            a.artist.toLowerCase().contains(lq) ||
            matchesFormat(a.format)) {
          allAlbums.add(a);
        }
      }
    }

    final seenArtistIds = <String>{};
    final allArtists = <Artist>[];
    final candidateArtists = [
      ...(await artists(const ArtistQuery())).items,
      if (_cloudAlbums.isEmpty && _realAlbum == null) ...MockCatalog.artists,
    ];
    for (final art in candidateArtists) {
      if (seenArtistIds.add(art.id)) {
        if (art.name.toLowerCase().contains(lq)) {
          allArtists.add(art);
        }
      }
    }

    final seenFolders = <String>{};
    final allFolders = <FolderEntry>[];
    for (final t in allTracks) {
      final p = t.folderPath;
      if (p.isNotEmpty && p.toLowerCase().contains(lq)) {
        if (seenFolders.add(p)) {
          final folderName =
              p.split('/').where((s) => s.isNotEmpty).lastOrNull ?? p;
          allFolders.add(FolderEntry(
            id: p,
            name: folderName,
            isDirectory: true,
            itemCount: 1,
          ));
        }
      }
    }

    final exactAlbum = allAlbums.cast<Album?>().firstWhere(
          (a) =>
              a!.title.toLowerCase() == lq ||
              a.title.toLowerCase().startsWith(lq),
          orElse: () => null,
        );
    final exactArtist = allArtists.cast<Artist?>().firstWhere(
          (art) =>
              art!.name.toLowerCase() == lq ||
              art.name.toLowerCase().startsWith(lq),
          orElse: () => null,
        );
    final exactTrack = allTracks.cast<Track?>().firstWhere(
          (t) =>
              t!.title.toLowerCase() == lq ||
              t.title.toLowerCase().startsWith(lq),
          orElse: () => null,
        );

    final enrichedTracks = allTracks.map(enrichTrack).toList();
    final enrichedAlbums = allAlbums.map(enrichAlbum).toList();

    final topResult = exactAlbum != null
        ? enrichAlbum(exactAlbum)
        : (exactArtist ??
            (exactTrack != null
                ? enrichTrack(exactTrack)
                : (enrichedAlbums.isNotEmpty
                    ? enrichedAlbums.first
                    : (enrichedTracks.isNotEmpty
                        ? enrichedTracks.first
                        : allArtists.firstOrNull))));

    return SearchResults(
      topResult: topResult,
      tracks: enrichedTracks.take(30).toList(),
      albums: enrichedAlbums.take(15).toList(),
      artists: allArtists.take(10).toList(),
      folders: allFolders.take(8).toList(),
    );
  }

  Future<List<String>> recentSearches() async {
    if (_recentSearchesList != null) {
      return List.unmodifiable(_recentSearchesList!);
    }
    final file = _recentSearchesFile;
    if (file != null && await file.exists()) {
      try {
        final text = await file.readAsString();
        final raw = jsonDecode(text);
        if (raw is List) {
          _recentSearchesList = raw.map((e) => e.toString()).toList();
          return List.unmodifiable(_recentSearchesList!);
        }
      } catch (e) {
        debugPrint('[search] failed to read recent searches: $e');
      }
    }
    _recentSearchesList = [];
    return const [];
  }

  Future<void> recordRecentSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    if (_recentSearchesList == null) {
      await recentSearches();
    }
    _recentSearchesList!.remove(q);
    _recentSearchesList!.insert(0, q);
    if (_recentSearchesList!.length > 15) {
      _recentSearchesList!.removeRange(15, _recentSearchesList!.length);
    }
    final file = _recentSearchesFile;
    if (file != null) {
      try {
        await file.writeAsString(jsonEncode(_recentSearchesList));
      } catch (e) {
        debugPrint('[search] failed to write recent searches: $e');
      }
    }
  }

  Future<void> removeRecentSearch(String query) async {
    if (_recentSearchesList == null) {
      await recentSearches();
    }
    _recentSearchesList!.remove(query);
    final file = _recentSearchesFile;
    if (file != null) {
      try {
        await file.writeAsString(jsonEncode(_recentSearchesList));
      } catch (e) {
        debugPrint('[search] failed to update recent searches: $e');
      }
    }
  }

  Future<void> clearRecentSearches() async {
    _recentSearchesList = [];
    final file = _recentSearchesFile;
    if (file != null && await file.exists()) {
      try {
        await file.delete();
      } catch (e) {
        debugPrint('[search] failed to delete recent searches: $e');
      }
    }
  }

  Future<rust_cache.CloudTrackLyrics?> getLyrics(Track track) async {
    try {
      final res = await rust_cache.cloudLibraryGetLyrics(
        fileId: track.id,
        artist: track.artist,
        title: track.title,
        album: track.albumTitle,
        durationSecs: track.durationMs ~/ 1000,
      );
      if (res != null) return res;
    } catch (e) {
      debugPrint('[library] failed to get lyrics from rust: $e');
    }
    return null;
  }

  Future<void> saveLyrics({
    required String fileId,
    required rust_cache.CloudTrackLyrics lyrics,
  }) async {
    try {
      await rust_cache.cloudLibrarySaveLyrics(fileId: fileId, lyrics: lyrics);
    } catch (e) {
      debugPrint('[library] failed to save lyrics to rust: $e');
    }
  }

  Future<void> recordPlayback({
    required String fileId,
    required int listenedMs,
    int? sampleRate,
    int? bitDepth,
  }) async {
    try {
      await rust_cache.cloudLibraryRecordPlayback(
        fileId: fileId,
        listenedMs: listenedMs,
        sampleRate: sampleRate,
        bitDepth: bitDepth,
      );
    } catch (e) {
      debugPrint('[library] failed to record playback: $e');
    }
  }

  Future<rust_cache.CloudListeningRecap?> getListeningRecap() async {
    try {
      return await rust_cache.cloudLibraryGetListeningRecap();
    } catch (e) {
      debugPrint('[library] failed to get listening recap: $e');
      return null;
    }
  }

  void dispose() {
    _cloudStatusSub?.cancel();
    _syncStatus.close();
    _defaultSources.close();
    _storage.close();
  }
}

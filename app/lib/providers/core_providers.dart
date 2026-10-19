import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core_api/bitdrop_core.dart';
import '../core_api/commands.dart';
import '../core_api/models.dart';
import '../core_api/queries.dart';
import '../core_api/settings.dart';
import '../core_mock/dev_env.dart';
import '../core_mock/scenarios.dart';
import '../core_live/live_core.dart';
import '../core_live/audio_handler.dart';

import '../core_live/cloud_library.dart';
import '../features/storage/google_drive_service.dart';

late final BitDropAudioHandler globalAudioHandler;

/// Created in `main()` so the audio handler can take a token provider from it
/// before the widget tree exists.
late final GoogleDriveService globalDriveService;

/// The one Drive connection. Screens must take it from here rather than
/// constructing their own, or each would hold a separate sign-in state.
final driveServiceProvider =
    Provider<GoogleDriveService>((ref) => globalDriveService);

/// Where streamed audio chunks and cover art live on disk. Set in `main()`,
/// which is the only place that knows the platform cache directory.
late final String globalChunkCacheDir;
late final String globalArtworkCacheDir;

/// The cloud index. Also created in `main()`, because the core needs it at
/// construction time.
late final CloudLibrary globalCloudLibrary;

final cloudLibraryProvider =
    Provider<CloudLibrary>((ref) => globalCloudLibrary);

/// Live scan progress, for the Home banner and the Sources card.
final cloudScanStatusProvider =
    StreamProvider((ref) => ref.watch(cloudLibraryProvider).status);

/// The signed-in Google account, or null. Drives the Sources screen and the
/// "needs reconnection" banner.
final driveAccountProvider = StreamProvider((ref) =>
    ref.watch(driveServiceProvider).accountStream);


/// The single core instance. In production this is replaced by the
/// flutter_rust_bridge handle; nothing above this line changes.
final coreProvider = Provider<BitDropCore>((ref) {
  final core = LiveBitDropCore(
    globalAudioHandler,
    cloudLibrary: globalCloudLibrary,
    chunkCacheDir: globalChunkCacheDir,
    artworkCacheDir: globalArtworkCacheDir,
  );
  ref.onDispose(core.dispose);
  return core;
});


/// Debug runs may open in a specific scenario (see `DevEnv`).
final Scenario _startScenario = DevEnv.scenarioId == null
    ? Scenarios.initial
    : Scenarios.byId(DevEnv.scenarioId!);

/// Convenience alias so feature code can depend on the interface, not the mock.
final coreApiProvider = Provider<BitDropCore>((ref) => ref.watch(coreProvider));

/// Bumped whenever the scenario changes, so cached queries refetch. Streams do
/// not need this — they re-emit on their own.
final scenarioRevisionProvider = StateProvider<int>((ref) => 0);
final libraryRevisionProvider = StateProvider<int>((ref) => 0);

final currentScenarioProvider =
    StateProvider<Scenario>((ref) => _startScenario);

/// Switches the whole simulated world.
void switchScenario(WidgetRef ref, Scenario s) {
  // ref.read(coreProvider).switchScenario(s);
  ref.read(currentScenarioProvider.notifier).state = s;
  ref.read(scenarioRevisionProvider.notifier).state++;
}

/// Fire-and-forget command dispatch.
void sendCommand(WidgetRef ref, PlayerCommand cmd) {
  // The core returns a Future only so the real bridge can be async; the UI
  // intentionally does not await it — results arrive on the streams. But a
  // thrown command used to vanish into ignore(), which made a dead button
  // indistinguishable from a working one.
  ref.read(coreProvider).send(cmd).then((_) {
    if (cmd is SetFavorite || cmd is Pin || cmd is Unpin) {
      ref.read(libraryRevisionProvider.notifier).state++;
    }
  }).catchError((Object e, StackTrace st) {
    debugPrint('[bitdrop] command ${cmd.runtimeType} failed: $e\n$st');
  });
}

// ---- State streams ---------------------------------------------------------

final playbackProvider =
    StreamProvider<PlaybackState>((ref) => ref.watch(coreProvider).playback);

/// ~30 Hz. **Only** the seek bar and its time labels may watch this.
final positionProvider =
    StreamProvider<PositionInfo>((ref) => ref.watch(coreProvider).position);

final nowPlayingProvider =
    StreamProvider<NowPlaying?>((ref) => ref.watch(coreProvider).nowPlaying);

final signalPathProvider =
    StreamProvider<SignalPath>((ref) => ref.watch(coreProvider).signalPath);

final queueProvider =
    StreamProvider<QueueState>((ref) => ref.watch(coreProvider).queue);

final outputDeviceProvider = StreamProvider<OutputDevice?>(
    (ref) => ref.watch(coreProvider).outputDevice);

final sourcesProvider = StreamProvider<List<SourceAccount>>(
    (ref) => ref.watch(coreProvider).sources);

final syncStatusProvider =
    StreamProvider<SyncStatus>((ref) => ref.watch(coreProvider).syncStatus);

final bannersProvider =
    StreamProvider<List<AppBanner>>((ref) => ref.watch(coreProvider).banners);

final eqProvider = StreamProvider<EqState>((ref) => ref.watch(coreProvider).eq);

final storageProvider =
    StreamProvider<StorageState>((ref) => ref.watch(coreProvider).storage);

final diagnosticsProvider = StreamProvider<DiagnosticsSnapshot>(
    (ref) => ref.watch(coreProvider).diagnostics);

final visualizerProvider = StreamProvider<VisualizerFrame>(
    (ref) => ref.watch(coreProvider).visualizer);

final deviceProfilesProvider = StreamProvider<List<DeviceProfile>>(
    (ref) => ref.watch(coreProvider).deviceProfiles);

final settingsProvider =
    StreamProvider<AppSettings>((ref) => ref.watch(coreProvider).settings);

/// Settings with a guaranteed value, for the places that cannot show a spinner
/// (theme selection, text scale). The core always has a current value.
final settingsValueProvider = Provider<AppSettings>((ref) {
  return ref.watch(settingsProvider).maybeWhen(
        data: (s) => s,
        orElse: () => const AppSettings(themeMode: AppThemeMode.system, oledBlack: false, textScale: 1.0, reduceMotion: false),
      );
});


// ---- Query providers -------------------------------------------------------

final albumsProvider =
    FutureProvider.family<Paged<Album>, AlbumQuery>((ref, q) {
  ref.watch(scenarioRevisionProvider);
  ref.watch(libraryRevisionProvider);
  return ref.watch(coreProvider).albums(q);
});

final tracksProvider =
    FutureProvider.family<Paged<Track>, TrackQuery>((ref, q) {
  ref.watch(scenarioRevisionProvider);
  ref.watch(libraryRevisionProvider);
  return ref.watch(coreProvider).tracks(q);
});

final artistsProvider =
    FutureProvider.family<Paged<Artist>, ArtistQuery>((ref, q) {
  ref.watch(scenarioRevisionProvider);
  ref.watch(libraryRevisionProvider);
  return ref.watch(coreProvider).artists(q);
});

final albumProvider = FutureProvider.family<Album?, String>((ref, id) {
  ref.watch(scenarioRevisionProvider);
  ref.watch(libraryRevisionProvider);
  return ref.watch(coreProvider).album(id);
});

final artistProvider = FutureProvider.family<Artist?, String>((ref, id) {
  ref.watch(scenarioRevisionProvider);
  ref.watch(libraryRevisionProvider);
  return ref.watch(coreProvider).artist(id);
});

final folderProvider = FutureProvider.family<FolderListing, String?>((ref, id) {
  ref.watch(scenarioRevisionProvider);
  return ref.watch(coreProvider).folder(id);
});

final playlistsProvider = FutureProvider<List<Playlist>>((ref) {
  ref.watch(scenarioRevisionProvider);
  ref.watch(libraryRevisionProvider);
  return ref.watch(coreProvider).playlists();
});

final genresProvider = FutureProvider<List<String>>((ref) {
  ref.watch(scenarioRevisionProvider);
  return ref.watch(coreProvider).genres();
});

final autoEqSearchProvider =
    FutureProvider.family<List<AutoEqProfile>, String>((ref, model) {
  return ref.watch(coreProvider).searchAutoEq(model);
});

final recentSearchesRevisionProvider = StateProvider<int>((ref) => 0);

final recentSearchesProvider = FutureProvider<List<String>>((ref) {
  ref.watch(recentSearchesRevisionProvider);
  return ref.watch(coreProvider).recentSearches();
});

Future<void> recordRecentSearch(WidgetRef ref, String query) async {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return;
  await ref.read(coreProvider).recordRecentSearch(trimmed);
  ref.read(recentSearchesRevisionProvider.notifier).state++;
}

Future<void> removeRecentSearch(WidgetRef ref, String query) async {
  await ref.read(coreProvider).removeRecentSearch(query);
  ref.read(recentSearchesRevisionProvider.notifier).state++;
}

Future<void> clearRecentSearches(WidgetRef ref) async {
  await ref.read(coreProvider).clearRecentSearches();
  ref.read(recentSearchesRevisionProvider.notifier).state++;
}

// ---- Search ---------------------------------------------------------------

final searchQueryProvider = StateProvider<String>((ref) => '');
final searchFiltersProvider =
    StateProvider<SearchFilters>((ref) => const SearchFilters());

final searchResultsProvider = FutureProvider<SearchResults>((ref) async {
  final text = ref.watch(searchQueryProvider);
  final filters = ref.watch(searchFiltersProvider);
  ref.watch(scenarioRevisionProvider);
  if (text.trim().isEmpty) return const SearchResults();
  return ref.watch(coreProvider).search(text, filters);
});

// ---- Library view state ---------------------------------------------------

enum LibraryTab { albums, artists, tracks, folders, genres, playlists }

final libraryTabProvider =
    StateProvider<LibraryTab>((ref) => LibraryTab.albums);
final libraryFiltersProvider =
    StateProvider<LibraryFilters>((ref) => const LibraryFilters());
final albumSortProvider = StateProvider<AlbumSort>((ref) => AlbumSort.title);
final albumSortDescProvider = StateProvider<bool>((ref) => false);
final libraryGridViewProvider = StateProvider<bool>((ref) => true);
final trackSortProvider = StateProvider<TrackSort>((ref) => TrackSort.title);

/// Multi-select state for library long-press.
final selectionProvider = StateProvider<Set<String>>((ref) => const {});

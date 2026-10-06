import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core_api/bitdrop_core.dart';
import '../core_api/commands.dart';
import '../core_api/models.dart';
import '../core_api/queries.dart';
import '../core_api/settings.dart';
import '../core_mock/dev_env.dart';
import '../core_mock/mock_core.dart';
import '../core_mock/scenarios.dart';

/// The single core instance. In production this is replaced by the
/// flutter_rust_bridge handle; nothing above this line changes.
final coreProvider = Provider<MockBitDropCore>((ref) {
  final core = MockBitDropCore(scenario: _startScenario);
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

final currentScenarioProvider =
    StateProvider<Scenario>((ref) => _startScenario);

/// Switches the whole simulated world.
void switchScenario(WidgetRef ref, Scenario s) {
  ref.read(coreProvider).switchScenario(s);
  ref.read(currentScenarioProvider.notifier).state = s;
  ref.read(scenarioRevisionProvider.notifier).state++;
}

/// Fire-and-forget command dispatch.
void sendCommand(WidgetRef ref, PlayerCommand cmd) {
  // The core returns a Future only so the real bridge can be async; the UI
  // intentionally does not await it — results arrive on the streams.
  ref.read(coreProvider).send(cmd).ignore();
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
        orElse: () => ref.watch(coreProvider).settingsValue,
      );
});

/// One-shot core events (skips, confirmations) surfaced as snackbars.
final coreEventsProvider =
    StreamProvider<CoreEvent>((ref) => ref.watch(coreProvider).events);

// ---- Query providers -------------------------------------------------------

final albumsProvider =
    FutureProvider.family<Paged<Album>, AlbumQuery>((ref, q) {
  ref.watch(scenarioRevisionProvider);
  return ref.watch(coreProvider).albums(q);
});

final tracksProvider =
    FutureProvider.family<Paged<Track>, TrackQuery>((ref, q) {
  ref.watch(scenarioRevisionProvider);
  return ref.watch(coreProvider).tracks(q);
});

final artistsProvider =
    FutureProvider.family<Paged<Artist>, ArtistQuery>((ref, q) {
  ref.watch(scenarioRevisionProvider);
  return ref.watch(coreProvider).artists(q);
});

final albumProvider = FutureProvider.family<Album?, String>((ref, id) {
  ref.watch(scenarioRevisionProvider);
  return ref.watch(coreProvider).album(id);
});

final artistProvider = FutureProvider.family<Artist?, String>((ref, id) {
  ref.watch(scenarioRevisionProvider);
  return ref.watch(coreProvider).artist(id);
});

final folderProvider = FutureProvider.family<FolderListing, String?>((ref, id) {
  ref.watch(scenarioRevisionProvider);
  return ref.watch(coreProvider).folder(id);
});

final playlistsProvider = FutureProvider<List<Playlist>>((ref) {
  ref.watch(scenarioRevisionProvider);
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

final recentSearchesProvider = FutureProvider<List<String>>(
    (ref) => ref.watch(coreProvider).recentSearches());

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

import 'commands.dart';
import 'models.dart';
import 'queries.dart';
import 'settings.dart';

/// The one boundary between the Flutter UI and the Rust engine.
///
/// The UI is a **display-only client**: it renders what these streams emit and
/// sends [PlayerCommand]s. It never computes a tier, a quality label or any
/// playback decision itself. `core_mock/` implements this for the prototype;
/// the Rust core will implement the same shape over flutter_rust_bridge.
///
/// Subscription rule: a widget listens to the **narrowest** stream it needs.
/// [position] ticks ~30 times a second and may only rebuild the seek bar and
/// its time labels.
abstract interface class BitDropCore {
  // ---- Streams -------------------------------------------------------------

  Stream<PlaybackState> get playback;

  /// ~30 Hz. Seek bar and time labels only.
  Stream<PositionInfo> get position;

  Stream<NowPlaying?> get nowPlaying;

  /// The honest account of the output path. Source of every quality label.
  Stream<SignalPath> get signalPath;

  Stream<QueueState> get queue;

  Stream<OutputDevice?> get outputDevice;

  Stream<List<SourceAccount>> get sources;

  Stream<SyncStatus> get syncStatus;

  /// Global banners: reconnect needed, DAC events, rate limiting.
  Stream<List<AppBanner>> get banners;

  Stream<EqState> get eq;

  Stream<StorageState> get storage;

  Stream<DiagnosticsSnapshot> get diagnostics;

  /// Mocked meter/spectrum data for the Studio style. <=30 Hz.
  Stream<VisualizerFrame> get visualizer;

  /// Known devices and their saved profiles.
  Stream<List<DeviceProfile>> get deviceProfiles;

  /// Every user-settable option. Written with [SetSetting].
  Stream<AppSettings> get settings;

  // ---- Queries -------------------------------------------------------------

  Future<Paged<Album>> albums(AlbumQuery q);
  Future<Paged<Track>> tracks(TrackQuery q);
  Future<Paged<Artist>> artists(ArtistQuery q);
  Future<Album?> album(String id);
  Future<Artist?> artist(String id);
  Future<FolderListing> folder(String? folderId);
  Future<List<Playlist>> playlists();
  Future<List<String>> genres();
  Future<SearchResults> search(String text, SearchFilters f);
  Future<List<AutoEqProfile>> searchAutoEq(String model);
  Future<List<String>> recentSearches();

  // ---- Commands ------------------------------------------------------------

  /// Fire-and-forget. Results arrive through the streams above.
  Future<void> send(PlayerCommand cmd);

  /// Releases stream controllers and timers.
  void dispose();
}

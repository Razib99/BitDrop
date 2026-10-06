import 'package:flutter/foundation.dart';

import 'enums.dart';

/// A concrete audio format.
///
/// Mirrors `StreamInfo` in `spike-drive/src/models.rs`: [sampleRate] is
/// `sample_rate`, [bitDepth] is `bits_per_sample`, [channels] is `channels`.
@immutable
class AudioFormat {
  const AudioFormat({
    required this.codec,
    required this.bitDepth,
    required this.sampleRate,
    this.bitrateKbps,
    this.channels = 2,
  });

  final Codec codec;

  /// `bits_per_sample` in the Rust core.
  final int bitDepth;

  /// Hertz, e.g. 96000.
  final int sampleRate;
  final int? bitrateKbps;
  final int channels;

  /// `24/96` — the compact form used in badges.
  String get shortLabel => '$bitDepth/${_rateLabel(sampleRate)}';

  /// `FLAC · 24/96`
  String get badgeLabel => '${codec.label} $shortLabel';

  /// `24-bit · 96 kHz`
  String get longLabel => '$bitDepth-bit · ${_rateLabel(sampleRate)} kHz';

  /// Hi-Res by the common definition: above CD depth or above 48 kHz.
  bool get isHiRes => bitDepth > 16 || sampleRate > 48000;

  bool get isCdQuality => bitDepth == 16 && sampleRate == 44100;

  static String _rateLabel(int hz) {
    final khz = hz / 1000.0;
    return khz == khz.roundToDouble()
        ? khz.round().toString()
        : khz.toStringAsFixed(1);
  }

  AudioFormat copyWith({
    Codec? codec,
    int? bitDepth,
    int? sampleRate,
    int? bitrateKbps,
    int? channels,
  }) =>
      AudioFormat(
        codec: codec ?? this.codec,
        bitDepth: bitDepth ?? this.bitDepth,
        sampleRate: sampleRate ?? this.sampleRate,
        bitrateKbps: bitrateKbps ?? this.bitrateKbps,
        channels: channels ?? this.channels,
      );

  @override
  bool operator ==(Object other) =>
      other is AudioFormat &&
      other.codec == codec &&
      other.bitDepth == bitDepth &&
      other.sampleRate == sampleRate &&
      other.bitrateKbps == bitrateKbps &&
      other.channels == channels;

  @override
  int get hashCode =>
      Object.hash(codec, bitDepth, sampleRate, bitrateKbps, channels);
}

/// A half-open span of the track, in milliseconds, that is on disk.
@immutable
class CachedRange {
  const CachedRange(this.startMs, this.endMs);
  final int startMs;
  final int endMs;

  bool contains(int ms) => ms >= startMs && ms < endMs;

  @override
  bool operator ==(Object other) =>
      other is CachedRange && other.startMs == startMs && other.endMs == endMs;

  @override
  int get hashCode => Object.hash(startMs, endMs);
}

/// High-frequency position payload (~30 Hz). Only the seek bar and time labels
/// may subscribe to this.
@immutable
class PositionInfo {
  const PositionInfo({
    required this.positionMs,
    required this.durationMs,
    this.cachedRanges = const [],
    this.bufferAheadMs = 0,
  });

  final int positionMs;
  final int durationMs;

  /// Can be non-contiguous after seeks.
  final List<CachedRange> cachedRanges;
  final int bufferAheadMs;

  static const empty = PositionInfo(positionMs: 0, durationMs: 0);

  double get fraction =>
      durationMs <= 0 ? 0 : (positionMs / durationMs).clamp(0.0, 1.0);

  bool isCachedAt(int ms) => cachedRanges.any((r) => r.contains(ms));
}

sealed class PlaybackState {
  const PlaybackState();

  bool get isPlaying => this is PlayingState;
  bool get isBusy => this is LoadingState || this is BufferingState;
}

class IdleState extends PlaybackState {
  const IdleState();
}

class LoadingState extends PlaybackState {
  const LoadingState();
}

/// [attempt] escalates the copy: 1 = "Buffering…", 2+ = "Slow connection".
class BufferingState extends PlaybackState {
  const BufferingState({
    required this.bufferedMs,
    required this.targetMs,
    this.attempt = 1,
  });

  final int bufferedMs;
  final int targetMs;
  final int attempt;
}

class PlayingState extends PlaybackState {
  const PlayingState();
}

class PausedState extends PlaybackState {
  const PausedState();
}

class ErrorState extends PlaybackState {
  const ErrorState({required this.kind, required this.message});
  final PlaybackErrorKind kind;
  final String message;
}

/// Seeded artwork description. The UI paints a gradient from these values —
/// no network image loading anywhere in the prototype.
@immutable
class Artwork {
  const Artwork({
    required this.seed,
    required this.dominantColor,
    this.hasEmbedded = true,
  });

  final int seed;

  /// ARGB value supplied by the core; drives adaptive Now Playing tinting.
  final int dominantColor;
  final bool hasEmbedded;
}

@immutable
class Track {
  const Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.albumTitle,
    required this.albumId,
    required this.durationMs,
    required this.format,
    required this.availability,
    required this.sizeBytes,
    required this.artwork,
    this.trackNumber,
    this.discNumber = 1,
    this.year,
    this.genre,
    this.folderPath = '',
    this.cachedPercent = 0,
    this.downloadProgress,
    this.hasLyrics = false,
    this.favorite = false,
    this.tagsPending = false,
    this.unsupportedReason,
    this.replayGainDb,
  });

  final String id;
  final String title;
  final String artist;
  final String albumTitle;
  final String albumId;
  final int durationMs;
  final AudioFormat format;
  final Availability availability;
  final int sizeBytes;
  final Artwork artwork;
  final int? trackNumber;
  final int discNumber;
  final int? year;
  final String? genre;
  final String folderPath;

  /// 0–100, meaningful when [availability] is `partiallyCached`.
  final int cachedPercent;

  /// 0.0–1.0 while pinning.
  final double? downloadProgress;
  final bool hasLyrics;
  final bool favorite;

  /// True while the second scan pass has not yet filled this row's tags; the
  /// UI shimmers the pending fields and shows path-derived names.
  final bool tagsPending;
  final String? unsupportedReason;
  final double? replayGainDb;

  bool get isPlayable =>
      availability != Availability.unavailable &&
      availability != Availability.unsupported &&
      availability != Availability.missing;

  Track copyWith({
    Availability? availability,
    int? cachedPercent,
    double? downloadProgress,
    bool? favorite,
    bool? tagsPending,
  }) =>
      Track(
        id: id,
        title: title,
        artist: artist,
        albumTitle: albumTitle,
        albumId: albumId,
        durationMs: durationMs,
        format: format,
        availability: availability ?? this.availability,
        sizeBytes: sizeBytes,
        artwork: artwork,
        trackNumber: trackNumber,
        discNumber: discNumber,
        year: year,
        genre: genre,
        folderPath: folderPath,
        cachedPercent: cachedPercent ?? this.cachedPercent,
        downloadProgress: downloadProgress ?? this.downloadProgress,
        hasLyrics: hasLyrics,
        favorite: favorite ?? this.favorite,
        tagsPending: tagsPending ?? this.tagsPending,
        unsupportedReason: unsupportedReason,
        replayGainDb: replayGainDb,
      );
}

@immutable
class Album {
  const Album({
    required this.id,
    required this.title,
    required this.artist,
    required this.artistId,
    required this.trackCount,
    required this.durationMs,
    required this.sizeBytes,
    required this.format,
    required this.availability,
    required this.artwork,
    this.year,
    this.genre,
    this.discCount = 1,
    this.mixedFormats = false,
    this.formatVarianceNote,
    this.folderPath = '',
    this.lastModified,
    this.downloadProgress,
    this.isCompilation = false,
    this.playCount = 0,
    this.addedAt,
    this.lastPlayedAt,
    this.tagsPending = false,
  });

  final String id;
  final String title;
  final String artist;
  final String artistId;
  final int trackCount;
  final int durationMs;
  final int sizeBytes;

  /// The album's headline format — the highest resolution it contains.
  final AudioFormat format;
  final Availability availability;
  final Artwork artwork;
  final int? year;
  final String? genre;
  final int discCount;

  /// True when tracks inside differ in sample rate or depth.
  final bool mixedFormats;

  /// Core-supplied gapless warning, e.g. "Tracks 4-5 change sample rate".
  final String? formatVarianceNote;
  final String folderPath;
  final DateTime? lastModified;
  final double? downloadProgress;
  final bool isCompilation;
  final int playCount;
  final DateTime? addedAt;
  final DateTime? lastPlayedAt;
  final bool tagsPending;

  Album copyWith({
    Availability? availability,
    double? downloadProgress,
  }) =>
      Album(
        id: id,
        title: title,
        artist: artist,
        artistId: artistId,
        trackCount: trackCount,
        durationMs: durationMs,
        sizeBytes: sizeBytes,
        format: format,
        availability: availability ?? this.availability,
        artwork: artwork,
        year: year,
        genre: genre,
        discCount: discCount,
        mixedFormats: mixedFormats,
        formatVarianceNote: formatVarianceNote,
        folderPath: folderPath,
        lastModified: lastModified,
        downloadProgress: downloadProgress ?? this.downloadProgress,
        isCompilation: isCompilation,
        playCount: playCount,
        addedAt: addedAt,
        lastPlayedAt: lastPlayedAt,
        tagsPending: tagsPending,
      );
}

@immutable
class Artist {
  const Artist({
    required this.id,
    required this.name,
    required this.albumCount,
    required this.trackCount,
    required this.artwork,
    this.genres = const [],
  });

  final String id;
  final String name;
  final int albumCount;
  final int trackCount;
  final Artwork artwork;
  final List<String> genres;
}

@immutable
class FolderEntry {
  const FolderEntry({
    required this.id,
    required this.name,
    required this.isDirectory,
    this.itemCount = 0,
    this.sizeBytes = 0,
    this.track,
  });

  final String id;
  final String name;
  final bool isDirectory;
  final int itemCount;
  final int sizeBytes;

  /// Set when [isDirectory] is false.
  final Track? track;
}

@immutable
class FolderListing {
  const FolderListing({
    required this.folderId,
    required this.breadcrumb,
    required this.entries,
  });

  final String? folderId;

  /// Root-first path segments, e.g. `[Drive, Music, Hi-Res]`.
  final List<FolderEntry> breadcrumb;
  final List<FolderEntry> entries;
}

@immutable
class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    required this.trackCount,
    required this.durationMs,
    required this.sizeBytes,
    required this.availability,
    required this.artwork,
    this.isSmart = false,
    this.description,
  });

  final String id;
  final String name;
  final int trackCount;
  final int durationMs;
  final int sizeBytes;
  final Availability availability;
  final Artwork artwork;
  final bool isSmart;
  final String? description;
}

/// What is loaded, plus where it is playing from.
@immutable
class NowPlaying {
  const NowPlaying({
    required this.track,
    required this.contextLabel,
    this.album,
    this.contextId,
  });

  final Track track;

  /// "Album · Glass Harbor", "Playlist · Late Nights".
  final String contextLabel;
  final Album? album;
  final String? contextId;
}

@immutable
class OutputDevice {
  const OutputDevice({
    required this.id,
    required this.name,
    required this.type,
    required this.supportedRates,
    required this.bitDepths,
    required this.hardwareVolume,
    this.maxTier = OutputTier.unknown,
    this.connectionLabel,
  });

  final String id;
  final String name;
  final DeviceType type;

  /// Hertz values the device advertises.
  final List<int> supportedRates;
  final List<int> bitDepths;
  final HardwareVolume hardwareVolume;

  /// Best tier this device can reach on this phone.
  final OutputTier maxTier;
  final String? connectionLabel;

  String get typeLabel => switch (type) {
        DeviceType.usb => 'USB',
        DeviceType.bluetooth => 'Bluetooth',
        DeviceType.phoneSpeaker => 'Phone speaker',
        DeviceType.wiredAnalog => 'Headphone jack',
        DeviceType.unknown => 'Unknown',
      };
}

/// The honest account of what happened to the audio. Everything the UI says
/// about quality comes from this object.
@immutable
class SignalPath {
  const SignalPath({
    required this.tier,
    required this.source,
    required this.requested,
    required this.actual,
    required this.dspActive,
    required this.volume,
    required this.explanation,
    this.dspChain = const [],
    this.device,
    this.sourceLabel = 'Google Drive',
    this.cachedPercent = 0,
    this.throughputMbps,
    this.decoderLabel,
    this.safetyAttenuationDb,
  });

  final OutputTier tier;
  final AudioFormat source;
  final AudioFormat requested;

  /// What was really negotiated with the device.
  final AudioFormat actual;
  final bool dspActive;

  /// e.g. ["EQ: Titan X AutoEQ", "Preamp -6.2 dB"]
  final List<String> dspChain;
  final VolumeMode volume;
  final OutputDevice? device;

  /// Plain-language reason, supplied by the core — never composed in the UI.
  final String explanation;
  final String sourceLabel;
  final int cachedPercent;
  final double? throughputMbps;
  final String? decoderLabel;
  final double? safetyAttenuationDb;

  bool get formatsMatch =>
      requested.sampleRate == actual.sampleRate &&
      requested.bitDepth == actual.bitDepth;
}

@immutable
class QueueItem {
  const QueueItem({
    required this.track,
    required this.id,
    this.preloadedForGapless = false,
    this.gapReason,
    this.isUserAdded = false,
  });

  final Track track;

  /// Stable per-position id so reorder and remove stay unambiguous.
  final String id;
  final bool preloadedForGapless;

  /// Set when a short gap is expected, e.g. "44.1 -> 96 kHz".
  final String? gapReason;
  final bool isUserAdded;
}

@immutable
class QueueState {
  const QueueState({
    required this.items,
    required this.currentIndex,
    required this.shuffle,
    required this.repeat,
    this.contextLabel = '',
    this.history = const [],
  });

  final List<QueueItem> items;
  final int currentIndex;
  final bool shuffle;
  final RepeatMode repeat;
  final String contextLabel;
  final List<QueueItem> history;

  static const empty = QueueState(
    items: [],
    currentIndex: -1,
    shuffle: false,
    repeat: RepeatMode.off,
  );

  QueueItem? get current =>
      currentIndex >= 0 && currentIndex < items.length ? items[currentIndex] : null;

  List<QueueItem> get upNext =>
      currentIndex < 0 ? const [] : items.skip(currentIndex + 1).toList();
}

@immutable
class SourceAccount {
  const SourceAccount({
    required this.id,
    required this.provider,
    required this.accountLabel,
    required this.trackCount,
    required this.folderCount,
    required this.status,
    this.lastSync,
    this.activityLabel,
    this.activityProgress,
    this.changesSinceLastSync,
    this.retryInSeconds,
  });

  final String id;

  /// "Google Drive" — the only provider wired up in v1.
  final String provider;
  final String accountLabel;
  final int trackCount;
  final int folderCount;
  final SourceStatus status;
  final DateTime? lastSync;
  final String? activityLabel;
  final double? activityProgress;

  /// "+24 new, 3 changed, 1 removed"
  final String? changesSinceLastSync;
  final int? retryInSeconds;
}

enum SourceStatus { upToDate, syncing, needsReconnect, rateLimited, offline, error }

@immutable
class SyncStatus {
  const SyncStatus({
    required this.phase,
    this.processed = 0,
    this.total = 0,
    this.retryInSeconds,
    this.wifiOnly = true,
    this.detail,
  });

  final SyncPhase phase;
  final int processed;
  final int total;
  final int? retryInSeconds;
  final bool wifiOnly;
  final String? detail;

  static const idle = SyncStatus(phase: SyncPhase.idle);

  double get progress => total <= 0 ? 0 : (processed / total).clamp(0.0, 1.0);
  bool get isActive => phase == SyncPhase.listing || phase == SyncPhase.tags;
}

/// A global, dismissible message. The core owns the text so copy stays
/// consistent with engine state.
@immutable
class AppBanner {
  const AppBanner({
    required this.id,
    required this.kind,
    required this.message,
    this.actionLabel,
    this.actionCommandId,
    this.dismissible = true,
  });

  final String id;
  final BannerKind kind;
  final String message;
  final String? actionLabel;
  final String? actionCommandId;
  final bool dismissible;
}

@immutable
class EqBand {
  const EqBand({
    required this.id,
    required this.type,
    required this.frequencyHz,
    required this.gainDb,
    required this.q,
    this.enabled = true,
  });

  final int id;
  final BiquadType type;
  final double frequencyHz;
  final double gainDb;
  final double q;
  final bool enabled;

  EqBand copyWith({
    BiquadType? type,
    double? frequencyHz,
    double? gainDb,
    double? q,
    bool? enabled,
  }) =>
      EqBand(
        id: id,
        type: type ?? this.type,
        frequencyHz: frequencyHz ?? this.frequencyHz,
        gainDb: gainDb ?? this.gainDb,
        q: q ?? this.q,
        enabled: enabled ?? this.enabled,
      );
}

@immutable
class EqState {
  const EqState({
    required this.mode,
    required this.bands,
    required this.preampDb,
    required this.bypass,
    this.clippedSamples = 0,
    this.assignedDeviceName,
    this.presetName,
    this.autoPreampDb,
    this.graphicGains = const [],
    this.bassDb = 0,
    this.trebleDb = 0,
    this.balance = 0,
    this.mono = false,
    this.replayGain = ReplayGainMode.off,
    this.replayGainPreampDb = 0,
    this.targetCurve,
  });

  final EqMode mode;
  final List<EqBand> bands;
  final double preampDb;
  final bool bypass;

  /// Reported by the core's clipping meter.
  final int clippedSamples;
  final String? assignedDeviceName;
  final String? presetName;

  /// Core's suggestion for a preamp that avoids clipping.
  final double? autoPreampDb;

  /// 10 ISO band gains, used in [EqMode.graphic].
  final List<double> graphicGains;
  final double bassDb;
  final double trebleDb;
  final double balance;
  final bool mono;
  final ReplayGainMode replayGain;
  final double replayGainPreampDb;

  /// AutoEQ target, drawn as an overlay when a profile is applied.
  final List<({double hz, double db})>? targetCurve;

  /// True when any stage would alter the samples.
  bool get isActive =>
      !bypass &&
      (bands.any((b) => b.enabled && b.gainDb != 0) ||
          preampDb != 0 ||
          bassDb != 0 ||
          trebleDb != 0 ||
          balance != 0 ||
          mono ||
          replayGain != ReplayGainMode.off);

  EqState copyWith({
    EqMode? mode,
    List<EqBand>? bands,
    double? preampDb,
    bool? bypass,
    int? clippedSamples,
    String? presetName,
    List<double>? graphicGains,
    double? bassDb,
    double? trebleDb,
    double? balance,
    bool? mono,
    ReplayGainMode? replayGain,
    double? replayGainPreampDb,
    String? assignedDeviceName,
  }) =>
      EqState(
        mode: mode ?? this.mode,
        bands: bands ?? this.bands,
        preampDb: preampDb ?? this.preampDb,
        bypass: bypass ?? this.bypass,
        clippedSamples: clippedSamples ?? this.clippedSamples,
        assignedDeviceName: assignedDeviceName ?? this.assignedDeviceName,
        presetName: presetName ?? this.presetName,
        autoPreampDb: autoPreampDb,
        graphicGains: graphicGains ?? this.graphicGains,
        bassDb: bassDb ?? this.bassDb,
        trebleDb: trebleDb ?? this.trebleDb,
        balance: balance ?? this.balance,
        mono: mono ?? this.mono,
        replayGain: replayGain ?? this.replayGain,
        replayGainPreampDb: replayGainPreampDb ?? this.replayGainPreampDb,
        targetCurve: targetCurve,
      );
}

@immutable
class AutoEqProfile {
  const AutoEqProfile({
    required this.id,
    required this.model,
    required this.measurementSource,
    required this.target,
    required this.bands,
    required this.suggestedPreampDb,
  });

  final String id;
  final String model;

  /// e.g. "oratory1990", "Crinacle IEC-711".
  final String measurementSource;

  /// e.g. "Harman IE 2019".
  final String target;
  final List<EqBand> bands;
  final double suggestedPreampDb;
}

@immutable
class PinnedItem {
  const PinnedItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.sizeBytes,
    required this.kind,
  });

  final String id;
  final String title;
  final String subtitle;
  final int sizeBytes;

  /// "Album", "Playlist", "Folder".
  final String kind;
}

@immutable
class DownloadJob {
  const DownloadJob({
    required this.id,
    required this.title,
    required this.progress,
    required this.sizeBytes,
    this.paused = false,
  });

  final String id;
  final String title;
  final double progress;
  final int sizeBytes;
  final bool paused;
}

@immutable
class StorageState {
  const StorageState({
    required this.pinnedBytes,
    required this.cacheBytes,
    required this.freeBytes,
    required this.totalBytes,
    required this.cacheLimitBytes,
    this.artworkBytes = 0,
    this.databaseBytes = 0,
    this.pinned = const [],
    this.downloads = const [],
    this.wifiOnlyDownloads = true,
    this.mobilePinPolicy = MobileDataPolicy.ask,
  });

  final int pinnedBytes;
  final int cacheBytes;
  final int freeBytes;
  final int totalBytes;
  final int cacheLimitBytes;
  final int artworkBytes;
  final int databaseBytes;
  final List<PinnedItem> pinned;
  final List<DownloadJob> downloads;
  final bool wifiOnlyDownloads;
  final MobileDataPolicy mobilePinPolicy;

  bool get nearlyFull => freeBytes < 2 * 1024 * 1024 * 1024;
}

/// Live engine telemetry for the Diagnostics screen.
///
/// Network fields mirror `RangeMeasurement` in `spike-drive/src/models.rs`:
/// [speedMbps] is `speed_mbps`, [timeToFirstByteMs] is `time_to_first_byte`,
/// [bytesDownloaded] is `bytes_downloaded`.
@immutable
class DiagnosticsSnapshot {
  const DiagnosticsSnapshot({
    required this.tier,
    required this.requested,
    required this.actual,
    required this.deviceName,
    required this.bufferAheadSeconds,
    required this.pcmFillPercent,
    required this.underrunCount,
    required this.speedMbps,
    required this.activeRangeRequests,
    required this.requestsPerMinute,
    required this.requestBudgetPerMinute,
    required this.cacheHitRate,
    required this.cacheSizeBytes,
    required this.currentFileCachedPercent,
    required this.decodeLoadPercent,
    required this.timeToFirstByteMs,
    required this.bytesDownloaded,
    this.lastError,
    this.throughputHistory = const [],
    this.bufferHistory = const [],
  });

  final OutputTier tier;
  final AudioFormat requested;
  final AudioFormat actual;
  final String deviceName;
  final double bufferAheadSeconds;
  final double pcmFillPercent;
  final int underrunCount;
  final double speedMbps;
  final int activeRangeRequests;
  final int requestsPerMinute;
  final int requestBudgetPerMinute;
  final double cacheHitRate;
  final int cacheSizeBytes;
  final int currentFileCachedPercent;
  final double decodeLoadPercent;
  final int timeToFirstByteMs;
  final int bytesDownloaded;
  final String? lastError;

  /// Newest-last sparkline samples.
  final List<double> throughputHistory;
  final List<double> bufferHistory;
}

/// Mocked, low-rate visualizer payload for the Studio Now Playing style.
/// Fed at <=30 Hz; never drives a quality claim.
@immutable
class VisualizerFrame {
  const VisualizerFrame({
    required this.spectrum,
    required this.peakLeftDb,
    required this.peakRightDb,
    required this.clipping,
  });

  final List<double> spectrum;
  final double peakLeftDb;
  final double peakRightDb;
  final bool clipping;

  static const silent = VisualizerFrame(
    spectrum: [],
    peakLeftDb: -90,
    peakRightDb: -90,
    clipping: false,
  );
}

@immutable
class DeviceProfile {
  const DeviceProfile({
    required this.deviceId,
    required this.deviceName,
    this.eqPresetName,
    this.replayGain = ReplayGainMode.off,
    this.safetyAttenuationDb,
    this.preferredVolumeDb,
    this.autoApply = true,
  });

  final String deviceId;
  final String deviceName;
  final String? eqPresetName;
  final ReplayGainMode replayGain;
  final double? safetyAttenuationDb;
  final double? preferredVolumeDb;
  final bool autoApply;
}

@immutable
class SafetyCheckResult {
  const SafetyCheckResult({
    required this.deviceId,
    required this.hardwareVolumeWorks,
    required this.completedAt,
    this.attenuationDb,
  });

  final String deviceId;
  final bool hardwareVolumeWorks;
  final DateTime completedAt;
  final double? attenuationDb;
}

/// One page of a query result.
@immutable
class Paged<T> {
  const Paged({required this.items, required this.total, this.nextOffset});

  final List<T> items;
  final int total;
  final int? nextOffset;

  static Paged<T> empty<T>() => Paged<T>(items: const [], total: 0);
}

@immutable
class SearchResults {
  const SearchResults({
    this.topResult,
    this.tracks = const [],
    this.albums = const [],
    this.artists = const [],
    this.folders = const [],
  });

  /// Tracks, albums, artists or folders — whatever matched best.
  final Object? topResult;
  final List<Track> tracks;
  final List<Album> albums;
  final List<Artist> artists;
  final List<FolderEntry> folders;

  bool get isEmpty =>
      tracks.isEmpty && albums.isEmpty && artists.isEmpty && folders.isEmpty;
}

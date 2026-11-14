/// The output tier the engine actually negotiated.
///
/// The UI never computes this — it is reported by the core and rendered
/// verbatim. See `docs/UI_UX_DESIGN_BRIEF.md` §4.1.
enum OutputTier { bitPerfect, nativeRate, resampled, unknown }

/// Where volume is applied in the chain.
enum VolumeMode { dacHardware, softwareDithered, system }

/// Cloud availability of a track, album or queue item.
enum Availability {
  cloudOnly,
  partiallyCached,
  cached,
  pinned,
  downloading,
  unavailable,
  unsupported,
  missing,
}

/// Container/codec. Everything from [ape] down is not decodable by the engine
/// and must be shown greyed out rather than hidden (audit §2.8).
enum Codec { flac, alac, wav, aiff, mp3, aac, ape, wavpack, dsf, opus }

enum DeviceType { usb, bluetooth, phoneSpeaker, wiredAnalog, unknown }

/// Whether the device exposes a hardware volume control. [unknown] is a real,
/// common answer on USB-C dongles and must be rendered as such.
enum HardwareVolume { yes, no, unknown }

enum SyncPhase { idle, listing, tags, paused, error }

enum EqMode { simple, graphic, parametric }

enum BiquadType { peak, lowShelf, highShelf, lowPass, highPass }

enum RepeatMode { off, all, one }

enum BannerKind { info, warning, error, success }

enum NowPlayingStyle { classic, minimal, studio }

enum ReplayGainMode { off, track, album }

enum CrossfeedPreset { off, defaultBs2b, chuMoy, janMeier }

extension CrossfeedPresetInfo on CrossfeedPreset {
  /// Matches Rust `CROSSFEED_*` constants in `dsp.rs`.
  int get rustId => index;

  String get shortLabel => switch (this) {
        CrossfeedPreset.off => 'Off',
        CrossfeedPreset.defaultBs2b => 'Default',
        CrossfeedPreset.chuMoy => 'Chu Moy',
        CrossfeedPreset.janMeier => 'Jan Meier',
      };

  String get label => switch (this) {
        CrossfeedPreset.off => 'Off',
        CrossfeedPreset.defaultBs2b => 'Default (700 Hz / 4.5 dB)',
        CrossfeedPreset.chuMoy => 'Chu Moy (700 Hz / 6.0 dB)',
        CrossfeedPreset.janMeier => 'Jan Meier (650 Hz / 9.5 dB)',
      };
}

enum PlaybackErrorKind {
  network,
  unsupportedFormat,
  fileMissing,
  authExpired,
  decodeFailed,
  deviceLost,
}

enum MobileDataPolicy { stream, cachedOnly, ask }

enum PrefetchPolicy { wifiOnly, always, never }

enum NetworkTransportMode { unmeteredWifi, meteredCellular }

enum BufferProfile { fast, balanced, safe }

enum BadgeVisibility { always, hiResOnly, never }

extension CodecInfo on Codec {
  /// Display name used in badges and chips.
  String get label => switch (this) {
        Codec.flac => 'FLAC',
        Codec.alac => 'ALAC',
        Codec.wav => 'WAV',
        Codec.aiff => 'AIFF',
        Codec.mp3 => 'MP3',
        Codec.aac => 'AAC',
        Codec.ape => 'APE',
        Codec.wavpack => 'WavPack',
        Codec.dsf => 'DSF',
        Codec.opus => 'Opus',
      };

  /// True when the engine can decode this container.
  bool get isSupported => switch (this) {
        Codec.flac || Codec.alac || Codec.wav || Codec.aiff => true,
        Codec.mp3 || Codec.aac || Codec.dsf => true,
        Codec.ape || Codec.wavpack || Codec.opus => false,
      };

  /// True when the format preserves every sample.
  bool get isLossless => switch (this) {
        Codec.flac ||
        Codec.alac ||
        Codec.wav ||
        Codec.aiff ||
        Codec.dsf =>
          true,
        _ => false,
      };
}

extension OutputTierInfo on OutputTier {
  /// The exact, mandated label. Never paraphrase these strings.
  String get label => switch (this) {
        OutputTier.bitPerfect => 'Bit-perfect',
        OutputTier.nativeRate => 'Native rate',
        OutputTier.resampled => 'Resampled',
        OutputTier.unknown => 'Unknown',
      };
}

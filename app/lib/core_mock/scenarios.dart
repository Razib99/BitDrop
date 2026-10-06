import '../core_api/enums.dart';
import '../core_api/models.dart';
import 'catalog.dart';

/// One switchable state of the world. The scenario fixes the device, the
/// negotiated format, the network behaviour and the library's sync state, so
/// every screen can be driven into a specific condition from one place.
class Scenario {
  const Scenario({
    required this.id,
    required this.name,
    required this.summary,
    required this.device,
    required this.tier,
    required this.volumeMode,
    required this.explanation,
    this.platformLabel = 'Android 14',
    this.dspActive = false,
    this.dspChain = const [],
    this.actualOverride,
    this.offline = false,
    this.weakNetwork = false,
    this.hasSources = true,
    this.sourceStatus = SourceStatus.upToDate,
    this.syncPhase = SyncPhase.idle,
    this.syncProcessed = 0,
    this.syncTotal = 0,
    this.retryInSeconds,
    this.deviceDisconnects = false,
    this.startWithUnsupportedTrack = false,
    this.safetyAttenuationDb,
    this.hardwareVolumeFailed = false,
    this.storageNearlyFull = false,
  });

  final String id;
  final String name;
  final String summary;
  final OutputDevice? device;
  final OutputTier tier;
  final VolumeMode volumeMode;

  /// Plain-language reason for the tier. In production this comes from the
  /// Rust core; here the scenario supplies it so the UI still never writes it.
  final String explanation;
  final String platformLabel;
  final bool dspActive;
  final List<String> dspChain;

  /// When the system imposes a rate, this is what was really negotiated.
  final AudioFormat? actualOverride;
  final bool offline;
  final bool weakNetwork;
  final bool hasSources;
  final SourceStatus sourceStatus;
  final SyncPhase syncPhase;
  final int syncProcessed;
  final int syncTotal;
  final int? retryInSeconds;

  /// Fires a mid-playback disconnect shortly after the scenario loads.
  final bool deviceDisconnects;
  final bool startWithUnsupportedTrack;
  final double? safetyAttenuationDb;
  final bool hardwareVolumeFailed;
  final bool storageNearlyFull;

  /// Resolves the actual format for a given source format under this scenario.
  AudioFormat actualFor(AudioFormat source) {
    if (actualOverride != null) {
      return source.copyWith(
        sampleRate: actualOverride!.sampleRate,
        bitDepth: actualOverride!.bitDepth,
      );
    }
    return source;
  }
}

abstract final class Scenarios {
  static const bitPerfect = Scenario(
    id: 'bit-perfect',
    name: 'Bit-perfect',
    summary: 'Android 14 · FiiO KA17 · FLAC 24/96 · DAC hardware volume',
    device: MockCatalog.fiioKa17,
    tier: OutputTier.bitPerfect,
    volumeMode: VolumeMode.dacHardware,
    explanation:
        'Samples reach your DAC untouched at their native rate. Volume is '
        'handled by the DAC, so BitDrop applies no digital gain.',
  );

  static const nativeRate = Scenario(
    id: 'native-rate',
    name: 'Native rate',
    summary: 'Android 14 · generic DAC · no bit-perfect mixer',
    device: MockCatalog.genericDac,
    tier: OutputTier.nativeRate,
    volumeMode: VolumeMode.system,
    explanation:
        'No resampling happens, but this DAC does not support the bit-perfect '
        'mixer, so Android may still apply software volume and mix other sounds.',
  );

  static const resampled = Scenario(
    id: 'resampled',
    name: 'Resampled',
    summary: 'Galaxy S10+ (Android 12) · DUNU Titan X → 48 kHz',
    device: MockCatalog.titanX,
    tier: OutputTier.resampled,
    volumeMode: VolumeMode.system,
    platformLabel: 'Android 12',
    actualOverride: AudioFormat(
      codec: Codec.flac,
      bitDepth: 24,
      sampleRate: 48000,
    ),
    explanation:
        'Android 12 mixes all audio at 48 kHz before it reaches your DAC. '
        'Bit-perfect output needs Android 14 or later and a supported DAC.',
  );

  static const dspActive = Scenario(
    id: 'dsp-active',
    name: 'DSP active',
    summary: 'Bit-perfect device with AutoEQ on — labels must change',
    device: MockCatalog.fiioKa17,
    tier: OutputTier.nativeRate,
    volumeMode: VolumeMode.softwareDithered,
    dspActive: true,
    dspChain: ['EQ: Titan X AutoEQ (7 bands)', 'Preamp −6.2 dB'],
    explanation:
        'Your DAC supports bit-perfect, but the equaliser changes the samples, '
        'so the output is Native rate. Turn the EQ off to get bit-perfect.',
  );

  static const phoneSpeaker = Scenario(
    id: 'phone-speaker',
    name: 'Phone speaker',
    summary: 'No DAC attached · system mixer at 48 kHz',
    device: MockCatalog.phoneSpeaker,
    tier: OutputTier.resampled,
    volumeMode: VolumeMode.system,
    actualOverride: AudioFormat(
      codec: Codec.flac,
      bitDepth: 16,
      sampleRate: 48000,
    ),
    explanation:
        'The phone speaker runs at a fixed 48 kHz, 16-bit. Your audio is '
        'resampled to match it.',
  );

  static const bluetooth = Scenario(
    id: 'bluetooth',
    name: 'Bluetooth headphones',
    summary: 'Aria Buds Pro · AAC · lossless not possible',
    device: MockCatalog.btBuds,
    tier: OutputTier.resampled,
    volumeMode: VolumeMode.system,
    actualOverride: AudioFormat(
      codec: Codec.flac,
      bitDepth: 16,
      sampleRate: 48000,
    ),
    explanation:
        'Bluetooth uses its own codec, so lossless bit-perfect output is not '
        'possible on any phone. Your audio is re-encoded to AAC.',
  );

  static const weakNetwork = Scenario(
    id: 'weak-network',
    name: 'Weak network',
    summary: 'Repeated buffering with escalating targets',
    device: MockCatalog.titanX,
    tier: OutputTier.resampled,
    volumeMode: VolumeMode.system,
    platformLabel: 'Android 12',
    weakNetwork: true,
    actualOverride: AudioFormat(
      codec: Codec.flac,
      bitDepth: 24,
      sampleRate: 48000,
    ),
    explanation:
        'Android 12 mixes all audio at 48 kHz before it reaches your DAC.',
  );

  static const offline = Scenario(
    id: 'offline',
    name: 'Offline · partial cache',
    summary: 'No network · only cached and pinned tracks are playable',
    device: MockCatalog.titanX,
    tier: OutputTier.resampled,
    volumeMode: VolumeMode.system,
    platformLabel: 'Android 12',
    offline: true,
    sourceStatus: SourceStatus.offline,
    actualOverride: AudioFormat(
      codec: Codec.flac,
      bitDepth: 24,
      sampleRate: 48000,
    ),
    explanation:
        'Android 12 mixes all audio at 48 kHz before it reaches your DAC.',
  );

  static const dacUnplugged = Scenario(
    id: 'dac-unplugged',
    name: 'DAC unplugged mid-playback',
    summary: 'Playback pauses and the output falls back to the speaker',
    device: MockCatalog.titanX,
    tier: OutputTier.resampled,
    volumeMode: VolumeMode.system,
    platformLabel: 'Android 12',
    deviceDisconnects: true,
    explanation:
        'Android 12 mixes all audio at 48 kHz before it reaches your DAC.',
  );

  static const needsReconnect = Scenario(
    id: 'needs-reconnect',
    name: 'Source needs reconnection',
    summary: 'Google consent expired · cached playback still works',
    device: MockCatalog.titanX,
    tier: OutputTier.resampled,
    volumeMode: VolumeMode.system,
    platformLabel: 'Android 12',
    sourceStatus: SourceStatus.needsReconnect,
    explanation:
        'Android 12 mixes all audio at 48 kHz before it reaches your DAC.',
  );

  static const firstRun = Scenario(
    id: 'first-run',
    name: 'First run · no sources',
    summary: 'Nothing connected yet — onboarding and empty states',
    device: MockCatalog.phoneSpeaker,
    tier: OutputTier.resampled,
    volumeMode: VolumeMode.system,
    hasSources: false,
    explanation:
        'The phone speaker runs at a fixed 48 kHz, 16-bit.',
  );

  static const scanning = Scenario(
    id: 'scanning',
    name: 'Scanning',
    summary: 'Library partially enriched · tags filling in over Wi-Fi',
    device: MockCatalog.titanX,
    tier: OutputTier.resampled,
    volumeMode: VolumeMode.system,
    platformLabel: 'Android 12',
    sourceStatus: SourceStatus.syncing,
    syncPhase: SyncPhase.tags,
    syncProcessed: 8214,
    syncTotal: 12480,
    explanation:
        'Android 12 mixes all audio at 48 kHz before it reaches your DAC.',
  );

  static const rateLimited = Scenario(
    id: 'rate-limited',
    name: 'Rate limited',
    summary: 'Drive is limiting requests · scan paused with countdown',
    device: MockCatalog.titanX,
    tier: OutputTier.resampled,
    volumeMode: VolumeMode.system,
    platformLabel: 'Android 12',
    sourceStatus: SourceStatus.rateLimited,
    syncPhase: SyncPhase.paused,
    syncProcessed: 6120,
    syncTotal: 12480,
    retryInSeconds: 32,
    explanation:
        'Android 12 mixes all audio at 48 kHz before it reaches your DAC.',
  );

  static const unsupportedTrack = Scenario(
    id: 'unsupported-track',
    name: 'Unsupported track in queue',
    summary: 'Queue reaches an APE file and skips it with an explanation',
    device: MockCatalog.titanX,
    tier: OutputTier.resampled,
    volumeMode: VolumeMode.system,
    platformLabel: 'Android 12',
    startWithUnsupportedTrack: true,
    explanation:
        'Android 12 mixes all audio at 48 kHz before it reaches your DAC.',
  );

  static const noHardwareVolume = Scenario(
    id: 'no-hardware-volume',
    name: 'No hardware volume',
    summary: 'Safety check failed · −12 dB attenuation applied',
    device: MockCatalog.genericDac,
    tier: OutputTier.nativeRate,
    volumeMode: VolumeMode.softwareDithered,
    dspActive: true,
    dspChain: ['Safety attenuation −12.0 dB'],
    safetyAttenuationDb: -12.0,
    hardwareVolumeFailed: true,
    explanation:
        'This DAC reports no hardware volume control, so BitDrop applies a '
        '−12 dB safety attenuation. That digital gain means the output is '
        'Native rate, not bit-perfect.',
  );

  static const storageFull = Scenario(
    id: 'storage-full',
    name: 'Storage nearly full',
    summary: 'Pinning paused · 1.1 GB free',
    device: MockCatalog.titanX,
    tier: OutputTier.resampled,
    volumeMode: VolumeMode.system,
    platformLabel: 'Android 12',
    storageNearlyFull: true,
    actualOverride: AudioFormat(
      codec: Codec.flac,
      bitDepth: 24,
      sampleRate: 48000,
    ),
    explanation:
        'Android 12 mixes all audio at 48 kHz before it reaches your DAC.',
  );

  /// The iOS ceiling: native rate, never bit-perfect.
  static const iosNativeRate = Scenario(
    id: 'ios',
    name: 'iOS',
    summary: 'iPhone · native rate is the best tier iOS exposes',
    device: MockCatalog.genericDac,
    tier: OutputTier.nativeRate,
    volumeMode: VolumeMode.system,
    platformLabel: 'iOS 18',
    explanation:
        'iOS has no bit-perfect audio API. BitDrop asks for your track\'s '
        'native rate, but system volume and mixing still apply.',
  );

  /// Order matters — this is the order the switcher lists them in.
  static final List<Scenario> all = [
    bitPerfect,
    nativeRate,
    resampled,
    dspActive,
    phoneSpeaker,
    bluetooth,
    weakNetwork,
    offline,
    dacUnplugged,
    needsReconnect,
    firstRun,
    scanning,
    rateLimited,
    unsupportedTrack,
    noHardwareVolume,
    storageFull,
    iosNativeRate,
  ];

  static Scenario byId(String id) =>
      all.firstWhere((s) => s.id == id, orElse: () => resampled);

  /// The prototype opens on the owner's real hardware.
  static Scenario get initial => resampled;
}

import '../core_api/enums.dart';
import '../core_api/models.dart';

/// Fictional catalogue for the prototype.
///
/// Artists, albums and track titles are invented; artwork is a seeded gradient
/// painted by the UI, never a real cover. Sizes and bitrates are *computed*
/// from format and duration so every total in the UI adds up.
abstract final class MockCatalog {
  // Headline counters shown in Sources and Settings. The browsable catalogue
  // below is a representative slice of a library this size.
  static const libraryTrackCount = 10412;
  static const libraryAlbumCount = 812;
  static const libraryBytes = 1864135010713; // 1.86 TB

  /// Lossless compression ratios, used to derive a believable bitrate.
  static double _compression(Codec codec) => switch (codec) {
        Codec.flac => 0.60,
        Codec.alac => 0.62,
        Codec.wav || Codec.aiff => 1.0,
        Codec.ape => 0.55,
        Codec.wavpack => 0.58,
        _ => 1.0,
      };

  static AudioFormat _fmt(Codec codec, int bitDepth, int sampleRate) {
    final int kbps;
    switch (codec) {
      case Codec.mp3:
        kbps = 320;
      case Codec.aac:
        kbps = 256;
      case Codec.dsf:
        kbps = 5645; // DSD64: 2.8224 MHz x 1 bit x 2 ch
      case Codec.opus:
        kbps = 160;
      default:
        kbps =
            (sampleRate * bitDepth * 2 * _compression(codec) / 1000).round();
    }
    return AudioFormat(
      codec: codec,
      bitDepth: bitDepth,
      sampleRate: sampleRate,
      bitrateKbps: kbps,
    );
  }

  static int _sizeBytes(AudioFormat f, int durationMs) =>
      ((f.bitrateKbps ?? 1000) * 1000 ~/ 8) * durationMs ~/ 1000;

  static Artwork _art(int seed, int argb) =>
      Artwork(seed: seed, dominantColor: argb);

  // ---- Format shorthands ---------------------------------------------------

  static final flac2496 = _fmt(Codec.flac, 24, 96000);
  static final flac1644 = _fmt(Codec.flac, 16, 44100);
  static final flac24192 = _fmt(Codec.flac, 24, 192000);
  static final flac2488 = _fmt(Codec.flac, 24, 88200);
  static final alac2448 = _fmt(Codec.alac, 24, 48000);
  static final wav2496 = _fmt(Codec.wav, 24, 96000);
  static final mp3320 = _fmt(Codec.mp3, 16, 44100);
  static final ape1644 = _fmt(Codec.ape, 16, 44100);
  static final dsf64 = _fmt(Codec.dsf, 1, 2822400);

  // ---- Album definitions ---------------------------------------------------

  static final List<_AlbumSpec> _specs = [
    _AlbumSpec(
      id: 'al-northern',
      title: 'Northern Lights Sessions',
      artist: 'Aurora Fields',
      artistId: 'ar-aurora',
      year: 2023,
      genre: 'Ambient',
      format: flac2496,
      dominantColor: 0xFF2E5A7A,
      folder: 'Drive › Music › Hi-Res › Aurora Fields › Northern Lights Sessions',
      availability: Availability.cached,
      titles: [
        'First Light Over Kiruna',
        'Snowfield',
        'Aurora, Part I',
        'Aurora, Part II',
        'The Long Dark',
        'Hoarfrost',
        'Radio Silence from the Observatory at Abisko',
        'Midwinter',
        'Returning',
        'Last Light',
      ],
      durations: [412000, 268000, 356000, 301000, 489000, 224000, 537000, 198000, 332000, 445000],
    ),
    _AlbumSpec(
      id: 'al-quiet',
      title: 'Quiet Machines',
      artist: 'The Lowlands',
      artistId: 'ar-lowlands',
      year: 2019,
      genre: 'Indie Rock',
      format: flac1644,
      dominantColor: 0xFF6B4A3A,
      folder: 'Drive › Music › Lossless › The Lowlands › Quiet Machines',
      availability: Availability.pinned,
      titles: [
        'Gearbox',
        'Slow Turbine',
        'Copper Wire',
        'Quiet Machines',
        'Dust in the Bearings',
        'Night Shift',
        'Hydraulic',
        'Tin Roof',
        'Cooling Tower',
        'Shutdown',
      ],
      durations: [204000, 238000, 186000, 311000, 265000, 222000, 198000, 254000, 289000, 341000],
    ),
    _AlbumSpec(
      id: 'al-glass',
      title: 'Glass Harbor',
      artist: 'Mira Okafor',
      artistId: 'ar-mira',
      year: 2024,
      genre: 'Modern Classical',
      format: flac24192,
      dominantColor: 0xFF1F6F6B,
      folder: 'Drive › Music › Hi-Res › Mira Okafor › Glass Harbor',
      availability: Availability.partiallyCached,
      cachedPercent: 64,
      titles: [
        'Harbour Lights',
        'Tidewater',
        'Glass',
        'Breakwater',
        'Salt',
        'The Ferry at Dawn',
        'Undertow',
        'Low Water',
        'Harbour Lights (Reprise)',
        'Open Sea',
      ],
      durations: [347000, 412000, 278000, 522000, 189000, 456000, 298000, 367000, 143000, 601000],
    ),
    _AlbumSpec(
      id: 'al-midnight',
      title: 'Midnight Transit',
      artist: 'Kenji Sato Trio',
      artistId: 'ar-kenji',
      year: 2021,
      genre: 'Jazz',
      format: alac2448,
      dominantColor: 0xFF4A3B6B,
      folder: 'Drive › Music › Jazz › Kenji Sato Trio › Midnight Transit',
      availability: Availability.cloudOnly,
      titles: [
        'Last Train',
        'Platform 9',
        'Transit',
        'Blue Line',
        'Interchange',
        'Night Bus',
        'Terminus',
        'Walking Home',
        'Four in the Morning',
        'First Train',
      ],
      durations: [398000, 467000, 312000, 589000, 345000, 278000, 423000, 356000, 512000, 289000],
    ),
    _AlbumSpec(
      id: 'al-field',
      title: 'Field Recordings, Vol. 2',
      artist: 'Hollow Pines',
      artistId: 'ar-hollow',
      year: 2022,
      genre: 'Field Recording',
      format: wav2496,
      dominantColor: 0xFF3E5B2F,
      folder: 'Drive › Music › Hi-Res › Hollow Pines › Field Recordings Vol 2',
      availability: Availability.cloudOnly,
      titles: [
        'Rain on a Tin Roof, Three Hours Before Sunrise',
        'Cicadas',
        'River Crossing',
        'Wind in the Firebreak',
        'Hailstorm',
        'Marsh at Dusk',
        'Thunder, Distant',
        'Snowmelt',
        'Dawn Chorus',
        'Silence (Room Tone)',
      ],
      durations: [723000, 456000, 389000, 512000, 267000, 634000, 345000, 478000, 556000, 189000],
    ),
    _AlbumSpec(
      id: 'al-loworbit',
      title: 'Low Orbit',
      artist: 'Station Seven',
      artistId: 'ar-station',
      year: 2020,
      genre: 'Electronic',
      format: flac2488,
      dominantColor: 0xFF7A3B5C,
      folder: 'Drive › Music › Hi-Res › Station Seven › Low Orbit',
      availability: Availability.downloading,
      downloadProgress: 0.42,
      titles: [
        'Apogee',
        'Perigee',
        'Low Orbit',
        'Decaying Orbit',
        'Reentry',
        'Splashdown',
        'Telemetry',
        'Dark Side Pass',
        'Docking Sequence',
        'Return Vehicle',
      ],
      durations: [312000, 289000, 401000, 356000, 467000, 234000, 198000, 523000, 378000, 445000],
    ),
    _AlbumSpec(
      id: 'al-paper',
      title: 'Paper Lanterns',
      artist: 'Lumen Choir',
      artistId: 'ar-lumen',
      year: 2018,
      genre: 'Choral',
      format: flac1644,
      dominantColor: 0xFF8A6A2F,
      folder: 'Drive › Music › Lossless › Lumen Choir › Paper Lanterns',
      availability: Availability.cached,
      singleFileCue: true,
      titles: [
        'Procession',
        'Paper Lanterns I',
        'Paper Lanterns II',
        'Paper Lanterns III',
        'Vigil',
        'Evensong',
        'The River of Lights',
        'Benediction',
        'Recession',
        'Silence After',
      ],
      durations: [178000, 234000, 267000, 198000, 389000, 312000, 445000, 223000, 156000, 98000],
    ),
    _AlbumSpec(
      id: 'al-concrete',
      title: 'Concrete Bloom',
      artist: 'Vesna',
      artistId: 'ar-vesna',
      year: 2017,
      genre: 'Pop',
      format: mp3320,
      dominantColor: 0xFF8A3A3A,
      folder: 'Drive › Music › Lossy › Vesna › Concrete Bloom',
      availability: Availability.cached,
      titles: [
        'Concrete Bloom',
        'Rooftop',
        'Streetlight',
        'Overpass',
        'Weeds',
        'Chainlink',
        'Tarmac',
        'Siren Song',
        'Fire Escape',
        'Sunrise, Sixth Floor',
      ],
      durations: [198000, 212000, 187000, 234000, 201000, 178000, 223000, 245000, 189000, 267000],
    ),
    _AlbumSpec(
      id: 'al-archive',
      title: 'Archive Tapes',
      artist: 'Delta Echo',
      artistId: 'ar-delta',
      year: 2015,
      genre: 'Experimental',
      format: ape1644,
      dominantColor: 0xFF4A4A52,
      folder: 'Drive › Music › Archive › Delta Echo › Archive Tapes',
      availability: Availability.unsupported,
      unsupportedReason: 'APE — not supported yet',
      titles: [
        'Reel One',
        'Reel Two',
        'Reel Three',
        'Splice',
        'Leader Tape',
        'Reel Four',
        'Degauss',
        'Reel Five',
        'Oxide',
        'End of Tape',
      ],
      durations: [312000, 289000, 356000, 198000, 145000, 423000, 234000, 378000, 267000, 189000],
    ),
    _AlbumSpec(
      id: 'al-sunday',
      title: 'Sunday Pressure',
      artist: 'The Copper Line',
      artistId: 'ar-copper',
      year: 2016,
      genre: 'Blues',
      format: dsf64,
      dominantColor: 0xFF6B5A2F,
      folder: 'Drive › Music › DSD › The Copper Line › Sunday Pressure',
      availability: Availability.unsupported,
      unsupportedReason: 'DSF / DSD64 — not supported yet',
      titles: [
        'Sunday Pressure',
        'Barrelhouse',
        'Twelve Bars to Midnight',
        'Slide',
        'Copper Line',
        'Dust Bowl',
        'Freight',
        'Juke',
        'Last Call',
        'Walk Home Slow',
      ],
      durations: [267000, 312000, 423000, 198000, 356000, 289000, 234000, 378000, 445000, 301000],
    ),
  ];

  /// The compilation is built separately — its tracks deliberately mix formats
  /// so the gapless note and the queue's gap markers have something to report.
  static final _mixedSpec = _AlbumSpec(
    id: 'al-mixed',
    title: 'Mixed Signals',
    artist: 'Various Artists',
    artistId: 'ar-various',
    year: 2024,
    genre: 'Compilation',
    format: flac2496,
    dominantColor: 0xFF3A6B8A,
    folder: 'Drive › Music › Compilations › Mixed Signals',
    availability: Availability.partiallyCached,
    cachedPercent: 30,
    isCompilation: true,
    titles: [
      'Opening Statement',
      'Crosstalk',
      'Signal to Noise',
      'Interference',
      'Carrier Wave',
      'Static',
      'Modulation',
      'Bandwidth',
      'Clean Channel',
      'Sign Off',
    ],
    durations: [234000, 312000, 289000, 198000, 423000, 267000, 356000, 245000, 378000, 189000],
    trackArtists: [
      'Aurora Fields',
      'The Lowlands',
      'Mira Okafor',
      'Station Seven',
      'Vesna',
      'Kenji Sato Trio',
      'Hollow Pines',
      'Lumen Choir',
      'Aurora Fields',
      'Station Seven',
    ],
    // Alternating CD and Hi-Res — the source of the sample-rate changes.
    perTrackFormats: [
      0, 1, 0, 1, 0, 1, 0, 1, 0, 1,
    ],
  );

  // ---- Built catalogue -----------------------------------------------------

  static final List<Album> albums = _buildAlbums();
  static final List<Track> tracks = _buildTracks();

  static Map<String, List<Track>>? _byAlbumCache;
  static Map<String, List<Track>> get tracksByAlbum =>
      _byAlbumCache ??= {
        for (final a in albums)
          a.id: tracks.where((t) => t.albumId == a.id).toList(),
      };

  static Track? trackById(String id) =>
      tracks.cast<Track?>().firstWhere((t) => t!.id == id, orElse: () => null);

  static Album? albumById(String id) =>
      albums.cast<Album?>().firstWhere((a) => a!.id == id, orElse: () => null);

  static List<_AlbumSpec> get _allSpecs => [..._specs, _mixedSpec];

  static List<Track> _buildTracks() {
    final out = <Track>[];
    for (final spec in _allSpecs) {
      for (var i = 0; i < spec.titles.length; i++) {
        final fmt = spec.formatForTrack(i);
        final duration = spec.durations[i];
        // Availability varies inside an album so rows are not uniform.
        final avail = spec.availabilityForTrack(i);
        out.add(Track(
          id: '${spec.id}-t${i + 1}',
          title: spec.titles[i],
          artist: spec.trackArtists?[i] ?? spec.artist,
          albumTitle: spec.title,
          albumId: spec.id,
          durationMs: duration,
          format: fmt,
          availability: avail,
          sizeBytes: _sizeBytes(fmt, duration),
          artwork: _art(spec.id.hashCode, spec.dominantColor),
          trackNumber: i + 1,
          year: spec.year,
          genre: spec.genre,
          folderPath: spec.folder,
          cachedPercent: avail == Availability.partiallyCached
              ? 30 + (i * 7) % 60
              : (avail == Availability.cached || avail == Availability.pinned
                  ? 100
                  : 0),
          downloadProgress:
              avail == Availability.downloading ? spec.downloadProgress : null,
          hasLyrics: i.isEven && spec.format.codec != Codec.wav,
          favorite: i == 2 && spec.id == 'al-glass',
          unsupportedReason: avail == Availability.unsupported
              ? spec.unsupportedReason
              : null,
          replayGainDb: -6.4 + (i % 5) * 0.8,
        ));
      }
    }
    // One tombstoned track: removed from Drive since the last sync.
    final ghost = out.firstWhere((t) => t.id == 'al-midnight-t7');
    out[out.indexOf(ghost)] = ghost.copyWith(availability: Availability.missing);
    return out;
  }

  static List<Album> _buildAlbums() {
    final out = <Album>[];
    for (final spec in _allSpecs) {
      var totalMs = 0;
      var totalBytes = 0;
      final rates = <int>{};
      final depths = <int>{};
      for (var i = 0; i < spec.titles.length; i++) {
        final fmt = spec.formatForTrack(i);
        totalMs += spec.durations[i];
        totalBytes += _sizeBytes(fmt, spec.durations[i]);
        rates.add(fmt.sampleRate);
        depths.add(fmt.bitDepth);
      }
      final mixed = rates.length > 1 || depths.length > 1;
      out.add(Album(
        id: spec.id,
        title: spec.title,
        artist: spec.artist,
        artistId: spec.artistId,
        trackCount: spec.titles.length,
        durationMs: totalMs,
        sizeBytes: totalBytes,
        format: spec.format,
        availability: spec.availability,
        artwork: _art(spec.id.hashCode, spec.dominantColor),
        year: spec.year,
        genre: spec.genre,
        mixedFormats: mixed,
        formatVarianceNote: mixed ? spec.varianceNote() : null,
        folderPath: spec.folder,
        lastModified: DateTime(2026, 9, 12 - (out.length % 9)),
        downloadProgress: spec.downloadProgress,
        isCompilation: spec.isCompilation,
        playCount: (spec.id.hashCode.abs() % 40),
        addedAt: DateTime(2026, 9, 28 - out.length * 2),
        lastPlayedAt: DateTime(2026, 10, 4 - (out.length % 5)),
      ));
    }
    return out;
  }

  // ---- Artists -------------------------------------------------------------

  static final List<Artist> artists = () {
    final byId = <String, Artist>{};
    for (final a in albums) {
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
    return byId.values.toList()..sort((x, y) => x.name.compareTo(y.name));
  }();

  static final List<String> genreList = () {
    final g = albums.map((a) => a.genre).whereType<String>().toSet().toList();
    g.sort();
    return g;
  }();

  // ---- Playlists -----------------------------------------------------------

  static final List<Playlist> playlists = [
    Playlist(
      id: 'pl-latenight',
      name: 'Late Nights, Long Drives',
      trackCount: 24,
      durationMs: 7845000,
      sizeBytes: 2140000000,
      availability: Availability.partiallyCached,
      artwork: _art('pl-latenight'.hashCode, 0xFF2F4A6B),
      description: 'Built by hand over two winters.',
    ),
    Playlist(
      id: 'pl-reference',
      name: 'Reference Tracks',
      trackCount: 12,
      durationMs: 3420000,
      sizeBytes: 1480000000,
      availability: Availability.pinned,
      artwork: _art('pl-reference'.hashCode, 0xFF1F6F6B),
      description: 'For judging gear. Pinned so it always plays.',
    ),
    Playlist(
      id: 'pl-firstlight',
      name: 'First Light',
      trackCount: 18,
      durationMs: 5160000,
      sizeBytes: 1920000000,
      availability: Availability.cloudOnly,
      artwork: _art('pl-firstlight'.hashCode, 0xFF8A6A2F),
    ),
    Playlist(
      id: 'pl-smart-recent',
      name: 'Recently added',
      trackCount: 50,
      durationMs: 14400000,
      sizeBytes: 5600000000,
      availability: Availability.cloudOnly,
      artwork: _art('pl-smart-recent'.hashCode, 0xFF4A3B6B),
      isSmart: true,
    ),
    Playlist(
      id: 'pl-smart-hires',
      name: 'Hi-Res',
      trackCount: 142,
      durationMs: 41200000,
      sizeBytes: 18400000000,
      availability: Availability.cloudOnly,
      artwork: _art('pl-smart-hires'.hashCode, 0xFF34D399),
      isSmart: true,
    ),
    Playlist(
      id: 'pl-smart-most',
      name: 'Most played',
      trackCount: 40,
      durationMs: 11800000,
      sizeBytes: 4200000000,
      availability: Availability.cloudOnly,
      artwork: _art('pl-smart-most'.hashCode, 0xFF7A3B5C),
      isSmart: true,
    ),
  ];

  // ---- Devices and AutoEQ --------------------------------------------------

  static const titanX = OutputDevice(
    id: 'dev-titanx',
    name: 'DUNU Titan X',
    type: DeviceType.usb,
    supportedRates: [44100, 48000, 88200, 96000, 176400, 192000],
    bitDepths: [16, 24, 32],
    hardwareVolume: HardwareVolume.unknown,
    maxTier: OutputTier.resampled,
    connectionLabel: 'USB-C',
  );

  static const fiioKa17 = OutputDevice(
    id: 'dev-ka17',
    name: 'FiiO KA17',
    type: DeviceType.usb,
    supportedRates: [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000],
    bitDepths: [16, 24, 32],
    hardwareVolume: HardwareVolume.yes,
    maxTier: OutputTier.bitPerfect,
    connectionLabel: 'USB-C',
  );

  static const genericDac = OutputDevice(
    id: 'dev-generic',
    name: 'USB Audio DAC',
    type: DeviceType.usb,
    supportedRates: [44100, 48000, 96000],
    bitDepths: [16, 24],
    hardwareVolume: HardwareVolume.no,
    maxTier: OutputTier.nativeRate,
    connectionLabel: 'USB-C',
  );

  static const phoneSpeaker = OutputDevice(
    id: 'dev-speaker',
    name: 'Phone speaker',
    type: DeviceType.phoneSpeaker,
    supportedRates: [48000],
    bitDepths: [16],
    hardwareVolume: HardwareVolume.yes,
    maxTier: OutputTier.resampled,
  );

  static const btBuds = OutputDevice(
    id: 'dev-bt',
    name: 'Aria Buds Pro',
    type: DeviceType.bluetooth,
    supportedRates: [44100, 48000],
    bitDepths: [16],
    hardwareVolume: HardwareVolume.yes,
    maxTier: OutputTier.resampled,
    connectionLabel: 'Bluetooth · AAC',
  );

  static const knownDevices = [titanX, fiioKa17, btBuds];

  static const List<AutoEqProfile> autoEqProfiles = [
    AutoEqProfile(
      id: 'aeq-titanx',
      model: 'DUNU Titan X',
      measurementSource: 'oratory1990',
      target: 'Harman IE 2019',
      suggestedPreampDb: -6.2,
      bands: [
        EqBand(id: 1, type: BiquadType.lowShelf, frequencyHz: 105, gainDb: 3.4, q: 0.7),
        EqBand(id: 2, type: BiquadType.peak, frequencyHz: 212, gainDb: -1.8, q: 1.1),
        EqBand(id: 3, type: BiquadType.peak, frequencyHz: 1150, gainDb: 1.2, q: 1.4),
        EqBand(id: 4, type: BiquadType.peak, frequencyHz: 2900, gainDb: -2.6, q: 2.2),
        EqBand(id: 5, type: BiquadType.peak, frequencyHz: 5200, gainDb: 2.1, q: 2.8),
        EqBand(id: 6, type: BiquadType.peak, frequencyHz: 7800, gainDb: -3.2, q: 3.4),
        EqBand(id: 7, type: BiquadType.highShelf, frequencyHz: 10500, gainDb: 1.6, q: 0.7),
      ],
    ),
    AutoEqProfile(
      id: 'aeq-moondrop',
      model: 'Aster Labs Chroma 2',
      measurementSource: 'Crinacle IEC-711',
      target: 'Diffuse Field',
      suggestedPreampDb: -4.8,
      bands: [
        EqBand(id: 1, type: BiquadType.lowShelf, frequencyHz: 80, gainDb: 2.2, q: 0.7),
        EqBand(id: 2, type: BiquadType.peak, frequencyHz: 420, gainDb: -1.1, q: 1.0),
        EqBand(id: 3, type: BiquadType.peak, frequencyHz: 3400, gainDb: 3.8, q: 1.9),
        EqBand(id: 4, type: BiquadType.peak, frequencyHz: 6100, gainDb: -2.4, q: 3.1),
        EqBand(id: 5, type: BiquadType.highShelf, frequencyHz: 12000, gainDb: 0.9, q: 0.7),
      ],
    ),
  ];

  /// ISO 10-band centre frequencies for the graphic EQ.
  static const graphicBands = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];

  static final List<String> recentSearches = [
    '24/192',
    'glass harbor',
    'alac',
    'aurora',
    'hi-res',
  ];
}

/// Internal album blueprint. Keeps the catalogue declarative.
class _AlbumSpec {
  _AlbumSpec({
    required this.id,
    required this.title,
    required this.artist,
    required this.artistId,
    required this.year,
    required this.genre,
    required this.format,
    required this.dominantColor,
    required this.folder,
    required this.availability,
    required this.titles,
    required this.durations,
    this.cachedPercent = 0,
    this.downloadProgress,
    this.unsupportedReason,
    this.isCompilation = false,
    this.singleFileCue = false,
    this.trackArtists,
    this.perTrackFormats,
  });

  final String id;
  final String title;
  final String artist;
  final String artistId;
  final int year;
  final String genre;
  final AudioFormat format;
  final int dominantColor;
  final String folder;
  final Availability availability;
  final List<String> titles;
  final List<int> durations;
  final int cachedPercent;
  final double? downloadProgress;
  final String? unsupportedReason;
  final bool isCompilation;
  final bool singleFileCue;
  final List<String>? trackArtists;

  /// 0 = album format, 1 = the CD-quality alternate. Drives mixed-format albums.
  final List<int>? perTrackFormats;

  AudioFormat formatForTrack(int i) {
    if (perTrackFormats == null) return format;
    return perTrackFormats![i] == 0 ? format : MockCatalog.flac1644;
  }

  /// Spread availability across an album so no list looks synthetic.
  Availability availabilityForTrack(int i) {
    switch (availability) {
      case Availability.unsupported:
      case Availability.pinned:
      case Availability.downloading:
        return availability;
      case Availability.cached:
        return i >= titles.length - 2 ? Availability.cloudOnly : Availability.cached;
      case Availability.partiallyCached:
        if (i < 3) return Availability.cached;
        if (i < 5) return Availability.partiallyCached;
        return Availability.cloudOnly;
      default:
        return Availability.cloudOnly;
    }
  }

  /// Plain-language gapless note. In the real app this string comes from the
  /// core; here the catalogue derives it once so the UI never composes it.
  String varianceNote() {
    for (var i = 1; i < titles.length; i++) {
      final a = formatForTrack(i - 1);
      final b = formatForTrack(i);
      if (a.sampleRate != b.sampleRate) {
        return 'Tracks $i–${i + 1} change sample rate; a brief gap may occur.';
      }
    }
    return 'Formats vary within this album; brief gaps may occur.';
  }
}

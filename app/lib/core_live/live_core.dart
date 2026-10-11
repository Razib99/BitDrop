import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:audio_service/audio_service.dart' as audio_svc;
import 'package:rxdart/rxdart.dart';
import '../core_api/bitdrop_core.dart';
import '../core_api/commands.dart';
import '../core_api/enums.dart';
import '../core_api/models.dart';
import '../core_api/queries.dart';
import '../core_api/settings.dart';
import '../core_mock/catalog.dart';
import '../core_mock/mock_core.dart';
import 'audio_handler.dart';
import 'cloud_library.dart';
import 'output_device.dart';
import '../src/rust/api/audio_engine.dart' as rust;
import '../src/rust/api/simple.dart' as rust_simple;

class LiveBitDropCore implements BitDropCore {
  final BitDropAudioHandler _audioHandler;
  final MockBitDropCore _mockCore;

  /// Null until Drive is connected. Everything cloud-related is served from
  /// here; local scanning and the mock catalogue are untouched by it.
  final CloudLibrary? _cloud;

  final Map<String, Track> _realTracks = {};

  /// When the current stall began, for escalating the buffering copy.
  DateTime? _bufferingSince;

  final _outputProbe = OutputDeviceProbe();
  final _signalPath = BehaviorSubject<SignalPath>.seeded(_unknownPath);

  static const _unknownPath = SignalPath(
    tier: OutputTier.unknown,
    source: AudioFormat(codec: Codec.flac, bitDepth: 0, sampleRate: 0),
    requested: AudioFormat(codec: Codec.flac, bitDepth: 0, sampleRate: 0),
    actual: AudioFormat(codec: Codec.flac, bitDepth: 0, sampleRate: 0),
    dspActive: false,
    volume: VolumeMode.system,
    explanation: 'Nothing is playing yet, so there is no output path to report.',
  );

  /// What the engine builds up before it resumes after a stall.
  static const _bufferTargetMs = 2000;
  Album? _realAlbum;

  LiveBitDropCore(this._audioHandler, {CloudLibrary? cloudLibrary})
      : _cloud = cloudLibrary,
        _mockCore = MockBitDropCore() {
    rust.initEngine();

    // The cloud library drives the scan banner on Home and Sources.
    _cloud?.status.listen(_syncStatus.add);
    _cloud?.open();

    _outputProbe.start();
    _outputProbe.stream.listen((_) => _recomputeSignalPath());
    _mockCore.eq.listen((_) => _recomputeSignalPath());

    _audioHandler.playbackState.listen((state) {
      _recomputeSignalPath();
      final isPlaying = state.playing;
      final buffering =
          state.processingState == audio_svc.AudioProcessingState.buffering;

      final aheadMs = (state.bufferedPosition - state.updatePosition)
          .inMilliseconds
          .clamp(0, 600000);

      // Buffering is not pausing: the user did not stop this, the network
      // did. The wording escalates with the length of the stall so a brief
      // hiccup and a failing connection do not read the same.
      if (buffering) {
        _bufferingSince ??= DateTime.now();
        final stalled = DateTime.now().difference(_bufferingSince!);
        _playback.add(BufferingState(
          bufferedMs: aheadMs,
          targetMs: _bufferTargetMs,
          attempt: stalled.inSeconds >= 4 ? 2 : 1,
        ));
      } else {
        _bufferingSince = null;
        _playback.add(isPlaying ? const PlayingState() : const PausedState());
      }

      _position.add(PositionInfo(
        positionMs: state.updatePosition.inMilliseconds,
        durationMs: _audioHandler.mediaItem.value?.duration?.inMilliseconds ?? 0,
        bufferAheadMs: aheadMs,
        // Which parts are already on disk. Non-contiguous after a seek,
        // which is exactly what the bar is meant to show.
        cachedRanges: _cachedRanges(),
      ));
    });
    
    _audioHandler.queue.listen((items) {
      if (items.isEmpty) return;
      final currentItem = _audioHandler.mediaItem.value;
      final currentIndex = currentItem == null ? 0 : items.indexOf(currentItem);
      final tracks = items.map((i) => _lookupTrack(i.id)).whereType<Track>().toList();
      final queueItems = tracks.map((t) => QueueItem(track: t, id: t.id)).toList();
      _queue.add(QueueState(items: queueItems, currentIndex: currentIndex < 0 ? 0 : currentIndex, shuffle: false, repeat: RepeatMode.off));
    });
    
    _audioHandler.mediaItem.listen((item) {
      if (item != null) {
        final track = _lookupTrack(item.id);
        if (track != null) {
          _nowPlaying.add(NowPlaying(
            track: track,
            contextLabel: track.folderPath.isNotEmpty
                ? track.folderPath
                : 'Local Music',
          ));
          
          // Update queue index
          final q = _queue.value;
          final idx = q.items.indexWhere((i) => i.id == item.id);
          if (idx >= 0) {
            _queue.add(QueueState(items: q.items, currentIndex: idx, shuffle: q.shuffle, repeat: q.repeat));
          }
        }
      }
    });

    _mockCore.eq.listen((eqState) {
      List<double> finalGains;
      if (eqState.mode == EqMode.simple) {
        finalGains = List.filled(10, 0.0);
        finalGains[0] = eqState.bassDb;
        finalGains[1] = eqState.bassDb * 0.8;
        finalGains[2] = eqState.bassDb * 0.4;
        finalGains[7] = eqState.trebleDb * 0.4;
        finalGains[8] = eqState.trebleDb * 0.8;
        finalGains[9] = eqState.trebleDb;
      } else if (eqState.graphicGains.isNotEmpty) {
        finalGains = eqState.graphicGains.take(10).toList();
      } else {
        finalGains = List.filled(10, 0.0);
      }
      // Pass the preamp as the 11th element of the gains list!
      finalGains.add(eqState.preampDb);
      
      rust.engineSetEq(gains: finalGains);
      rust.engineSetEqEnabled(enabled: !eqState.bypass);
    });

    _scanRealMusic();
  }
  
  Future<void> _scanRealMusic() async {
    try {
      final metas = rust_simple.scanDirectory(path: '/home/razib/Desktop/BitDrop/Music');
      if (metas.isEmpty) return;
      
      int duration = 0;
      int size = 0;
      
      for (final m in metas) {
        final t = Track(
          id: m.path,
          title: m.title.isNotEmpty ? m.title : m.path.split('/').last,
          artist: m.artist.isNotEmpty ? m.artist : 'Unknown Artist',
          albumTitle: m.album,
          albumId: 'real-music',
          durationMs: m.durationMs,
          sizeBytes: 50000000,
          format: AudioFormat(codec: Codec.flac, bitDepth: 16, sampleRate: m.sampleRate),
          availability: Availability.cached,
          artwork: Artwork(seed: 42, dominantColor: 0xFF4A90E2, uri: m.path),
          trackNumber: 1,
        );
        _realTracks[t.id] = t;
        duration += m.durationMs;
      }
      
      _realAlbum = Album(
        id: 'real-music',
        title: 'Real Music Folder',
        artist: 'Various Artists',
        artistId: 'various',
        trackCount: _realTracks.length,
        durationMs: duration,
        sizeBytes: size,
        format: const AudioFormat(codec: Codec.flac, bitDepth: 16, sampleRate: 44100),
        availability: Availability.cached,
          artwork: Artwork(seed: 42, dominantColor: 0xFF4A90E2, uri: _realTracks.values.firstOrNull?.id),
        mixedFormats: true,
      );
    } catch (e) {
      debugPrint('[library] local scan failed: $e');
    }
  }


  // Intercepted streams
  final _playback = BehaviorSubject<PlaybackState>.seeded(const IdleState());
  @override Stream<PlaybackState> get playback => _playback.stream;

  final _position = BehaviorSubject<PositionInfo>.seeded(PositionInfo.empty);
  @override Stream<PositionInfo> get position => _position.stream;

  final _nowPlaying = BehaviorSubject<NowPlaying?>.seeded(null);
  @override Stream<NowPlaying?> get nowPlaying => _nowPlaying.stream;

  // Delegated streams
  @override Stream<SignalPath> get signalPath => _signalPath.stream;
  final _queue = BehaviorSubject<QueueState>.seeded(QueueState.empty);
  @override Stream<QueueState> get queue => _queue.stream;
  @override Stream<OutputDevice?> get outputDevice => _outputProbe.stream;
  @override
  Stream<List<SourceAccount>> get sources =>
      _cloud?.sourceAccounts ?? _mockCore.sources;
  final _syncStatus = BehaviorSubject<SyncStatus>.seeded(SyncStatus.idle);
  @override Stream<SyncStatus> get syncStatus => _syncStatus.stream;
  @override Stream<List<AppBanner>> get banners => _mockCore.banners;
  @override Stream<EqState> get eq => _mockCore.eq;
  @override Stream<StorageState> get storage => _mockCore.storage;
  @override Stream<DiagnosticsSnapshot> get diagnostics => _mockCore.diagnostics;
  @override Stream<VisualizerFrame> get visualizer => _mockCore.visualizer;
  @override Stream<List<DeviceProfile>> get deviceProfiles => _mockCore.deviceProfiles;
  @override Stream<AppSettings> get settings => _mockCore.settings;

  // Delegated queries
  
  /// Resolves an id across every source: cloud first, then the local scan,
  /// then the mock catalogue.
  Track? _lookupTrack(String id) =>
      _cloud?.trackById(id) ?? _realTracks[id] ?? MockCatalog.trackById(id);

  List<Album> get _cloudAlbums => _cloud?.currentAlbums ?? const [];
  List<Track> get _cloudTracks => _cloud?.currentTracks ?? const [];

  @override
  Future<Paged<Album>> albums(AlbumQuery q) async {
    final items = <Album>[
      ..._cloudAlbums,
      if (_realAlbum != null) _realAlbum!,
    ];
    return Paged(items: items, total: items.length);
  }

  @override
  Future<Paged<Track>> tracks(TrackQuery q) async {
    if (q.albumId != null) {
      final cloud =
          _cloudTracks.where((t) => t.albumId == q.albumId).toList();
      if (cloud.isNotEmpty) return Paged(items: cloud, total: cloud.length);
      if (q.albumId == 'real-music') {
        return Paged(items: _realTracks.values.toList(), total: _realTracks.length);
      }
      return const Paged(items: [], total: 0);
    }

    final items = <Track>[..._cloudTracks, ..._realTracks.values];
    return Paged(items: items, total: items.length);
  }

  @override
  Future<Album?> album(String id) async {
    for (final a in _cloudAlbums) {
      if (a.id == id) return a;
    }
    if (id == 'real-music') return _realAlbum;
    return _mockCore.album(id);
  }

  @override
  Future<Paged<Artist>> artists(ArtistQuery q) async {
    // Artists are derived from whatever albums exist rather than stored, so a
    // rescan cannot leave a stale artist behind.
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

  @override
  Future<Artist?> artist(String id) async {
    final all = await artists(const ArtistQuery());
    for (final a in all.items) {
      if (a.id == id) return a;
    }
    return _mockCore.artist(id);
  }
  @override Future<FolderListing> folder(String? folderId) async => const FolderListing(folderId: null, breadcrumb: [], entries: []);
  @override Future<List<Playlist>> playlists() async => const [];
  @override Future<List<String>> genres() async => const [];
  @override
  Future<SearchResults> search(String text, SearchFilters f) async {
    final q = text.trim().toLowerCase();
    if (q.isEmpty) return const SearchResults();

    final tracks = _cloudTracks
        .where((t) =>
            t.title.toLowerCase().contains(q) ||
            t.artist.toLowerCase().contains(q) ||
            t.albumTitle.toLowerCase().contains(q) ||
            t.format.badgeLabel.toLowerCase() == q)
        .take(20)
        .toList();
    final albums = _cloudAlbums
        .where((a) =>
            a.title.toLowerCase().contains(q) ||
            a.artist.toLowerCase().contains(q))
        .take(12)
        .toList();

    return SearchResults(
      topResult: albums.isNotEmpty
          ? albums.first
          : (tracks.isNotEmpty ? tracks.first : null),
      tracks: tracks,
      albums: albums,
      artists: const [],
      folders: const [],
    );
  }
  @override Future<List<AutoEqProfile>> searchAutoEq(String model) => _mockCore.searchAutoEq(model);
  @override Future<List<String>> recentSearches() => _mockCore.recentSearches();

  // Intercepted commands
  @override
  Future<void> send(PlayerCommand cmd) async {
    if (cmd is PlayContext) {
      // Must go through _lookupTrack: resolving against local and mock only
      // meant every cloud track came back empty and the tap did nothing.
      final tracks =
          cmd.trackIds.map(_lookupTrack).whereType<Track>().toList();
      debugPrint('[play] PlayContext ${cmd.contextId}: '
          '${cmd.trackIds.length} ids -> ${tracks.length} resolved, '
          'startIndex ${cmd.startIndex}');
      if (tracks.isEmpty) {
        debugPrint('[play] nothing resolved; first id was '
            '${cmd.trackIds.isEmpty ? '(none)' : cmd.trackIds.first}');
      }
      if (tracks.isNotEmpty) {
        final items = tracks.map((t) {
          // A cloud track is identified by its Drive file id, so the engine is
          // told where to stream it from; a local track's id is its path.
          final isCloud = _cloud?.trackById(t.id) != null;
          return audio_svc.MediaItem(
            id: t.id,
            title: t.title,
            album: t.albumTitle,
            artist: t.artist,
            duration: Duration(milliseconds: t.durationMs),
            extras: isCloud
                ? cloudTrackExtras(
                    fileId: t.id,
                    url: 'https://www.googleapis.com/drive/v3/files/${t.id}?alt=media',
                    sizeBytes: t.sizeBytes,
                    ext: t.format.codec.label.toLowerCase(),
                  )
                : null,
          );
        }).toList();
        
        if (cmd.shuffle) {
          items.shuffle();
        }
        
        await _audioHandler.setQueueAndPlay(items, cmd.startIndex);
      }
    } else if (cmd is Pause) {
      await _audioHandler.pause();
    } else if (cmd is Resume) {
      await _audioHandler.play();
    } else if (cmd is Seek) {
      await _audioHandler.seek(Duration(milliseconds: cmd.positionMs));
    } else {
      await _mockCore.send(cmd);
    }
  }

  /// Builds the signal path from measured facts only.
  ///
  /// The source format comes from the decoder, the output rate from the
  /// stream the device actually granted, and the device from AudioManager.
  /// Nothing here is inferred from a file name or assumed from a scenario.
  void _recomputeSignalPath() {
    final out = rust.engineOutputState();
    if (!out.hasTrack || out.sourceSampleRate == 0) {
      _signalPath.add(_unknownPath);
      return;
    }

    final device = _outputProbe.current;
    final codec = _codecFromName(out.sourceCodec);

    final source = AudioFormat(
      codec: codec,
      bitDepth: out.sourceBits == 0 ? 16 : out.sourceBits,
      sampleRate: out.sourceSampleRate,
      channels: out.sourceChannels == 0 ? 2 : out.sourceChannels,
    );

    // What actually leaves the engine: the stream's rate, not the file's.
    final actual = source.copyWith(
      sampleRate:
          out.outputSampleRate == 0 ? out.sourceSampleRate : out.outputSampleRate,
    );

    final resampled = actual.sampleRate != source.sampleRate;
    final dsp = out.dspActive;

    // Order matters. A rate change is the more severe truth, so it outranks
    // DSP; DSP in turn rules out bit-perfect. The device ceiling caps the
    // rest, and on Android 12 that ceiling is never bit-perfect.
    final ceiling = device?.maxTier ?? OutputTier.unknown;
    final OutputTier tier;
    if (resampled) {
      tier = OutputTier.resampled;
    } else if (dsp) {
      tier = OutputTier.nativeRate;
    } else if (ceiling == OutputTier.resampled) {
      tier = OutputTier.resampled;
    } else {
      tier = ceiling;
    }

    final dspChain = <String>[];
    if (dsp) dspChain.add('Equaliser');

    _signalPath.add(SignalPath(
      tier: tier,
      source: source,
      requested: source,
      actual: actual,
      dspActive: dsp,
      dspChain: dspChain,
      volume: dsp ? VolumeMode.softwareDithered : VolumeMode.system,
      device: device,
      sourceLabel: _cloud?.trackById(_currentTrackId) != null
          ? 'Google Drive'
          : 'This device',
      decoderLabel: '${source.codec.label} -> '
          '${source.bitDepth}-bit integer PCM',
      explanation: _explain(tier, source, actual, dsp, device),
    ));
  }

  String get _currentTrackId => _nowPlaying.value?.track.id ?? '';

  /// Cached spans of the current track, read straight from the chunk cache.
  ///
  /// Recomputed per tick rather than cached: a chunk can land at any moment
  /// and a stale answer would tell the user a seek is instant when it is not.
  List<CachedRange> _cachedRanges() {
    try {
      return rust
          .engineCachedRanges()
          .map((r) => CachedRange(r.startMs, r.endMs))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Codec _codecFromName(String name) => switch (name.toUpperCase()) {
        'FLAC' => Codec.flac,
        'ALAC' => Codec.alac,
        'PCM' || 'WAV' => Codec.wav,
        'AIFF' => Codec.aiff,
        'MP3' => Codec.mp3,
        'AAC' => Codec.aac,
        'VORBIS' || 'OPUS' => Codec.opus,
        _ => Codec.flac,
      };

  /// Plain language, and specific about the actual cause.
  static String _explain(
    OutputTier tier,
    AudioFormat source,
    AudioFormat actual,
    bool dsp,
    OutputDevice? device,
  ) {
    if (tier == OutputTier.resampled && actual.sampleRate != source.sampleRate) {
      return 'This phone mixes all audio at '
          '${actual.sampleRate ~/ 1000} kHz, so your '
          '${source.sampleRate ~/ 1000} kHz file is resampled before it '
          'reaches the output. Bit-perfect needs Android 14 or later and a '
          'DAC that supports it.';
    }
    if (device?.type == DeviceType.bluetooth) {
      return 'Bluetooth re-encodes audio with its own codec, so lossless '
          'playback is not possible over it on any phone.';
    }
    if (dsp) {
      return 'The equaliser is changing the samples, so this is no longer an '
          'untouched signal. Turn it off to get the closest path available.';
    }
    if (tier == OutputTier.nativeRate) {
      return 'No resampling is happening: the output runs at the file\'s own '
          'rate. Android may still apply system volume and mix other sounds.';
    }
    return 'The output path could not be determined.';
  }

  @override
  void dispose() {
    _playback.close();
    _position.close();
    _nowPlaying.close();
    _syncStatus.close();
    _queue.close();
    _cloud?.dispose();
    _outputProbe.dispose();
    _signalPath.close();
    _mockCore.dispose();
  }
}

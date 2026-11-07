import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:bitdrop/core_api/commands.dart';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_live/audio_handler.dart';
import 'package:bitdrop/core_live/cloud_library.dart';
import 'package:bitdrop/core_live/live_core.dart';
import 'package:bitdrop/core_live/playback_engine.dart';
import 'package:bitdrop/core_mock/catalog.dart';
import 'package:bitdrop/src/rust/api/audio_engine.dart' as rust;
import 'package:flutter_test/flutter_test.dart';

class MockRecordingEngine extends PlaybackEngine {
  final controller = StreamController<rust.EngineEvent>.broadcast(sync: true);
  final playedLocal = <String>[];
  final playedCloud = <String>[];
  String? stagedLocal;
  String? stagedCloud;
  int stops = 0;

  @override
  Stream<rust.EngineEvent> events() => controller.stream;

  @override
  int get position => 0;

  @override
  bool get isPlaying => false;

  @override
  rust.EngineBufferState get buffer => rust.EngineBufferState(
        buffering: false,
        bufferedMs: 0,
        fetchesInFlight: 0,
        bytesFetched: BigInt.zero,
        streamOpens: 0,
      );

  @override
  void play(String path) {
    playedLocal.add(path);
  }

  @override
  void stage(String path) {
    stagedLocal = path;
  }

  @override
  void clearNext() {
    stagedLocal = null;
    stagedCloud = null;
  }

  @override
  void resume() {}

  @override
  void pause() {}

  @override
  void seek(int milliseconds) {}

  @override
  void stop() {
    stops++;
  }

  @override
  void supplyToken(BigInt requestId, String? token) {}

  @override
  void playCloud({
    required String fileId,
    required String url,
    required String authToken,
    required BigInt totalSize,
    required String cacheDir,
    required String ext,
  }) {
    playedCloud.add(fileId);
  }

  @override
  void stageCloud({
    required String fileId,
    required String url,
    required String authToken,
    required BigInt totalSize,
    required String cacheDir,
    required String ext,
  }) {
    stagedCloud = fileId;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Metadata Extras & Codec Helpers', () {
    test('localTrackExtras produces expected dictionary structure', () {
      final extras = localTrackExtras(
        path: '/storage/emulated/0/Music/song.flac',
        sizeBytes: 1048576,
        ext: 'flac',
      );

      expect(extras['source'], 'local');
      expect(extras['fileId'], '/storage/emulated/0/Music/song.flac');
      expect(extras['path'], '/storage/emulated/0/Music/song.flac');
      expect(extras['sizeBytes'], 1048576);
      expect(extras['ext'], 'flac');
    });

    test('cloudTrackExtras produces expected dictionary structure', () {
      final extras = cloudTrackExtras(
        fileId: 'gdrive_abc123',
        url: 'https://www.googleapis.com/drive/v3/files/gdrive_abc123?alt=media',
        sizeBytes: 2097152,
        ext: 'flac',
      );

      expect(extras['source'], 'cloud');
      expect(extras['fileId'], 'gdrive_abc123');
      expect(extras['url'], contains('gdrive_abc123'));
      expect(extras['sizeBytes'], 2097152);
      expect(extras['ext'], 'flac');
    });

    test('CloudLibrary.codecFor maps file extensions to correct Codec enum', () {
      expect(CloudLibrary.codecFor('song.flac'), Codec.flac);
      expect(CloudLibrary.codecFor('track.wav'), Codec.wav);
      expect(CloudLibrary.codecFor('audio.mp3'), Codec.mp3);
      expect(CloudLibrary.codecFor('song.m4a'), Codec.alac);
      expect(CloudLibrary.codecFor('song.aac'), Codec.aac);
      expect(CloudLibrary.codecFor('song.ogg'), Codec.opus);
      expect(CloudLibrary.codecFor('track.dsf'), Codec.dsf);
      expect(CloudLibrary.codecFor('track.dff'), Codec.dsf);
      expect(CloudLibrary.codecFor('unknown.xyz'), Codec.flac);
    });
  });

  group('BitDropAudioHandler Seamless Mixed Queue Transitions', () {
    late MockRecordingEngine engine;
    late BitDropAudioHandler handler;

    final localItem1 = MediaItem(
      id: '/music/local1.flac',
      title: 'Local Track 1',
      extras: localTrackExtras(
        path: '/music/local1.flac',
        sizeBytes: 1000,
        ext: 'flac',
      ),
    );

    final localItem2 = MediaItem(
      id: '/music/local2.wav',
      title: 'Local Track 2',
      extras: localTrackExtras(
        path: '/music/local2.wav',
        sizeBytes: 2000,
        ext: 'wav',
      ),
    );

    final cloudItem1 = MediaItem(
      id: 'cloud_111',
      title: 'Cloud Track 1',
      extras: cloudTrackExtras(
        fileId: 'cloud_111',
        url: 'https://example.com/cloud1',
        sizeBytes: 3000,
        ext: 'flac',
      ),
    );

    final cloudItem2 = MediaItem(
      id: 'cloud_222',
      title: 'Cloud Track 2',
      extras: cloudTrackExtras(
        fileId: 'cloud_222',
        url: 'https://example.com/cloud2',
        sizeBytes: 4000,
        ext: 'flac',
      ),
    );

    setUp(() {
      engine = MockRecordingEngine();
      handler = BitDropAudioHandler(engine: engine);
      handler.cacheDir = '/tmp/bitdrop_test_cache';
      handler.accessTokenProvider = () async => 'test_access_token';
    });

    tearDown(() async {
      await handler.dispose();
      await engine.controller.close();
    });

    test('Local -> Local: plays local, stages local next', () async {
      await handler.setQueueAndPlay([localItem1, localItem2], 0);

      expect(engine.playedLocal, ['/music/local1.flac']);
      expect(engine.stagedLocal, '/music/local2.wav');
      expect(engine.stagedCloud, isNull);
    });

    test('Local -> Cloud: plays local, stages cloud next with credentials',
        () async {
      await handler.setQueueAndPlay([localItem1, cloudItem1], 0);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(engine.playedLocal, ['/music/local1.flac']);
      expect(engine.stagedCloud, 'cloud_111');
      expect(engine.stagedLocal, isNull);
    });

    test('Cloud -> Local: plays cloud, stages local next', () async {
      await handler.setQueueAndPlay([cloudItem1, localItem1], 0);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(engine.playedCloud, ['cloud_111']);
      expect(engine.stagedLocal, '/music/local1.flac');
      expect(engine.stagedCloud, isNull);
    });

    test('Cloud -> Cloud: plays cloud, stages cloud next', () async {
      await handler.setQueueAndPlay([cloudItem1, cloudItem2], 0);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(engine.playedCloud, ['cloud_111']);
      expect(engine.stagedCloud, 'cloud_222');
      expect(engine.stagedLocal, isNull);
    });

    test('Engine TrackStarted event advances index and stages successor',
        () async {
      await handler.setQueueAndPlay([localItem1, localItem2, cloudItem1], 0);

      expect(handler.currentIndex, 0);
      expect(engine.stagedLocal, '/music/local2.wav');

      // Rust engine emits TrackStarted for track 2 (by path)
      engine.controller.add(
        const rust.EngineEvent.trackStarted(fileId: '/music/local2.wav'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(handler.currentIndex, 1);
      expect(handler.mediaItem.value?.id, '/music/local2.wav');
      // Successor of track 2 is cloudItem1:
      expect(engine.stagedCloud, 'cloud_111');
    });

    test('Engine TrackEnded event automatically skips to next track', () async {
      await handler.setQueueAndPlay([localItem1, cloudItem1], 0);
      expect(handler.currentIndex, 0);

      // Rust engine emits TrackEnded for localItem1 (by path)
      engine.controller.add(
        const rust.EngineEvent.trackEnded(fileId: '/music/local1.flac'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(handler.currentIndex, 1);
      expect(engine.playedCloud, ['cloud_111']);
      expect(handler.mediaItem.value?.id, 'cloud_111');
    });
  });

  group('LiveBitDropCore Directory & Mixed Queue Resolution', () {
    late MockRecordingEngine engine;
    late BitDropAudioHandler handler;
    late Directory tempDir;

    setUp(() {
      engine = MockRecordingEngine();
      handler = BitDropAudioHandler(engine: engine);
      tempDir = Directory.systemTemp.createTempSync('bitdrop_test_music_');
    });

    tearDown(() async {
      await handler.dispose();
      await engine.controller.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('PlayContext with local audio files on disk resolves and plays',
        () async {
      // Create sample audio dummy files in nested folders
      final rockDir = Directory('${tempDir.path}/Rock')..createSync();
      final song1 = File('${rockDir.path}/track1.flac')..writeAsBytesSync([0, 1, 2]);
      final song2 = File('${rockDir.path}/track2.wav')..writeAsBytesSync([0, 1, 2]);

      final core = LiveBitDropCore(
        handler,
        chunkCacheDir: '${tempDir.path}/cache',
        artworkCacheDir: '${tempDir.path}/art',
      );

      // Send PlayContext with disk directory as contextId and empty trackIds
      await core.send(PlayContext(
        contextId: tempDir.path,
        trackIds: const [],
        contextLabel: 'Test Directory',
      ));

      // Check handler received queued items
      final queued = handler.queue.value;
      expect(queued.length, 2);
      expect(queued.any((i) => i.id == song1.path), isTrue);
      expect(queued.any((i) => i.id == song2.path), isTrue);

      final item1 = queued.firstWhere((i) => i.id == song1.path);
      expect(item1.extras?['source'], 'local');
      expect(item1.extras?['path'], song1.path);
      expect(item1.extras?['ext'], 'flac');

      // The first track should have been played
      expect(engine.playedLocal, isNotEmpty);
    });

    test('PlayContext with explicit mixed track IDs tags local vs cloud correctly',
        () async {
      final localFile = File('${tempDir.path}/song.mp3')
        ..writeAsBytesSync([1, 2, 3]);

      final core = LiveBitDropCore(
        handler,
        chunkCacheDir: '${tempDir.path}/cache',
        artworkCacheDir: '${tempDir.path}/art',
      );

      final mockTrackId = MockCatalog.tracks.first.id;
      // Send PlayContext with 1 local file path and 1 mock track ID
      await core.send(PlayContext(
        contextId: 'mixed_test',
        trackIds: [localFile.path, mockTrackId],
        contextLabel: 'Mixed Playlist',
      ));

      final queued = handler.queue.value;
      expect(queued.length, 2);

      final localItem = queued[0];
      expect(localItem.id, localFile.path);
      expect(localItem.extras?['source'], 'local');
      expect(localItem.extras?['path'], localFile.path);

      final mockItem = queued[1];
      expect(mockItem.id, mockTrackId);
      // Mock catalog item without cloud library should have null cloud extras
      expect(mockItem.extras?['source'], isNot('cloud'));
    });
  });
}

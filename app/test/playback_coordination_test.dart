import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_live/audio_handler.dart';
import 'package:bitdrop/core_live/playback_engine.dart';
import 'package:bitdrop/src/rust/api/audio_engine.dart' as rust;
import 'package:flutter_test/flutter_test.dart';

class RecordingEngine extends PlaybackEngine {
  final controller = StreamController<rust.EngineEvent>.broadcast(sync: true);
  final played = <String>[];
  String? staged;
  int stops = 0;
  String? suppliedToken;
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
      streamOpens: 0);
  @override
  void play(String path) => played.add(path);
  @override
  void stage(String path) {
    staged = path;
  }

  @override
  void clearNext() {
    staged = null;
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
  void supplyToken(BigInt requestId, String? token) {
    suppliedToken = token;
  }

  @override
  void playCloud(
      {required String fileId,
      required String url,
      required String authToken,
      required BigInt totalSize,
      required String cacheDir,
      required String ext}) {
    played.add(fileId);
  }

  @override
  void stageCloud(
      {required String fileId,
      required String url,
      required String authToken,
      required BigInt totalSize,
      required String cacheDir,
      required String ext}) {
    staged = fileId;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RecordingEngine engine;
  late BitDropAudioHandler handler;
  const items = [
    MediaItem(id: 'one', title: 'One'),
    MediaItem(id: 'two', title: 'Two'),
    MediaItem(id: 'three', title: 'Three')
  ];
  setUp(() {
    engine = RecordingEngine();
    handler = BitDropAudioHandler(engine: engine);
  });
  tearDown(() async {
    await handler.dispose();
    await engine.controller.close();
  });

  test('repeat one clears gapless successor and reopens current item at EOF',
      () async {
    await handler.setQueueAndPlay(items, 0);
    expect(engine.staged, 'two');
    await handler.setRepeat(RepeatMode.one);
    expect(engine.staged, isNull);
    engine.controller.add(const rust.EngineEvent.trackEnded(fileId: 'one'));
    await Future<void>.delayed(Duration.zero);
    expect(engine.played, ['one', 'one']);
    expect(handler.currentIndex, 0);
  });
  test('queue edits replace or clear the staged successor', () async {
    await handler.setQueueAndPlay(items, 0);
    await handler.reorderQueue(2, 1);
    expect(engine.staged, 'three');
    await handler.removeQueueItemAtId('three');
    expect(engine.staged, 'two');
    await handler.clearQueue();
    expect(engine.staged, isNull);
  });
  test('removing current item opens its replacement from the updated queue',
      () async {
    await handler.setQueueAndPlay(items, 1);
    await handler.removeQueueItemAtId('two');
    expect(engine.played.last, 'three');
    expect(handler.mediaItem.value?.id, 'three');
  });
  test('late cloud credentials cannot open a track skipped in the meantime',
      () async {
    final token = Completer<String?>();
    handler.cacheDir = '/cache';
    handler.accessTokenProvider = () => token.future;
    final opening = handler.setQueueAndPlay([
      const MediaItem(id: 'cloud', title: 'Cloud', extras: {
        'source': 'cloud',
        'fileId': 'cloud',
        'url': 'https://example.test/cloud',
        'sizeBytes': 8,
      }),
      items[1]
    ], 0);
    await handler.skipToNext();
    token.complete('credential');
    await opening;
    expect(engine.played, ['two']);
  });
  test('stale staging credentials cannot restore a cleared queue', () async {
    final token = Completer<String?>();
    handler.cacheDir = '/cache';
    handler.accessTokenProvider = () => token.future;
    await handler.setQueueAndPlay([
      items[0],
      const MediaItem(id: 'cloud', title: 'Cloud', extras: {
        'source': 'cloud',
        'fileId': 'cloud',
        'url': 'https://example.test/cloud',
        'sizeBytes': 8,
      })
    ], 0);
    await handler.clearQueue();
    token.complete('credential');
    await Future<void>.delayed(Duration.zero);
    expect(engine.staged, isNull);
  });
  test('stop releases playback and keeps the event subscription for replay',
      () async {
    await handler.setQueueAndPlay(items, 0);
    await handler.stop();
    expect(engine.stops, 1);
    await handler.play();
    engine.controller.add(const rust.EngineEvent.trackStarted(fileId: 'two'));
    await Future<void>.delayed(Duration.zero);
    expect(handler.currentIndex, 1);
  });
  test('a delayed matching EOF cannot restart a stopped queue', () async {
    await handler.setQueueAndPlay(items, 0);
    await handler.stop();
    engine.controller.add(const rust.EngineEvent.trackEnded(fileId: 'one'));
    await Future<void>.delayed(Duration.zero);
    expect(engine.played, ['one']);
    expect(handler.currentIndex, 0);
    expect(engine.staged, isNull);
    expect(handler.playbackState.value.playing, isFalse);
  });
  test(
      'stop a populated queue, deliver a delayed matching EOF event, and assert that no track opens',
      () async {
    await handler.setQueueAndPlay(items, 0);
    expect(engine.played, ['one']);
    expect(handler.currentIndex, 0);

    await handler.stop();
    expect(engine.stops, 1);
    expect(handler.playbackState.value.playing, isFalse);

    final countBefore = engine.played.length;
    engine.controller.add(const rust.EngineEvent.trackEnded(fileId: 'one'));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(engine.played.length, countBefore);
    expect(handler.currentIndex, 0);
    expect(engine.staged, isNull);
    expect(handler.playbackState.value.playing, isFalse);
  });
  test('expired credentials are refreshed and returned to the waiting fetch',
      () async {
    handler.refreshAccessTokenProvider = () async => 'new-credential';
    engine.controller
        .add(rust.EngineEvent.tokenRefreshRequested(requestId: BigInt.one));
    await Future<void>.delayed(Duration.zero);
    expect(engine.suppliedToken, 'new-credential');
  });
}

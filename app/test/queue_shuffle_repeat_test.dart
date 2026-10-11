import 'package:audio_service/audio_service.dart';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_live/audio_handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BitDropAudioHandler handler;

  final items = [
    const MediaItem(id: 'track-1', title: 'Song 1', duration: Duration(minutes: 3)),
    const MediaItem(id: 'track-2', title: 'Song 2', duration: Duration(minutes: 4)),
    const MediaItem(id: 'track-3', title: 'Song 3', duration: Duration(minutes: 5)),
    const MediaItem(id: 'track-4', title: 'Song 4', duration: Duration(minutes: 6)),
  ];

  setUp(() {
    handler = BitDropAudioHandler();
  });

  tearDown(() async {
    await handler.stop();
  });

  test('queue initializes with default repeat off and shuffle off', () async {
    await handler.setQueueAndPlay(items, 0);

    expect(handler.currentIndex, 0);
    expect(handler.repeatMode, RepeatMode.off);
    expect(handler.shuffleMode, isFalse);
    expect(handler.queue.value.length, 4);
    expect(handler.mediaItem.value?.id, 'track-1');
  });

  test('toggling repeat updates mode and playback state', () async {
    await handler.setQueueAndPlay(items, 0);

    await handler.setRepeat(RepeatMode.all);
    expect(handler.repeatMode, RepeatMode.all);
    expect(handler.playbackState.value.repeatMode, AudioServiceRepeatMode.all);

    await handler.setRepeat(RepeatMode.one);
    expect(handler.repeatMode, RepeatMode.one);
    expect(handler.playbackState.value.repeatMode, AudioServiceRepeatMode.one);

    await handler.setRepeat(RepeatMode.off);
    expect(handler.repeatMode, RepeatMode.off);
    expect(handler.playbackState.value.repeatMode, AudioServiceRepeatMode.none);
  });

  test('repeat all wraps around to first track at queue boundary', () async {
    await handler.setQueueAndPlay(items, 3); // Start at last track
    expect(handler.currentIndex, 3);

    await handler.setRepeat(RepeatMode.all);
    await handler.skipToNext();

    expect(handler.currentIndex, 0);
    expect(handler.mediaItem.value?.id, 'track-1');
  });

  test('repeat off does not advance past last track', () async {
    await handler.setQueueAndPlay(items, 3);
    expect(handler.currentIndex, 3);

    await handler.setRepeat(RepeatMode.off);
    await handler.skipToNext(auto: true);

    expect(handler.currentIndex, 3);
  });

  test('toggling shuffle randomizes remaining tracks and unshuffles cleanly', () async {
    await handler.setQueueAndPlay(items, 0);

    await handler.setShuffle(true);
    expect(handler.shuffleMode, isTrue);
    expect(handler.playbackState.value.shuffleMode, AudioServiceShuffleMode.all);
    expect(handler.currentIndex, 0);
    expect(handler.queue.value.first.id, 'track-1');
    expect(handler.queue.value.length, 4);

    // Turning shuffle off restores canonical order
    await handler.setShuffle(false);
    expect(handler.shuffleMode, isFalse);
    expect(handler.playbackState.value.shuffleMode, AudioServiceShuffleMode.none);
    expect(handler.queue.value.map((i) => i.id).toList(), [
      'track-1',
      'track-2',
      'track-3',
      'track-4',
    ]);
  });

  test('starting context with shuffle: true preserves original list for unshuffling', () async {
    await handler.setQueueAndPlay(items, 0, shuffle: true);

    expect(handler.shuffleMode, isTrue);
    expect(handler.currentIndex, 0);
    expect(handler.queue.value.first.id, 'track-1');

    await handler.setShuffle(false);
    expect(handler.queue.value.map((i) => i.id).toList(), [
      'track-1',
      'track-2',
      'track-3',
      'track-4',
    ]);
  });

  test('reordering and removing queue items', () async {
    await handler.setQueueAndPlay(items, 0);

    await handler.removeQueueItemAtId('track-2');
    expect(handler.queue.value.map((i) => i.id).toList(), [
      'track-1',
      'track-3',
      'track-4',
    ]);

    await handler.reorderQueue(1, 2);
    expect(handler.queue.value.map((i) => i.id).toList(), [
      'track-1',
      'track-4',
      'track-3',
    ]);
  });
}

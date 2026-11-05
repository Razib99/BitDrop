import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:bitdrop/core_api/commands.dart';
import 'package:bitdrop/core_live/audio_handler.dart';
import 'package:bitdrop/core_live/live_core.dart';
import 'package:bitdrop/core_mock/catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BitDropAudioHandler Lockscreen Controls & System Actions', () {
    late BitDropAudioHandler handler;

    final testItems = [
      const MediaItem(
        id: 'track-1',
        title: 'Song 1',
        album: 'Album 1',
        artist: 'Artist 1',
        duration: Duration(minutes: 3),
      ),
      const MediaItem(
        id: 'track-2',
        title: 'Song 2',
        album: 'Album 1',
        artist: 'Artist 1',
        duration: Duration(minutes: 4),
      ),
    ];

    setUp(() {
      handler = BitDropAudioHandler();
    });

    tearDown(() async {
      await handler.stop();
    });

    test('playbackState contains required systemActions for lockscreen/notification controls', () async {
      await handler.setQueueAndPlay(testItems, 0);

      final state = handler.playbackState.value;
      final actions = state.systemActions;

      expect(actions.contains(MediaAction.play), isTrue);
      expect(actions.contains(MediaAction.pause), isTrue);
      expect(actions.contains(MediaAction.playPause), isTrue);
      expect(actions.contains(MediaAction.stop), isTrue);
      expect(actions.contains(MediaAction.skipToNext), isTrue);
      expect(actions.contains(MediaAction.skipToPrevious), isTrue);
      // Seek is enabled so Android renders the scrub bar when pulled down/expanded
      expect(actions.contains(MediaAction.seek), isTrue);
      expect(actions.contains(MediaAction.seekForward), isTrue);
      expect(actions.contains(MediaAction.seekBackward), isTrue);
      expect(state.androidCompactActionIndices, const [0, 1, 2]);
      expect(state.controls.length, 3);
      expect(state.controls[0].action, MediaAction.skipToPrevious);
      expect(state.controls[1].action, MediaAction.play);
      expect(state.controls[2].action, MediaAction.skipToNext);
    });

    test('processingState stays ready when paused with a track loaded', () async {
      await handler.setQueueAndPlay(testItems, 0);

      // Even if paused, processingState must be ready so Android does not kill notification
      await handler.pause();
      final state = handler.playbackState.value;
      expect(state.processingState, AudioProcessingState.ready);
    });

    test('skipToNext advances track and updates mediaItem', () async {
      await handler.setQueueAndPlay(testItems, 0);
      expect(handler.currentIndex, 0);
      expect(handler.mediaItem.value?.id, 'track-1');

      await handler.skipToNext();
      expect(handler.currentIndex, 1);
      expect(handler.mediaItem.value?.id, 'track-2');
    });

    test('skipToPrevious returns to previous track', () async {
      await handler.setQueueAndPlay(testItems, 1);
      expect(handler.currentIndex, 1);

      await handler.skipToPrevious();
      expect(handler.currentIndex, 0);
      expect(handler.mediaItem.value?.id, 'track-1');
    });
  });

  group('LiveBitDropCore Artwork Resolution for MediaItem', () {
    late Directory tempDir;
    late BitDropAudioHandler handler;
    late LiveBitDropCore liveCore;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('bitdrop_art_test_');
      handler = BitDropAudioHandler();

      liveCore = LiveBitDropCore(
        handler,
        artworkCacheDir: tempDir.path,
        chunkCacheDir: tempDir.path,
      );
    });

    tearDown(() async {
      await handler.stop();
      liveCore.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('PlayContext maps tracks and plays via handler', () async {
      final track = MockCatalog.tracks.first;

      await liveCore.send(PlayContext(
        contextId: 'test_ctx',
        trackIds: [track.id],
        startIndex: 0,
      ));

      // Verify that handler received the track in queue
      expect(handler.queue.value.isNotEmpty, isTrue);
      final currentItem = handler.queue.value.first;
      expect(currentItem.id, track.id);
      expect(currentItem.title, track.title);
      expect(currentItem.artist, track.artist);
    });
  });
}

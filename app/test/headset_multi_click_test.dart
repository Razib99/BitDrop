import 'package:audio_service/audio_service.dart';
import 'package:bitdrop/core_api/settings.dart';
import 'package:bitdrop/core_live/audio_handler.dart';
import 'package:bitdrop/core_live/persistence_codec.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestAudioHandler extends BitDropAudioHandler {
  int playCalls = 0;
  int pauseCalls = 0;
  int nextCalls = 0;
  int prevCalls = 0;

  @override
  Future<void> play() async {
    playCalls++;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
  }

  @override
  Future<void> skipToNext({bool auto = false}) async {
    nextCalls++;
  }

  @override
  Future<void> skipToPrevious() async {
    prevCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('IEM / headset inline button multi-press', () {
    late _TestAudioHandler handler;

    setUp(() {
      handler = _TestAudioHandler()
        ..mediaButtonMultiClickWindow = const Duration(milliseconds: 60)
        ..headsetMultiClickEnabled = true;
    });

    tearDown(() async {
      await handler.dispose();
    });

    test('single press toggles playback after multi-click window', () async {
      await handler.click(MediaButton.media);
      expect(handler.playCalls, 0);
      await Future<void>.delayed(const Duration(milliseconds: 90));

      expect(handler.playCalls, 1);
      expect(handler.nextCalls, 0);
      expect(handler.prevCalls, 0);
    });

    test('double press skips to next track without toggling play/pause',
        () async {
      await handler.click(MediaButton.media);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await handler.click(MediaButton.media);
      await Future<void>.delayed(const Duration(milliseconds: 90));

      expect(handler.nextCalls, 1);
      expect(handler.playCalls, 0);
      expect(handler.pauseCalls, 0);
      expect(handler.prevCalls, 0);
    });

    test('triple press skips to previous track immediately on 3rd press',
        () async {
      await handler.click(MediaButton.media);
      await Future<void>.delayed(const Duration(milliseconds: 15));
      await handler.click(MediaButton.media);
      await Future<void>.delayed(const Duration(milliseconds: 15));
      await handler.click(MediaButton.media);

      // Dispatches immediately without waiting for timer expiration
      expect(handler.prevCalls, 1);
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(handler.prevCalls, 1);
      expect(handler.nextCalls, 0);
      expect(handler.playCalls, 0);
    });

    test('disabling multi-click toggles play/pause immediately on 1st press',
        () async {
      handler.headsetMultiClickEnabled = false;
      await handler.click(MediaButton.media);

      expect(handler.playCalls, 1);
      expect(handler.nextCalls, 0);
      expect(handler.prevCalls, 0);
    });

    test('explicit next/previous buttons cancel pending click timer', () async {
      await handler.click(MediaButton.media);
      await handler.click(MediaButton.next);
      await Future<void>.delayed(const Duration(milliseconds: 90));

      expect(handler.nextCalls, 1);
      expect(handler.playCalls, 0);

      await handler.click(MediaButton.media);
      await handler.click(MediaButton.previous);
      await Future<void>.delayed(const Duration(milliseconds: 90));

      expect(handler.prevCalls, 1);
      expect(handler.playCalls, 0);
    });

    test('AppSettings and PersistenceCodec roundtrip headsetMultiClickControls',
        () {
      const defaults = AppSettings();
      expect(defaults.headsetMultiClickControls, isTrue);

      final updated = defaults.withKey('headsetMultiClickControls', false);
      expect(updated.headsetMultiClickControls, isFalse);

      final json = PersistenceCodec.serializeAppSettings(updated);
      final restored = PersistenceCodec.deserializeAppSettings(json);
      expect(restored.headsetMultiClickControls, isFalse);
    });
  });
}

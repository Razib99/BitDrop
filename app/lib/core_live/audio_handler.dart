import 'dart:async';
import 'package:audio_service/audio_service.dart';
import '../src/rust/api/audio_engine.dart' as rust;

class BitDropAudioHandler extends BaseAudioHandler with SeekHandler, QueueHandler {
  Timer? _positionTimer;
  bool _wasPlaying = false;
  int _currentIndex = -1;
  
  BitDropAudioHandler() {
    _positionTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      _syncState();
    });
  }
  
  void _syncState() {
    if (mediaItem.value == null) return;
    
    final positionMs = rust.engineGetPosition();
    final isPlaying = rust.engineIsPlaying();
    
    // EOF Detection (if it stopped playing naturally)
    if (_wasPlaying && !isPlaying && positionMs > 0) {
      final duration = mediaItem.value?.duration?.inMilliseconds ?? 0;
      // If we are within 1 second of the end and it stopped, assume EOF
      if (duration > 0 && positionMs >= duration - 1000) {
        _wasPlaying = isPlaying;
        skipToNext();
        return;
      }
    }
    _wasPlaying = isPlaying;
    
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        isPlaying ? MediaControl.pause : MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: isPlaying ? AudioProcessingState.ready : AudioProcessingState.idle,
      playing: isPlaying,
      updatePosition: Duration(milliseconds: positionMs),
    ));
  }

  Future<void> setQueueAndPlay(List<MediaItem> items, int startIndex) async {
    queue.add(items);
    _currentIndex = startIndex;
    if (_currentIndex >= 0 && _currentIndex < items.length) {
      await _playCurrentIndex();
    }
  }

  Future<void> _playCurrentIndex() async {
    final items = queue.value;
    if (_currentIndex < 0 || _currentIndex >= items.length) return;
    
    final item = items[_currentIndex];
    mediaItem.add(item);
    
    // The ID contains the physical path from our mock injection
    rust.enginePlay(path: item.id);
  }

  @override
  Future<void> skipToNext() async {
    final items = queue.value;
    if (_currentIndex < items.length - 1) {
      _currentIndex++;
      await _playCurrentIndex();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_currentIndex > 0) {
      _currentIndex--;
      await _playCurrentIndex();
    }
  }

  @override
  Future<void> play() async {
    rust.engineResume();
  }

  @override
  Future<void> pause() async {
    rust.enginePause();
  }

  @override
  Future<void> seek(Duration position) async {
    rust.engineSeek(positionMs: position.inMilliseconds);
  }

  @override
  Future<void> stop() async {
    rust.enginePause();
    _positionTimer?.cancel();
    await super.stop();
  }
}

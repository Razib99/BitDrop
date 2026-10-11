import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import '../src/rust/api/audio_engine.dart' as rust;

/// Supplies a currently-valid OAuth access token for cloud playback.
///
/// A callback rather than a direct dependency on GoogleDriveService, so the
/// handler stays unaware of which cloud provider is in use.
typedef AccessTokenProvider = Future<String?> Function();

/// Marks a [MediaItem] as living in cloud storage. Builds the `extras` map
/// that [BitDropAudioHandler] reads when it opens the track.
Map<String, dynamic> cloudTrackExtras({
  required String fileId,
  required String url,
  required int sizeBytes,
  required String ext,
}) =>
    {
      'source': 'cloud',
      'fileId': fileId,
      'url': url,
      'sizeBytes': sizeBytes,
      'ext': ext,
    };

class BitDropAudioHandler extends BaseAudioHandler with SeekHandler, QueueHandler {
  Timer? _positionTimer;
  bool _wasPlaying = false;
  int _currentIndex = -1;

  /// Where the Rust engine writes cached byte-range chunks. Until this is set
  /// the handler can still play local files; only cloud playback needs it.
  String? cacheDir;

  /// Set once Drive is connected. Null means cloud tracks cannot be opened.
  AccessTokenProvider? accessTokenProvider;

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

    debugPrint('[play] opening ${item.id} '
        'source=${item.extras?['source'] ?? 'local'}');

    if (item.extras?['source'] == 'cloud') {
      await _playCloud(item);
      return;
    }

    // For a local track the id is the physical path on disk.
    rust.enginePlay(path: item.id);
  }

  /// Opens a track streamed from cloud storage.
  ///
  /// The token is fetched per track rather than cached: access tokens last
  /// about an hour, and the engine holds whatever it is given for the whole
  /// track, so a stale one would fail partway through an album.
  Future<void> _playCloud(MediaItem item) async {
    final extras = item.extras;
    final dir = cacheDir;
    final provider = accessTokenProvider;

    if (extras == null || dir == null || provider == null) {
      _reportCloudError(
        dir == null
            ? 'Cache directory is not ready yet.'
            : 'Not signed in to your cloud storage.',
      );
      return;
    }

    final token = await provider();
    if (token == null) {
      // Expired or revoked grant. Google's testing mode drops it roughly
      // weekly, so this is an expected state, not a crash.
      _reportCloudError('Your cloud session expired. Reconnect to keep playing.');
      return;
    }

    debugPrint('[play] cloud ${extras['fileId']} '
        'size=${extras['sizeBytes']} ext=${extras['ext']}');

    rust.enginePlayCloud(
      fileId: extras['fileId'] as String,
      url: extras['url'] as String,
      authToken: token,
      totalSize: BigInt.from(extras['sizeBytes'] as int? ?? 0),
      cacheDir: dir,
      ext: extras['ext'] as String? ?? '',
    );
  }

  void _reportCloudError(String message) {
    debugPrint('[play] cloud error: $message');
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.error,
      playing: false,
      errorMessage: message,
    ));
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

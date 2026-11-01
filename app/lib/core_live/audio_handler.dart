import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import '../core_api/enums.dart';
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
  StreamSubscription<rust.EngineEvent>? _eventsSubscription;
  bool _wasPlaying = false;
  int _currentIndex = -1;
  RepeatMode _repeatMode = RepeatMode.off;
  bool _shuffleMode = false;
  List<MediaItem> _originalQueue = [];

  RepeatMode get repeatMode => _repeatMode;
  bool get shuffleMode => _shuffleMode;
  int get currentIndex => _currentIndex;

  /// Where the Rust engine writes cached byte-range chunks. Until this is set
  /// the handler can still play local files; only cloud playback needs it.
  String? cacheDir;

  /// Set once Drive is connected. Null means cloud tracks cannot be opened.
  AccessTokenProvider? accessTokenProvider;

  BitDropAudioHandler() {
    _initEngineEventStream();
  }

  void _initEngineEventStream() {
    try {
      _eventsSubscription = rust.engineEventsStream().listen(
        _handleEngineEvent,
        onError: (err) {
          debugPrint('[BitDropAudioHandler] Engine event stream error: $err');
        },
      );
    } catch (e) {
      debugPrint('[BitDropAudioHandler] Stream init skipped (headless/mock): $e');
    }
  }

  void _handleEngineEvent(rust.EngineEvent event) {
    switch (event) {
      case rust.EngineEvent_PlaybackState(:final isPlaying, :final isBuffering):
        _wasPlaying = isPlaying;
        playbackState.add(playbackState.value.copyWith(
          playing: isPlaying,
          controls: [
            MediaControl.skipToPrevious,
            isPlaying ? MediaControl.pause : MediaControl.play,
            MediaControl.skipToNext,
          ],
          processingState: isBuffering
              ? AudioProcessingState.buffering
              : (mediaItem.value != null ? AudioProcessingState.ready : AudioProcessingState.idle),
        ));
      case rust.EngineEvent_TrackStarted(:final fileId):
        final items = queue.value;
        final idx = items.indexWhere((i) {
          if (i.extras?['source'] == 'cloud') {
            return i.extras?['fileId'] == fileId;
          }
          return i.id == fileId;
        });
        if (idx >= 0 && idx != _currentIndex) {
          _currentIndex = idx;
          mediaItem.add(items[idx]);
          unawaited(_stageNextTrack());
        }
      case rust.EngineEvent_TrackEnded():
        skipToNext(auto: true);
      case rust.EngineEvent_PositionUpdate(:final positionMs, :final durationMs):
        final currentPos = Duration(milliseconds: positionMs);
        final currentDur = mediaItem.value?.duration?.inMilliseconds ?? 0;
        if (durationMs > 0 && currentDur != durationMs && mediaItem.value != null) {
          mediaItem.add(mediaItem.value!.copyWith(duration: Duration(milliseconds: durationMs)));
        }
        playbackState.add(playbackState.value.copyWith(
          updatePosition: currentPos,
        ));
      case rust.EngineEvent_BufferTelemetry(:final bufferedMs, :final fetchesInFlight):
        final pos = playbackState.value.position;
        playbackState.add(playbackState.value.copyWith(
          bufferedPosition: pos + Duration(milliseconds: bufferedMs),
          processingState: fetchesInFlight > 0 && bufferedMs < 500
              ? AudioProcessingState.buffering
              : (mediaItem.value != null ? AudioProcessingState.ready : AudioProcessingState.idle),
        ));
      case rust.EngineEvent_LimiterTelemetry():
        break;
    }
  }

  Future<void> _stageNextTrack() async {
    final items = queue.value;
    if (items.isEmpty || _currentIndex < 0) return;

    MediaItem? nextItem;
    if (_currentIndex + 1 < items.length) {
      nextItem = items[_currentIndex + 1];
    } else if (_repeatMode == RepeatMode.all) {
      nextItem = items.first;
    }

    if (nextItem == null) return;

    try {
      if (nextItem.extras?['source'] == 'cloud') {
        final extras = nextItem.extras!;
        final dir = cacheDir;
        final provider = accessTokenProvider;
        if (dir != null && provider != null) {
          final token = await provider();
          if (token != null) {
            rust.engineSetNextCloud(
              fileId: extras['fileId'] as String,
              url: extras['url'] as String,
              authToken: token,
              totalSize: BigInt.from(extras['sizeBytes'] as int? ?? 0),
              cacheDir: dir,
              ext: extras['ext'] as String? ?? '',
            );
          }
        }
      } else {
        rust.engineSetNextTrack(path: nextItem.id);
      }
    } catch (e) {
      debugPrint('[stageNextTrack] error: $e');
    }
  }
  
  void _syncState() {
    if (mediaItem.value == null) return;

    int positionMs = 0;
    bool isPlaying = false;
    rust.EngineBufferState buffer = rust.EngineBufferState(
      buffering: false,
      bufferedMs: 0,
      fetchesInFlight: 0,
      bytesFetched: BigInt.zero,
      streamOpens: 0,
    );
    try {
      positionMs = rust.engineGetPosition();
      isPlaying = rust.engineIsPlaying();
      buffer = rust.engineBufferState();
    } catch (_) {
      // In headless test environments where RustLib is not initialized
    }
    
    // EOF Detection (if it stopped playing naturally)
    if (_wasPlaying && !isPlaying && positionMs > 0) {
      final duration = mediaItem.value?.duration?.inMilliseconds ?? 0;
      // If we are within 1 second of the end and it stopped, assume EOF
      if (duration > 0 && positionMs >= duration - 1000) {
        _wasPlaying = isPlaying;
        skipToNext(auto: true);
        return;
      }
    }
    _wasPlaying = isPlaying;
    
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        isPlaying ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.setRepeatMode,
        MediaAction.setShuffleMode,
        MediaAction.play,
        MediaAction.pause,
        MediaAction.playPause,
        MediaAction.stop,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
      androidCompactActionIndices: const [0, 1, 2],
      // Buffering is a distinct state from paused: the user did not stop
      // this, the network did, and the UI should say which.
      processingState: buffer.buffering
          ? AudioProcessingState.buffering
          : (mediaItem.value != null ? AudioProcessingState.ready : AudioProcessingState.idle),
      playing: isPlaying,
      repeatMode: switch (_repeatMode) {
        RepeatMode.off => AudioServiceRepeatMode.none,
        RepeatMode.all => AudioServiceRepeatMode.all,
        RepeatMode.one => AudioServiceRepeatMode.one,
      },
      shuffleMode: _shuffleMode
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
      updatePosition: Duration(milliseconds: positionMs),
      bufferedPosition:
          Duration(milliseconds: positionMs + buffer.bufferedMs),
    ));
  }

  Future<void> setRepeat(RepeatMode mode) async {
    _repeatMode = mode;
    _syncState();
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    switch (repeatMode) {
      case AudioServiceRepeatMode.none:
      case AudioServiceRepeatMode.group:
        await setRepeat(RepeatMode.off);
      case AudioServiceRepeatMode.one:
        await setRepeat(RepeatMode.one);
      case AudioServiceRepeatMode.all:
        await setRepeat(RepeatMode.all);
    }
  }

  Future<void> setShuffle(bool enabled) async {
    if (_shuffleMode == enabled) return;
    _shuffleMode = enabled;

    final currentList = queue.value;
    if (currentList.isEmpty || _currentIndex < 0 || _currentIndex >= currentList.length) {
      _syncState();
      return;
    }

    if (enabled) {
      if (_originalQueue.isEmpty || _originalQueue.length != currentList.length) {
        _originalQueue = List<MediaItem>.from(currentList);
      }
      final played = currentList.sublist(0, _currentIndex + 1);
      final remaining = currentList.sublist(_currentIndex + 1)..shuffle();
      final newQueue = [...played, ...remaining];
      queue.add(newQueue);
    } else {
      if (_originalQueue.isNotEmpty) {
        final playedIds = currentList.sublist(0, _currentIndex + 1).map((i) => i.id).toSet();
        final remainingInOriginal = _originalQueue.where((i) => !playedIds.contains(i.id)).toList();
        final played = currentList.sublist(0, _currentIndex + 1);
        final newQueue = [...played, ...remainingInOriginal];
        queue.add(newQueue);
      }
    }
    _syncState();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    await setShuffle(shuffleMode != AudioServiceShuffleMode.none);
  }

  Future<void> shuffleRemaining() async {
    final currentList = queue.value;
    if (currentList.isEmpty || _currentIndex < 0 || _currentIndex >= currentList.length - 1) return;

    _shuffleMode = true;
    final head = currentList.sublist(0, _currentIndex + 1);
    final tail = currentList.sublist(_currentIndex + 1)..shuffle();
    queue.add([...head, ...tail]);
    _syncState();
  }

  Future<void> setQueueAndPlay(
    List<MediaItem> items,
    int startIndex, {
    bool shuffle = false,
  }) async {
    _originalQueue = List<MediaItem>.from(items);
    _shuffleMode = shuffle;

    if (items.isEmpty) {
      queue.add(const []);
      _currentIndex = -1;
      _syncState();
      return;
    }

    final safeStart = startIndex.clamp(0, items.length - 1);

    if (shuffle && items.length > 1) {
      final chosen = items[safeStart];
      final others = items.where((i) => i.id != chosen.id).toList()..shuffle();
      final shuffledList = [chosen, ...others];
      queue.add(shuffledList);
      _currentIndex = 0;
    } else {
      queue.add(items);
      _currentIndex = safeStart;
    }

    if (_currentIndex >= 0 && _currentIndex < queue.value.length) {
      await _playCurrentIndex();
    }
    _syncState();
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
      unawaited(_stageNextTrack());
      return;
    }

    // For a local track the id is the physical path on disk.
    try {
      rust.enginePlay(path: item.id);
      unawaited(_stageNextTrack());
    } catch (e) {
      debugPrint('[play] enginePlay error: $e');
    }
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
  Future<void> skipToNext({bool auto = false}) async {
    final items = queue.value;
    if (items.isEmpty) return;

    if (auto && _repeatMode == RepeatMode.one) {
      await seek(Duration.zero);
      await play();
      return;
    }

    if (_currentIndex < items.length - 1) {
      _currentIndex++;
      await _playCurrentIndex();
    } else if (_repeatMode == RepeatMode.all) {
      _currentIndex = 0;
      await _playCurrentIndex();
    } else if (auto) {
      await pause();
      await seek(Duration.zero);
    }
    _syncState();
  }

  @override
  Future<void> skipToPrevious() async {
    final items = queue.value;
    if (items.isEmpty) return;

    int pos = 0;
    try {
      pos = rust.engineGetPosition();
    } catch (_) {}
    if (pos > 3000) {
      await seek(Duration.zero);
    } else if (_currentIndex > 0) {
      _currentIndex--;
      await _playCurrentIndex();
    } else if (_repeatMode == RepeatMode.all && items.isNotEmpty) {
      _currentIndex = items.length - 1;
      await _playCurrentIndex();
    } else {
      await seek(Duration.zero);
    }
    _syncState();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    final items = queue.value;
    if (index >= 0 && index < items.length) {
      _currentIndex = index;
      await _playCurrentIndex();
      _syncState();
    }
  }

  Future<void> clearQueue() async {
    final current = mediaItem.value;
    if (current != null) {
      queue.add([current]);
      _currentIndex = 0;
    } else {
      queue.add(const []);
      _currentIndex = -1;
    }
    _originalQueue = List<MediaItem>.from(queue.value);
    _syncState();
  }

  @override
  Future<void> removeQueueItem(MediaItem mediaItem) async {
    await removeQueueItemAtId(mediaItem.id);
  }

  Future<void> removeQueueItemAtId(String id) async {
    final items = [...queue.value];
    final idx = items.indexWhere((i) => i.id == id);
    if (idx < 0) return;
    items.removeAt(idx);
    _originalQueue.removeWhere((i) => i.id == id);
    if (idx < _currentIndex) {
      _currentIndex--;
    } else if (idx == _currentIndex) {
      if (_currentIndex >= items.length) {
        _currentIndex = items.length - 1;
      }
      if (_currentIndex >= 0) {
        await _playCurrentIndex();
      } else {
        await pause();
        mediaItem.add(null);
      }
    }
    queue.add(items);
    _syncState();
  }

  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    final items = [...queue.value];
    if (oldIndex < 0 || oldIndex >= items.length) return;
    final item = items.removeAt(oldIndex);
    items.insert(newIndex.clamp(0, items.length), item);
    if (oldIndex == _currentIndex) {
      _currentIndex = newIndex.clamp(0, items.length - 1);
    } else if (oldIndex < _currentIndex && newIndex >= _currentIndex) {
      _currentIndex--;
    } else if (oldIndex > _currentIndex && newIndex <= _currentIndex) {
      _currentIndex++;
    }
    queue.add(items);
    _syncState();
  }

  Future<void> playNext(List<MediaItem> newItems) async {
    if (newItems.isEmpty) return;
    final items = [...queue.value];
    final insertAt = (_currentIndex + 1).clamp(0, items.length);
    items.insertAll(insertAt, newItems);
    queue.add(items);
    _originalQueue.addAll(newItems);
    _syncState();
  }

  Future<void> enqueue(List<MediaItem> newItems) async {
    if (newItems.isEmpty) return;
    final items = [...queue.value, ...newItems];
    queue.add(items);
    _originalQueue.addAll(newItems);
    _syncState();
  }

  @override
  Future<void> play() async {
    try {
      rust.engineResume();
    } catch (_) {}
    _syncState();
  }

  @override
  Future<void> pause() async {
    try {
      rust.enginePause();
    } catch (_) {}
    _syncState();
  }

  @override
  Future<void> seek(Duration position) async {
    try {
      rust.engineSeek(positionMs: position.inMilliseconds);
    } catch (_) {}
    _syncState();
  }

  @override
  Future<void> stop() async {
    try {
      rust.enginePause();
    } catch (_) {}
    await _eventsSubscription?.cancel();
    _syncState();
    await super.stop();
  }

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    switch (button) {
      case MediaButton.media:
        bool playing = false;
        try {
          playing = rust.engineIsPlaying();
        } catch (_) {}
        if (playing) {
          await pause();
        } else {
          await play();
        }
      case MediaButton.next:
        await skipToNext();
      case MediaButton.previous:
        await skipToPrevious();
    }
  }
}

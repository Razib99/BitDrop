import re

with open("app/lib/core_live/live_core.dart", "r") as f:
    core = f.read()

bad_queue = """    _audioHandler.queue.listen((items) {
      if (items.isEmpty) return;
      final currentItem = _audioHandler.mediaItem.value;
      final currentIndex = currentItem == null ? 0 : items.indexOf(currentItem);
      final tracks = items.map((i) => MockCatalog.trackById(i.id)).whereType<Track>().toList();
      _queue.add(QueueState(tracks: tracks, currentIndex: currentIndex < 0 ? 0 : currentIndex));
    });
    
    _audioHandler.mediaItem.listen((item) {
      if (item != null) {
        final track = MockCatalog.trackById(item.id);
        if (track != null) {
          _nowPlaying.add(NowPlaying(track: track, contextLabel: 'Local Music'));
          
          // Update queue index
          final q = _queue.value;
          final idx = q.tracks.indexWhere((t) => t.id == item.id);
          if (idx >= 0) {
            _queue.add(q.copyWith(currentIndex: idx));
          }
        }
      }
    });"""

good_queue = """    _audioHandler.queue.listen((items) {
      if (items.isEmpty) return;
      final currentItem = _audioHandler.mediaItem.value;
      final currentIndex = currentItem == null ? 0 : items.indexOf(currentItem);
      final tracks = items.map((i) => MockCatalog.trackById(i.id)).whereType<Track>().toList();
      final queueItems = tracks.map((t) => QueueItem(track: t, id: t.id)).toList();
      _queue.add(QueueState(items: queueItems, currentIndex: currentIndex < 0 ? 0 : currentIndex, shuffle: false, repeat: RepeatMode.off));
    });
    
    _audioHandler.mediaItem.listen((item) {
      if (item != null) {
        final track = MockCatalog.trackById(item.id);
        if (track != null) {
          _nowPlaying.add(NowPlaying(track: track, contextLabel: 'Local Music'));
          
          // Update queue index
          final q = _queue.value;
          final idx = q.items.indexWhere((i) => i.id == item.id);
          if (idx >= 0) {
            _queue.add(QueueState(items: q.items, currentIndex: idx, shuffle: q.shuffle, repeat: q.repeat));
          }
        }
      }
    });"""

core = core.replace(bad_queue, good_queue)
with open("app/lib/core_live/live_core.dart", "w") as f:
    f.write(core)

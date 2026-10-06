import re

with open("app/lib/core_live/live_core.dart", "r") as f:
    core = f.read()

# 1. Add queue interception
core = core.replace("@override Stream<QueueState> get queue => _mockCore.queue;", "final _queue = BehaviorSubject<QueueState>.seeded(QueueState.empty);\n  @override Stream<QueueState> get queue => _queue.stream;")

# 2. Hook up the audio handler's queue to the behavior subject
queue_hook = """    _audioHandler.queue.listen((items) {
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

core = re.sub(r"    _audioHandler\.mediaItem\.listen\(\(item\) \{.*?\}\);", queue_hook, core, flags=re.DOTALL)

# 3. Update the send(PlayContext)
send_hook = """    if (cmd is PlayContext) {
      final tracks = cmd.trackIds.map(MockCatalog.trackById).whereType<Track>().toList();
      if (tracks.isNotEmpty) {
        final items = tracks.map((t) => audio_svc.MediaItem(
          id: t.id,
          title: t.title,
          album: t.albumTitle,
          artist: t.artist,
          duration: Duration(milliseconds: t.durationMs),
        )).toList();
        
        if (cmd.shuffle) {
          items.shuffle();
        }
        
        await _audioHandler.setQueueAndPlay(items, cmd.startIndex);
      }
    }"""

core = re.sub(r"    if \(cmd is PlayContext\) \{.*?    \} else if", send_hook + " else if", core, flags=re.DOTALL)

with open("app/lib/core_live/live_core.dart", "w") as f:
    f.write(core)

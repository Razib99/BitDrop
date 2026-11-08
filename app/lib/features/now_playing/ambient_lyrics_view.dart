import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core_api/commands.dart';
import '../../core_api/models.dart';
import '../../providers/core_providers.dart';
import '../../theme/tokens.dart';

/// Renders time-synchronized or plain lyrics over an ambient background
/// with smooth auto-scrolling, active line glowing, and tap-to-seek.
class AmbientLyricsView extends ConsumerStatefulWidget {
  const AmbientLyricsView({
    super.key,
    required this.track,
    this.onClose,
  });

  final Track track;
  final VoidCallback? onClose;

  @override
  ConsumerState<AmbientLyricsView> createState() => _AmbientLyricsViewState();
}

class _AmbientLyricsViewState extends ConsumerState<AmbientLyricsView> {
  final ScrollController _scrollController = ScrollController();
  int _activeLineIndex = -1;
  bool _userIsScrolling = false;
  DateTime _lastUserScrollTime = DateTime.fromMillisecondsSinceEpoch(0);

  // Approximate item height for calculating target scroll offset
  static const double _estimatedLineHeight = 56.0;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToActiveLine(int index, int totalLines, double viewportHeight) {
    if (!_scrollController.hasClients || totalLines == 0) return;

    // If user recently scrolled manually, pause auto-scroll for 2.5 seconds
    final now = DateTime.now();
    if (_userIsScrolling ||
        now.difference(_lastUserScrollTime).inMilliseconds < 2500) {
      return;
    }

    final targetOffset = (index * _estimatedLineHeight) -
        (viewportHeight / 2) +
        (_estimatedLineHeight / 2);
    final clamped = targetOffset.clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );

    _scrollController.animateTo(
      clamped,
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final lyricsAsync = ref.watch(lyricsProvider(widget.track));
    final position = ref.watch(positionProvider).valueOrNull?.positionMs ?? 0;

    return lyricsAsync.when(
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(Spacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(strokeWidth: 2),
              SizedBox(height: Spacing.md),
              Text(
                'Searching for lyrics...',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
      error: (err, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lyrics_outlined, size: 48, color: Colors.white38),
              const SizedBox(height: Spacing.md),
              const Text(
                'Could not load lyrics',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: Spacing.xs),
              Text(
                err.toString(),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
      data: (lyrics) {
        if (lyrics == null ||
            (lyrics.lines.isEmpty && lyrics.plainLyrics.trim().isEmpty)) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(Spacing.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.lyrics_outlined,
                    size: 48,
                    color: Colors.white38,
                  ),
                  const SizedBox(height: Spacing.md),
                  const Text(
                    'No lyrics available',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    'Neither embedded tags nor LRCLIB have lyrics for "${widget.track.title}".',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ],
              ),
            ),
          );
        }

        if (!lyrics.synced) {
          // Unsynced plain-text display
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.xl),
            child: SingleChildScrollView(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(vertical: Spacing.xl),
              child: Text(
                lyrics.plainLyrics,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  height: 1.8,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          );
        }

        // Time-synced lyrics with active line tracking
        int newActiveIndex = -1;
        for (int i = 0; i < lyrics.lines.length; i++) {
          if (lyrics.lines[i].timestampMs <= position) {
            newActiveIndex = i;
          } else {
            break;
          }
        }

        if (newActiveIndex != _activeLineIndex) {
          _activeLineIndex = newActiveIndex;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              final viewportHeight = MediaQuery.sizeOf(context).height * 0.45;
              _scrollToActiveLine(
                _activeLineIndex,
                lyrics.lines.length,
                viewportHeight,
              );
            }
          });
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            final viewportHeight = constraints.maxHeight;
            return NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is ScrollStartNotification) {
                  _userIsScrolling = true;
                } else if (notification is ScrollEndNotification) {
                  _userIsScrolling = false;
                  _lastUserScrollTime = DateTime.now();
                }
                return false;
              },
              child: ListView.builder(
                controller: _scrollController,
                padding: EdgeInsets.symmetric(
                  vertical: viewportHeight * 0.42,
                  horizontal: Spacing.xl,
                ),
                itemCount: lyrics.lines.length,
                itemBuilder: (context, index) {
                  final line = lyrics.lines[index];
                  final isActive = index == _activeLineIndex;
                  final isPassed = index < _activeLineIndex;

                  return GestureDetector(
                    onTap: () {
                      sendCommand(ref, Seek(line.timestampMs));
                      _lastUserScrollTime = DateTime.fromMillisecondsSinceEpoch(0);
                    },
                    behavior: HitTestBehavior.opaque,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOutCubic,
                      padding: const EdgeInsets.symmetric(
                        vertical: 10,
                        horizontal: Spacing.xs,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        line.text,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: isActive
                              ? Colors.white
                              : (isPassed ? Colors.white38 : Colors.white54),
                          fontSize: isActive ? 22 : 18,
                          fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                          height: 1.4,
                          shadows: isActive
                              ? const [
                                  Shadow(
                                    color: Color(0x9900E5FF),
                                    blurRadius: 18,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

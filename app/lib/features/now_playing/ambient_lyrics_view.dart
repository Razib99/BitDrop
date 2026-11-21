import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core_api/commands.dart';
import '../../core_api/models.dart';
import '../../providers/core_providers.dart';
import '../../theme/tokens.dart';
import '../../util/poster_color.dart';

/// Renders time-synchronized or plain lyrics over an ambient background
/// with accurate key-based auto-scrolling, adaptive active glow, edge fade,
/// and tap-to-seek.
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
  final Map<int, GlobalKey> _lineKeys = {};
  int _activeLineIndex = -1;
  bool _manualBrowse = false;
  Timer? _resumeTimer;

  @override
  void didUpdateWidget(covariant AmbientLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.id != widget.track.id) {
      _activeLineIndex = -1;
      _lineKeys.clear();
      _manualBrowse = false;
      _resumeTimer?.cancel();
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    }
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  GlobalKey _keyFor(int index) =>
      _lineKeys.putIfAbsent(index, () => GlobalKey());

  void _onUserScroll() {
    _resumeTimer?.cancel();
    if (!_manualBrowse && mounted) {
      setState(() => _manualBrowse = true);
    }
    _resumeTimer = Timer(const Duration(milliseconds: 3500), () {
      if (!mounted) return;
      setState(() => _manualBrowse = false);
      if (_activeLineIndex >= 0) {
        _scrollToActiveLine(_activeLineIndex);
      }
    });
  }

  void _jumpToActiveLine() {
    _resumeTimer?.cancel();
    if (_manualBrowse && mounted) {
      setState(() => _manualBrowse = false);
    }
    if (_activeLineIndex >= 0) {
      _scrollToActiveLine(_activeLineIndex);
    }
  }

  void _scrollToActiveLine(int index) {
    if (!mounted || _manualBrowse || index < 0) return;
    final ctx = _lineKeys[index]?.currentContext;
    if (ctx == null) return;

    Scrollable.ensureVisible(
      ctx,
      alignment: 0.38,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );
  }

  Color _glowColor() {
    final base = PosterColor.of(
      widget.track.artwork,
      title: widget.track.albumTitle,
    );
    final hsl = HSLColor.fromColor(base);
    if (hsl.saturation < 0.08) {
      return const Color(0xAAFFFFFF);
    }
    return hsl
        .withSaturation((hsl.saturation * 1.15).clamp(0.45, 0.85))
        .withLightness(0.62)
        .toColor()
        .withOpacity(0.75);
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
          return _buildEdgeFade(
            child: SingleChildScrollView(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(
                vertical: Spacing.xl,
                horizontal: Spacing.xl,
              ),
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
            _scrollToActiveLine(_activeLineIndex);
          });
        }

        final glowColor = _glowColor();

        return LayoutBuilder(
          builder: (context, constraints) {
            final viewportHeight = constraints.maxHeight;
            final verticalPad = (viewportHeight * 0.36).clamp(48.0, 220.0);

            return Stack(
              children: [
                _buildEdgeFade(
                  child: NotificationListener<UserScrollNotification>(
                    onNotification: (notification) {
                      if (notification.direction != ScrollDirection.idle) {
                        _onUserScroll();
                      }
                      return false;
                    },
                    child: SingleChildScrollView(
                      controller: _scrollController,
                      padding: EdgeInsets.symmetric(
                        vertical: verticalPad,
                        horizontal: Spacing.lg,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (int index = 0;
                              index < lyrics.lines.length;
                              index++)
                            _LyricLineTile(
                              key: _keyFor(index),
                              line: lyrics.lines[index],
                              isActive: index == _activeLineIndex,
                              isPassed: index < _activeLineIndex,
                              glowColor: glowColor,
                              onTap: () {
                                sendCommand(
                                  ref,
                                  Seek(lyrics.lines[index].timestampMs),
                                );
                                _resumeTimer?.cancel();
                                if (_manualBrowse) {
                                  setState(() => _manualBrowse = false);
                                }
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_manualBrowse && _activeLineIndex >= 0)
                  Positioned(
                    right: Spacing.md,
                    bottom: Spacing.md,
                    child: _JumpToCurrentPill(
                      accentColor: glowColor,
                      onTap: _jumpToActiveLine,
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildEdgeFade({required Widget child}) => ShaderMask(
        shaderCallback: (bounds) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent,
          ],
          stops: [0.0, 0.11, 0.86, 1.0],
        ).createShader(bounds),
        blendMode: BlendMode.dstIn,
        child: child,
      );
}

class _LyricLineTile extends StatelessWidget {
  const _LyricLineTile({
    super.key,
    required this.line,
    required this.isActive,
    required this.isPassed,
    required this.glowColor,
    required this.onTap,
  });

  final LyricLine line;
  final bool isActive;
  final bool isPassed;
  final Color glowColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = line.text.trim();
    final isBreak = text.isEmpty;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: EdgeInsets.symmetric(
          vertical: isActive ? 12 : 9,
          horizontal: Spacing.sm,
        ),
        decoration: isActive
            ? BoxDecoration(
                color: Colors.white.withOpacity(0.06),
                borderRadius: BorderRadius.circular(14),
              )
            : null,
        alignment: Alignment.center,
        child: isBreak
            ? Text(
                '• • •',
                style: TextStyle(
                  color: isActive ? Colors.white70 : Colors.white24,
                  fontSize: 16,
                  letterSpacing: 6,
                ),
              )
            : AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isActive
                      ? Colors.white
                      : (isPassed ? Colors.white38 : Colors.white60),
                  fontSize: isActive ? 22 : 18,
                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                  height: 1.42,
                  shadows: isActive
                      ? [
                          Shadow(
                            color: glowColor,
                            blurRadius: 20,
                          ),
                        ]
                      : null,
                ),
                child: Text(line.text),
              ),
      ),
    );
  }
}

class _JumpToCurrentPill extends StatelessWidget {
  const _JumpToCurrentPill({
    required this.accentColor,
    required this.onTap,
  });

  final Color accentColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withOpacity(0.55),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: accentColor.withOpacity(0.65)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.my_location, size: 14, color: Colors.white),
              SizedBox(width: 5),
              Text(
                'Sync',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

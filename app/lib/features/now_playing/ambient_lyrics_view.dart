import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core_api/commands.dart';
import '../../core_api/models.dart';
import '../../providers/core_providers.dart';
import '../../theme/tokens.dart';
import '../../util/poster_color.dart';
import '../../widgets/artwork.dart';

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

  static String _formatSource(TrackLyrics lyrics) {
    final s = lyrics.source.trim().toLowerCase();
    if (s.contains('embed') || s.contains('tag')) return 'Embedded';
    if (s.contains('lrclib') || s.contains('net')) return 'LRCLIB';
    if (s.contains('cache') || s.contains('db') || s.contains('local')) {
      return 'Cached';
    }
    return lyrics.synced ? 'Synced' : 'Plain';
  }

  static String _formatOffset(int offsetMs) {
    if (offsetMs == 0) return '0.0s';
    final sec = offsetMs / 1000.0;
    final sign = offsetMs > 0 ? '+' : '';
    final formatted = (offsetMs % 500 == 0)
        ? sec.toStringAsFixed(1)
        : sec.toStringAsFixed(2);
    return '$sign${formatted}s';
  }

  void _adjustOffset(int deltaMs) {
    final current = ref.read(lyricsOffsetProvider(widget.track.id));
    final next = (current + deltaMs).clamp(-5000, 5000);
    ref.read(lyricsOffsetProvider(widget.track.id).notifier).state = next;
  }

  void _resetOffset() {
    ref.read(lyricsOffsetProvider(widget.track.id).notifier).state = 0;
  }

  void _refreshLyrics() {
    ref.invalidate(lyricsProvider(widget.track));
  }

  @override
  Widget build(BuildContext context) {
    final lyricsAsync = ref.watch(lyricsProvider(widget.track));
    final position = ref.watch(positionProvider).valueOrNull?.positionMs ?? 0;
    final offsetMs = ref.watch(lyricsOffsetProvider(widget.track.id));
    final effectivePosition = position + offsetMs;
    final isPlaying = ref.watch(playbackProvider).valueOrNull?.isPlaying ?? false;
    final glowColor = _glowColor();

    final body = lyricsAsync.when(
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
              const SizedBox(height: Spacing.md),
              OutlinedButton.icon(
                key: const Key('lyrics_retry_button'),
                onPressed: _refreshLyrics,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Re-search lyrics'),
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
                  const SizedBox(height: Spacing.md),
                  OutlinedButton.icon(
                    key: const Key('lyrics_retry_button'),
                    onPressed: _refreshLyrics,
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Re-search lyrics'),
                  ),
                ],
              ),
            ),
          );
        }

        final header = _LyricsHeaderBar(
          sourceLabel: _formatSource(lyrics),
          synced: lyrics.synced,
          offsetLabel: _formatOffset(offsetMs),
          offsetActive: offsetMs != 0,
          accentColor: glowColor,
          onDecreaseOffset: () => _adjustOffset(-250),
          onResetOffset: _resetOffset,
          onIncreaseOffset: () => _adjustOffset(250),
          onRefresh: _refreshLyrics,
        );

        if (!lyrics.synced) {
          return Column(
            children: [
              header,
              Expanded(
                child: _buildEdgeFade(
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                      vertical: Spacing.lg,
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
                ),
              ),
            ],
          );
        }

        int newActiveIndex = -1;
        for (int i = 0; i < lyrics.lines.length; i++) {
          if (lyrics.lines[i].timestampMs <= effectivePosition) {
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

        final showPreIntro = lyrics.lines.isNotEmpty &&
            effectivePosition < lyrics.lines.first.timestampMs &&
            lyrics.lines.first.timestampMs >= 2500;

        return Column(
          children: [
            header,
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final viewportHeight = constraints.maxHeight;
                  final verticalPad =
                      (viewportHeight * 0.36).clamp(48.0, 220.0);

                  return Stack(
                    children: [
                      _buildEdgeFade(
                        child: NotificationListener<UserScrollNotification>(
                          onNotification: (notification) {
                            if (notification.direction !=
                                ScrollDirection.idle) {
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
                                if (showPreIntro)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                        bottom: Spacing.md),
                                    child: _InstrumentalBreather(
                                      key: const Key(
                                          'lyrics_pre_intro_breather'),
                                      animate: isPlaying,
                                      color: glowColor,
                                    ),
                                  ),
                                for (int index = 0;
                                    index < lyrics.lines.length;
                                    index++)
                                  _LyricLineTile(
                                    key: _keyFor(index),
                                    line: lyrics.lines[index],
                                    isActive: index == _activeLineIndex,
                                    isPassed: index < _activeLineIndex,
                                    isPlaying: isPlaying,
                                    glowColor: glowColor,
                                    onTap: () {
                                      final maxMs = widget.track.durationMs > 0
                                          ? widget.track.durationMs
                                          : 1 << 30;
                                      final targetMs =
                                          (lyrics.lines[index].timestampMs -
                                                  offsetMs)
                                              .clamp(0, maxMs);
                                      sendCommand(ref, Seek(targetMs));
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
              ),
            ),
          ],
        );
      },
    );

    return _LyricsBackdropShell(
      track: widget.track,
      glowColor: glowColor,
      child: body,
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

class _LyricsHeaderBar extends StatelessWidget {
  const _LyricsHeaderBar({
    required this.sourceLabel,
    required this.synced,
    required this.offsetLabel,
    required this.offsetActive,
    required this.accentColor,
    required this.onDecreaseOffset,
    required this.onResetOffset,
    required this.onIncreaseOffset,
    required this.onRefresh,
  });

  final String sourceLabel;
  final bool synced;
  final String offsetLabel;
  final bool offsetActive;
  final Color accentColor;
  final VoidCallback onDecreaseOffset;
  final VoidCallback onResetOffset;
  final VoidCallback onIncreaseOffset;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          Spacing.sm, Spacing.xs, Spacing.xs, 0),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withOpacity(0.14)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  synced ? Icons.graphic_eq : Icons.notes_rounded,
                  size: 11,
                  color: synced ? accentColor : Colors.white60,
                ),
                const SizedBox(width: 4),
                Text(
                  sourceLabel,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          if (synced) ...[
            Container(
              decoration: BoxDecoration(
                color: offsetActive
                    ? accentColor.withOpacity(0.18)
                    : Colors.white.withOpacity(0.07),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: offsetActive
                      ? accentColor.withOpacity(0.5)
                      : Colors.white.withOpacity(0.12),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  InkWell(
                    key: const Key('lyrics_offset_minus'),
                    onTap: onDecreaseOffset,
                    borderRadius: const BorderRadius.horizontal(
                      left: Radius.circular(14),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                      child: Icon(Icons.remove, size: 13, color: Colors.white70),
                    ),
                  ),
                  InkWell(
                    key: const Key('lyrics_offset_value'),
                    onTap: onResetOffset,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 4),
                      child: Text(
                        offsetLabel,
                        style: TextStyle(
                          color: offsetActive ? Colors.white : Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  InkWell(
                    key: const Key('lyrics_offset_plus'),
                    onTap: onIncreaseOffset,
                    borderRadius: const BorderRadius.horizontal(
                      right: Radius.circular(14),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                      child: Icon(Icons.add, size: 13, color: Colors.white70),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
          ],
          IconButton(
            key: const Key('lyrics_refresh_button'),
            tooltip: 'Re-search lyrics',
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh_rounded,
                size: 16, color: Colors.white70),
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(6),
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
  }
}

class _LyricsBackdropShell extends StatelessWidget {
  const _LyricsBackdropShell({
    required this.track,
    required this.glowColor,
    required this.child,
  });

  final Track track;
  final Color glowColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: Radii.heroArtR,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF0B0E14),
          borderRadius: Radii.heroArtR,
          border: Border.all(color: glowColor.withOpacity(0.20)),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ExcludeSemantics(
              child: Opacity(
                opacity: 0.28,
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: AlbumArtwork(
                      artwork: track.artwork,
                      size: 280,
                      title: track.albumTitle,
                      borderRadius: BorderRadius.zero,
                    ),
                  ),
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, -0.25),
                  radius: 1.15,
                  colors: [
                    glowColor.withOpacity(0.16),
                    Colors.black.withOpacity(0.55),
                    Colors.black.withOpacity(0.82),
                  ],
                  stops: const [0.0, 0.55, 1.0],
                ),
              ),
            ),
            child,
          ],
        ),
      ),
    );
  }
}

class _LyricLineTile extends StatelessWidget {
  const _LyricLineTile({
    super.key,
    required this.line,
    required this.isActive,
    required this.isPassed,
    required this.isPlaying,
    required this.glowColor,
    required this.onTap,
  });

  final LyricLine line;
  final bool isActive;
  final bool isPassed;
  final bool isPlaying;
  final Color glowColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = line.text.trim();
    final isBreak = text.isEmpty || text == '♪' || text == '•••';

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
            ? _InstrumentalBreather(
                key: const Key('lyrics_break_breather'),
                animate: isActive && isPlaying,
                color: isActive ? glowColor : Colors.white24,
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

class _InstrumentalBreather extends StatefulWidget {
  const _InstrumentalBreather({
    super.key,
    required this.animate,
    required this.color,
  });

  final bool animate;
  final Color color;

  @override
  State<_InstrumentalBreather> createState() => _InstrumentalBreatherState();
}

class _InstrumentalBreatherState extends State<_InstrumentalBreather>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant _InstrumentalBreather oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.animate && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int i = 0; i < 3; i++)
              Builder(builder: (_) {
                final phase =
                    (_controller.value * 2 * math.pi) - (i * math.pi / 2.2);
                final pulse = widget.animate
                    ? (0.55 + 0.45 * math.sin(phase)).clamp(0.25, 1.0)
                    : 0.7;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Transform.scale(
                    scale: 0.8 + 0.35 * pulse,
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: widget.color.withOpacity(pulse),
                      ),
                    ),
                  ),
                );
              }),
          ],
        );
      },
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

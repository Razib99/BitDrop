import 'dart:ui' show lerpDouble;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core_api/commands.dart';
import '../core_api/enums.dart';
import '../core_api/models.dart';
import '../features/now_playing/now_playing_screen.dart';
import '../l10n/l10n.dart';
import '../providers/core_providers.dart';
import '../providers/player_sheet_provider.dart';
import '../routing/routes.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../util/poster_color.dart';
import 'artwork.dart';
import 'cache_seek_bar.dart';
import 'indicators.dart';
import 'transport.dart';

/// The persistent, morphing expanding player sheet.
///
/// Unifies the mini player and full Now Playing window into a single continuous
/// interactive sheet.
///
/// Organized in 3 strict choreography phases:
/// - Phase 1 (0.0 to 0.18): Mini controls cleanly slide down 8 dp and dissolve.
/// - Phase 2 (0.18 to 0.70): Hero artwork glides along a smooth cubic curve and
///   scales into position with ambient background expansion. Zero UI clutter.
/// - Phase 3 (0.55 to 1.0): Full screen controls stagger into place from top
///   and bottom without squashing.
class ExpandingPlayerSheet extends ConsumerWidget {
  const ExpandingPlayerSheet({
    super.key,
    required this.isHome,
    required this.useRail,
  });

  final bool isHome;
  final bool useRail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final np = ref.watch(nowPlayingProvider).valueOrNull;
    final controller = ref.watch(playerSheetControllerProvider);
    final p = controller.progress;

    if (np == null) {
      return const Positioned(
        left: 0,
        bottom: 0,
        width: 0,
        height: 0,
        child: SizedBox.shrink(),
      );
    }

    // When on Home screen and fully collapsed, the sheet is hidden so the
    // "Continue Listening" card in the feed takes pride of place.
    if (isHome && controller.isCollapsed) {
      return const Positioned(
        left: 0,
        bottom: 0,
        width: 0,
        height: 0,
        child: SizedBox.shrink(),
      );
    }

    final screenHeight = MediaQuery.sizeOf(context).height;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final topSafeArea = MediaQuery.paddingOf(context).top;
    final bottomSafeArea = MediaQuery.paddingOf(context).bottom;

    // Mobile nav bar height including safe area
    final navBarHeight = useRail ? 0.0 : (80.0 + bottomSafeArea);

    // Compute sheet height and bottom offset
    const miniHeight = Sizes.miniPlayerHeight;
    final fullHeight = screenHeight;

    final double currentHeight;
    final double bottomOffset;

    if (isHome) {
      // On Home, expands from bottom: 0 up to full screen
      currentHeight = lerpDouble(0.0, fullHeight, p)!;
      bottomOffset = 0.0;
    } else {
      // On Library/Search/Sources, sits above navigation bar when collapsed,
      // and slides down to bottom: 0 when expanded
      currentHeight = lerpDouble(miniHeight, fullHeight, p)!;
      bottomOffset = lerpDouble(navBarHeight, 0.0, p)!;
    }

    if (currentHeight <= 0.001) {
      return const Positioned(
        left: 0,
        bottom: 0,
        width: 0,
        height: 0,
        child: SizedBox.shrink(),
      );
    }

    final c = context.c;
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Positioned(
      left: 0,
      right: 0,
      bottom: bottomOffset,
      height: currentHeight,
      child: PopScope(
        canPop: controller.isCollapsed,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && !controller.isCollapsed) {
            controller.collapse();
          }
        },
        child: FutureBuilder<Color>(
          future: PosterColor.resolve(np.track.artwork, title: np.track.albumTitle),
          initialData: PosterColor.of(np.track.artwork, title: np.track.albumTitle),
          builder: (context, snapshot) {
            final posterColor = snapshot.data ??
                PosterColor.of(np.track.artwork, title: np.track.albumTitle);

            final topColor = Color.lerp(posterColor, c.bg, dark ? 0.38 : 0.20)!;
            final midColor = Color.lerp(posterColor, c.bg, dark ? 0.72 : 0.60)!;

            final sheetRadius = Radius.circular(lerpDouble(16.0, 0.0, p)!);

            return Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.vertical(top: sheetRadius),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.35 + 0.25 * p),
                    blurRadius: 16.0 + 24.0 * p,
                    offset: Offset(0, -2.0 - 4.0 * p),
                  ),
                ],
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color.lerp(c.surface2, topColor, p)!,
                    Color.lerp(c.surface2, midColor, p)!,
                    c.bg,
                    c.bg,
                  ],
                  stops: const [0.0, 0.42, 0.78, 1.0],
                ),
              ),
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragUpdate: (details) {
                  final deltaY = details.primaryDelta ?? 0.0;
                  final totalDrag = fullHeight - miniHeight;
                  if (totalDrag > 0) {
                    controller.setProgress(controller.progress - (deltaY / totalDrag));
                  }
                },
                onVerticalDragEnd: (details) {
                  final velocity = details.primaryVelocity ?? 0.0;
                  controller.settle(velocity);
                },
                onTap: p < 0.2 ? () => controller.expand() : null,
                child: Stack(
                  children: [
                    // Top hairline subtle highlight
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: 1,
                      child: Container(
                        color: Colors.white.withOpacity(0.12 * (1.0 - p * 0.5)),
                      ),
                    ),

                    // Top pull handle (centered, visible during full or drag)
                    if (p > 0.08)
                      Positioned(
                        top: topSafeArea > 0 ? (topSafeArea * (1.0 - p) + 8.0) : 8.0,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Container(
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.28 * p),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),

                    // ========================================================
                    // PHASE 1: MINI PLAYER BAR (0.0 to 0.18)
                    // ========================================================
                    if (p < 0.25)
                      _MiniBarLayer(
                        nowPlaying: np,
                        progress: p,
                      ),

                    // ========================================================
                    // PHASE 3: FULL PLAYER CONTROLS (0.55 to 1.0)
                    // ========================================================
                    if (p > 0.50)
                      _FullPlayerLayer(
                        nowPlaying: np,
                        progress: p,
                        topSafeArea: topSafeArea,
                        bottomSafeArea: bottomSafeArea,
                        onCollapse: () => controller.collapse(),
                      ),

                    // ========================================================
                    // PHASE 2: HERO ALBUM ARTWORK (0.0 to 1.0 continuous morph)
                    // ========================================================
                    _MorphingArtwork(
                      nowPlaying: np,
                      progress: p,
                      screenWidth: screenWidth,
                      topSafeArea: topSafeArea,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Mini Player row displayed when the sheet is collapsed.
/// Fades out completely by progress = 0.18.
class _MiniBarLayer extends ConsumerWidget {
  const _MiniBarLayer({
    required this.nowPlaying,
    required this.progress,
  });

  final NowPlaying nowPlaying;
  final double progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exitProgress = (progress / 0.18).clamp(0.0, 1.0);
    final opacity = (1.0 - exitProgress);
    final translateY = exitProgress * 8.0;

    final c = context.c;
    final playback =
        ref.watch(playbackProvider).valueOrNull ?? const IdleState();
    final signal = ref.watch(signalPathProvider).valueOrNull;
    final isPlaying = playback is PlayingState;
    final isBusy = playback is BufferingState || playback is LoadingState;

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: Sizes.miniPlayerHeight,
      child: IgnorePointer(
        ignoring: progress > 0.15,
        child: Opacity(
          opacity: opacity,
          child: Transform.translate(
            offset: Offset(0, translateY),
            child: Dismissible(
              key: ValueKey('mini-morph-${nowPlaying.track.id}'),
              direction: DismissDirection.horizontal,
              confirmDismiss: (dir) async {
                sendCommand(
                  ref,
                  dir == DismissDirection.startToEnd
                      ? const Previous()
                      : const Next(),
                );
                return false;
              },
              child: Stack(
                children: [
                  // Mini Progress Line at top
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Opacity(
                      opacity: (1.0 - (progress / 0.08)).clamp(0.0, 1.0),
                      child: const MiniProgressLine(),
                    ),
                  ),

                  // Mini Content Row
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
                    child: Row(
                      children: [
                        // Space reserved for the morphing artwork anchor
                        const SizedBox(width: 44),
                        const SizedBox(width: Spacing.sm),

                        // Title & Artist Column
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                nowPlaying.track.title,
                                style: context.t.bodySmall.copyWith(
                                  fontWeight: FontWeight.w500,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 1),
                              Row(
                                children: [
                                  if (signal != null)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 5),
                                      child: _TierDot(tier: signal.tier),
                                    ),
                                  Expanded(
                                    child: Text(
                                      nowPlaying.track.artist,
                                      style: context.t.label
                                          .copyWith(color: c.textSecondary),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (signal?.dspActive ?? false)
                                    const Padding(
                                      padding: EdgeInsets.only(left: 4),
                                      child: DspBadge(dense: true),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),

                        // Mini Transport Controls
                        IconButton(
                          onPressed: () {
                            HapticFeedback.selectionClick();
                            sendCommand(ref, const Previous());
                          },
                          icon: const Icon(Icons.skip_previous_rounded),
                          iconSize: 22,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.all(Spacing.xs),
                          tooltip: context.l10n.actionPrevious,
                        ),
                        IconButton(
                          onPressed: () {
                            HapticFeedback.mediumImpact();
                            sendCommand(ref,
                                isPlaying ? const Pause() : const Resume());
                          },
                          icon: isBusy
                              ? Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: c.accent,
                                        backgroundColor: c.outline,
                                      ),
                                    ),
                                    Icon(
                                      isPlaying
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                      size: 13,
                                      color: c.accent,
                                    ),
                                  ],
                                )
                              : Icon(
                                  isPlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                ),
                          iconSize: 28,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.all(Spacing.xs),
                          tooltip: isPlaying
                              ? context.l10n.actionPause
                              : context.l10n.actionPlay,
                        ),
                        IconButton(
                          onPressed: () {
                            HapticFeedback.selectionClick();
                            sendCommand(ref, const Next());
                          },
                          icon: const Icon(Icons.skip_next_rounded),
                          iconSize: 22,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.all(Spacing.xs),
                          tooltip: context.l10n.actionNext,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Hero Album Artwork that scales, floats, and morphs seamlessly between
/// mini (44 dp) and full hero (280+ dp) size.
class _MorphingArtwork extends ConsumerWidget {
  const _MorphingArtwork({
    required this.nowPlaying,
    required this.progress,
    required this.screenWidth,
    required this.topSafeArea,
  });

  final NowPlaying nowPlaying;
  final double progress;
  final double screenWidth;
  final double topSafeArea;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artEase = Curves.easeOutCubic.transform(progress);

    final heroSize = (screenWidth - Spacing.xl * 2).clamp(180.0, 320.0);

    // Mini coordinates
    const miniLeft = 12.0;
    const miniTop = 10.0;
    const miniSize = 44.0;
    const miniRadius = 8.0;

    // Full hero coordinates
    final fullLeft = (screenWidth - heroSize) / 2;
    final fullTop = topSafeArea + 56.0;
    const fullRadius = Radii.heroArt;

    final curLeft = lerpDouble(miniLeft, fullLeft, artEase)!;
    final curTop = lerpDouble(miniTop, fullTop, artEase)!;
    final curSize = lerpDouble(miniSize, heroSize, artEase)!;
    final curRadius = lerpDouble(miniRadius, fullRadius, progress)!;

    final shadowBlur = lerpDouble(6.0, 36.0, progress)!;
    final shadowY = lerpDouble(2.0, 16.0, progress)!;
    final shadowAlpha = lerpDouble(0.35, 0.48, progress)!;

    return Positioned(
      left: curLeft,
      top: curTop,
      width: curSize,
      height: curSize,
      child: GestureDetector(
        onHorizontalDragEnd: progress > 0.8
            ? (d) {
                final v = d.primaryVelocity ?? 0;
                if (v < -180) {
                  sendCommand(ref, const Next());
                } else if (v > 180) {
                  sendCommand(ref, const Previous());
                }
              }
            : null,
        onLongPress: progress > 0.8
            ? () => context.push(Routes.album(nowPlaying.track.albumId))
            : null,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(curRadius),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(shadowAlpha),
                blurRadius: shadowBlur,
                offset: Offset(0, shadowY),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(curRadius),
            child: AlbumArtwork(
              artwork: nowPlaying.track.artwork,
              size: curSize,
              title: nowPlaying.track.albumTitle,
              borderRadius: BorderRadius.circular(curRadius),
            ),
          ),
        ),
      ),
    );
  }
}

/// Full screen player controls, entering with disciplined staggered choreography.
class _FullPlayerLayer extends ConsumerWidget {
  const _FullPlayerLayer({
    required this.nowPlaying,
    required this.progress,
    required this.topSafeArea,
    required this.bottomSafeArea,
    required this.onCollapse,
  });

  final NowPlaying nowPlaying;
  final double progress;
  final double topSafeArea;
  final double bottomSafeArea;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signal = ref.watch(signalPathProvider).valueOrNull;

    // Phase 3 Sub-element interval curves
    // Top Bar (0.60 to 0.92)
    final topP = ((progress - 0.60) / 0.32).clamp(0.0, 1.0);

    // Title Row (0.55 to 0.85)
    final titleP = ((progress - 0.55) / 0.30).clamp(0.0, 1.0);

    // Signal Chip (0.62 to 0.90)
    final signalP = ((progress - 0.62) / 0.28).clamp(0.0, 1.0);

    // Seek Bar (0.68 to 0.94)
    final seekP = ((progress - 0.68) / 0.26).clamp(0.0, 1.0);

    // Transport (0.72 to 0.98)
    final transportP = ((progress - 0.72) / 0.26).clamp(0.0, 1.0);
    final transportScale = 0.88 + 0.12 * transportP;

    // Bottom Actions (0.80 to 1.0)
    final actionsP = ((progress - 0.80) / 0.20).clamp(0.0, 1.0);

    return Stack(
      children: [
        // Top Bar (Collapse button, playing from context, menu)
        Positioned(
          top: topSafeArea,
          left: 0,
          right: 0,
          child: Opacity(
            opacity: topP,
            child: Transform.translate(
              offset: Offset(0, (1.0 - topP) * -16.0),
              child: IgnorePointer(
                ignoring: topP < 0.8,
                child: NowPlayingTopBar(
                  nowPlaying: nowPlaying,
                  onCollapse: onCollapse,
                ),
              ),
            ),
          ),
        ),

        // Bottom Controls Region (Anchored to bottom, zero squash!)
        Positioned(
          left: 0,
          right: 0,
          bottom: bottomSafeArea + 8.0,
          child: IgnorePointer(
            ignoring: progress < 0.75,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Track Title & Favorite
                Opacity(
                  opacity: titleP,
                  child: Transform.translate(
                    offset: Offset(0, (1.0 - titleP) * 16.0),
                    child: NowPlayingTitleBlock(nowPlaying: nowPlaying),
                  ),
                ),
                const SizedBox(height: Spacing.xs),

                // Bit-Perfect Signal Chip
                if (signal != null)
                  Opacity(
                    opacity: signalP,
                    child: Transform.translate(
                      offset: Offset(0, (1.0 - signalP) * 14.0),
                      child: NowPlayingSignalChip(signal: signal),
                    ),
                  ),
                const SizedBox(height: Spacing.sm),

                // Frosted White Seek Bar
                Opacity(
                  opacity: seekP,
                  child: Transform.translate(
                    offset: Offset(0, (1.0 - seekP) * 12.0),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Spacing.xl),
                      child: CacheSeekBar(
                        durationMs: nowPlaying.track.durationMs,
                        activeColor: const Color(0xFFF1F5F9),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: Spacing.xs),

                // Volume Hint
                const NowPlayingVolumeHint(),
                const SizedBox(height: Spacing.xs),

                // Transport Controls with Frosted White Play Button
                Opacity(
                  opacity: transportP,
                  child: Transform.scale(
                    scale: transportScale,
                    child: Transform.translate(
                      offset: Offset(0, (1.0 - transportP) * 14.0),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: Spacing.md),
                        child: TransportControls(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: Spacing.xs),

                // Bottom Action Pills (Queue, EQ, Output, Lyrics, More)
                Opacity(
                  opacity: actionsP,
                  child: Transform.translate(
                    offset: Offset(0, (1.0 - actionsP) * 10.0),
                    child: NowPlayingBottomActions(nowPlaying: nowPlaying),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TierDot extends StatelessWidget {
  const _TierDot({required this.tier});

  final OutputTier tier;

  @override
  Widget build(BuildContext context) {
    final color = TierChip.colorFor(context, tier);
    return Semantics(
      label: context.l10n.outputIs(tier.label),
      excludeSemantics: true,
      child: Icon(TierChip.iconFor(tier), size: 11, color: color),
    );
  }
}

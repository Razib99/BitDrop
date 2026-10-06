import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core_api/commands.dart';
import '../core_api/enums.dart';
import '../core_api/models.dart';
import '../providers/core_providers.dart';
import '../routing/routes.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../l10n/l10n.dart';
import 'artwork.dart';
import 'cache_seek_bar.dart';
import 'indicators.dart';

/// 64 dp bar docked above the navigation bar whenever something is loaded.
///
/// Swipe sideways to skip, tap or swipe up to expand into Now Playing,
/// long-press for the output device. The tier dot carries colour **and** shape,
/// so it reads without colour vision.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final np = ref.watch(nowPlayingProvider).valueOrNull;
    if (np == null) return const SizedBox.shrink();

    final c = context.c;
    final playback =
        ref.watch(playbackProvider).valueOrNull ?? const IdleState();
    final signal = ref.watch(signalPathProvider).valueOrNull;
    final isPlaying = playback is PlayingState;

    return Material(
      color: c.surface2,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MiniProgressLine(),
          Dismissible(
            key: ValueKey('mini-${np.track.id}'),
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
            background: const _SkipHint(
              icon: Icons.skip_previous,
              alignment: Alignment.centerLeft,
            ),
            secondaryBackground: const _SkipHint(
              icon: Icons.skip_next,
              alignment: Alignment.centerRight,
            ),
            child: GestureDetector(
              onVerticalDragEnd: (d) {
                if ((d.primaryVelocity ?? 0) < -120) {
                  context.push(Routes.nowPlaying);
                }
              },
              child: InkWell(
                onTap: () => context.push(Routes.nowPlaying),
                onLongPress: () => context.push(Routes.output),
                child: SizedBox(
                  height: Sizes.miniPlayerHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
                    child: Row(
                      children: [
                        Hero(
                          tag: 'art-${np.track.albumId}',
                          child: AlbumArtwork(
                            artwork: np.track.artwork,
                            size: 44,
                            title: np.track.albumTitle,
                          ),
                        ),
                        const SizedBox(width: Spacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                np.track.title,
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
                                      np.track.artist,
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
                        if (playback is BufferingState)
                          Padding(
                            padding: const EdgeInsets.only(right: Spacing.xs),
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: c.accent,
                                backgroundColor: c.outline,
                              ),
                            ),
                          ),
                        IconButton(
                          onPressed: () {
                            HapticFeedback.mediumImpact();
                            sendCommand(ref,
                                isPlaying ? const Pause() : const Resume());
                          },
                          icon:
                              Icon(isPlaying ? Icons.pause : Icons.play_arrow),
                          iconSize: 28,
                          tooltip: isPlaying
                              ? context.l10n.actionPause
                              : context.l10n.actionPlay,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Tier as colour **plus** shape: diamond, circle, triangle, question mark.
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

class _SkipHint extends StatelessWidget {
  const _SkipHint({required this.icon, required this.alignment});

  final IconData icon;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) => Container(
        color: context.c.surface3,
        alignment: alignment,
        padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
        child: Icon(icon, color: context.c.accent),
      );
}

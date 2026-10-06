import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core_api/commands.dart';
import '../core_api/enums.dart';
import '../core_api/models.dart';
import '../providers/core_providers.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../l10n/l10n.dart';

/// Shuffle · previous · play/pause · next · repeat.
///
/// The play button becomes a progress ring while loading or buffering, so a
/// stall is never a dead button.
class TransportControls extends ConsumerWidget {
  const TransportControls({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(playbackProvider).valueOrNull ?? const IdleState();
    final queue = ref.watch(queueProvider).valueOrNull ?? QueueState.empty;
    final size = compact ? 56.0 : Sizes.playButton;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _ToggleIcon(
          icon: Icons.shuffle,
          active: queue.shuffle,
          tooltip: queue.shuffle
              ? context.l10n.shuffleOn
              : context.l10n.shuffleOff,
          onTap: () => sendCommand(ref, SetShuffle(!queue.shuffle)),
        ),
        IconButton(
          onPressed: () {
            HapticFeedback.selectionClick();
            sendCommand(ref, const Previous());
          },
          icon: const Icon(Icons.skip_previous),
          iconSize: compact ? 28 : 34,
          tooltip: context.l10n.actionPrevious,
        ),
        _PlayButton(playback: playback, size: size),
        IconButton(
          onPressed: () {
            HapticFeedback.selectionClick();
            sendCommand(ref, const Next());
          },
          icon: const Icon(Icons.skip_next),
          iconSize: compact ? 28 : 34,
          tooltip: context.l10n.actionNext,
        ),
        _ToggleIcon(
          icon: queue.repeat == RepeatMode.one
              ? Icons.repeat_one
              : Icons.repeat,
          active: queue.repeat != RepeatMode.off,
          tooltip: switch (queue.repeat) {
            RepeatMode.off => context.l10n.repeatOff,
            RepeatMode.all => context.l10n.repeatAll,
            RepeatMode.one => context.l10n.repeatOne,
          },
          onTap: () => sendCommand(
            ref,
            SetRepeat(switch (queue.repeat) {
              RepeatMode.off => RepeatMode.all,
              RepeatMode.all => RepeatMode.one,
              RepeatMode.one => RepeatMode.off,
            }),
          ),
        ),
      ],
    );
  }
}

class _PlayButton extends ConsumerWidget {
  const _PlayButton({required this.playback, required this.size});

  final PlaybackState playback;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final state = playback;
    final isPlaying = state is PlayingState;
    final busy = state.isBusy;

    final double? progress = state is BufferingState && state.targetMs > 0
        ? (state.bufferedMs / state.targetMs).clamp(0.0, 1.0)
        : null;

    return Semantics(
      button: true,
      label: busy
          ? context.l10n.bufferingLabel
          : (isPlaying ? context.l10n.actionPause : context.l10n.actionPlay),
      excludeSemantics: true,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (busy)
              SizedBox(
                width: size,
                height: size,
                child: CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 3,
                  color: c.accent,
                  backgroundColor: c.outline,
                ),
              ),
            Material(
              color: c.accent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () {
                  HapticFeedback.mediumImpact();
                  sendCommand(ref, isPlaying ? const Pause() : const Resume());
                },
                child: SizedBox(
                  width: size - (busy ? 10 : 0),
                  height: size - (busy ? 10 : 0),
                  child: Icon(
                    isPlaying ? Icons.pause : Icons.play_arrow,
                    color: c.onAccent,
                    size: (size - (busy ? 10 : 0)) * 0.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToggleIcon extends StatelessWidget {
  const _ToggleIcon({
    required this.icon,
    required this.active,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final bool active;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon),
      iconSize: 22,
      tooltip: tooltip,
      color: active ? c.accent : c.textSecondary,
    );
  }
}

/// Small circular action used in the Now Playing bottom row.
class ActionPill extends StatelessWidget {
  const ActionPill({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.dot = false,
    this.badge,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Pink dot: something in this stage is altering the audio.
  final bool dot;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      button: true,
      label: dot ? '$label, active' : label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: Radii.chipR,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: Spacing.xs, vertical: Spacing.xs),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(icon, size: 22, color: c.textSecondary),
                  if (dot)
                    Positioned(
                      right: -2,
                      top: -2,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: c.dspActive,
                          shape: BoxShape.circle,
                          border: Border.all(color: c.bg, width: 1.5),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                badge ?? label,
                style: context.t.monoLabel.copyWith(color: c.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

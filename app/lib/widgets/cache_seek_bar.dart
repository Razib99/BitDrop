import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core_api/commands.dart';
import '../core_api/models.dart';
import '../providers/core_providers.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../util/format.dart';

/// The cache-aware seek bar.
///
/// Three layers on one track: **played** (accent), **cached on disk**
/// (`cacheFill`, which can be several separate ranges after seeks) and
/// **not yet fetched** (outline). Scrubbing shows a bubble that says whether
/// that point is already on disk or will have to stream.
///
/// This widget is the *only* place that subscribes to [positionProvider], so a
/// 30 Hz position tick repaints this subtree and nothing else.
class CacheSeekBar extends ConsumerStatefulWidget {
  const CacheSeekBar({super.key, required this.durationMs});

  final int durationMs;

  @override
  ConsumerState<CacheSeekBar> createState() => _CacheSeekBarState();
}

class _CacheSeekBarState extends ConsumerState<CacheSeekBar> {
  double? _dragFraction;
  bool _showRemaining = true;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final info = ref.watch(positionProvider).valueOrNull ?? PositionInfo.empty;
    final playback = ref.watch(playbackProvider).valueOrNull;
    final buffering = playback is BufferingState ? playback : null;

    final duration = widget.durationMs > 0 ? widget.durationMs : info.durationMs;
    final liveFraction = duration <= 0
        ? 0.0
        : (info.positionMs / duration).clamp(0.0, 1.0);
    final fraction = _dragFraction ?? liveFraction;
    final scrubMs = (fraction * duration).round();
    final willStream = !info.isCachedAt(scrubMs);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Scrub bubble sits above the track so it never hides the thumb.
        SizedBox(
          height: 26,
          child: _dragFraction == null
              ? null
              : LayoutBuilder(
                  builder: (context, box) {
                    final x = (fraction * box.maxWidth)
                        .clamp(42.0, math.max(42.0, box.maxWidth - 42));
                    return Stack(
                      children: [
                        Positioned(
                          left: x - 42,
                          child: _ScrubBubble(
                            time: Fmt.duration(scrubMs),
                            cached: !willStream,
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
        Semantics(
          slider: true,
          label: 'Playback position',
          value: '${Fmt.duration(scrubMs)} of ${Fmt.duration(duration)}'
              '${willStream ? ', will stream' : ', cached'}',
          onIncrease: () => _seekBy(10000, duration),
          onDecrease: () => _seekBy(-10000, duration),
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (d) => _updateDrag(d.localPosition.dx, context),
            onHorizontalDragUpdate: (d) => _updateDrag(d.localPosition.dx, context),
            onHorizontalDragEnd: (_) => _commitDrag(duration),
            onTapDown: (d) => _updateDrag(d.localPosition.dx, context),
            onTapUp: (_) => _commitDrag(duration),
            child: SizedBox(
              height: 28,
              width: double.infinity,
              child: CustomPaint(
                painter: _SeekPainter(
                  fraction: fraction,
                  durationMs: duration,
                  ranges: info.cachedRanges,
                  played: c.accent,
                  cached: c.cacheFill,
                  track: c.outline,
                  thumb: c.accent,
                  dragging: _dragFraction != null,
                  pulse: buffering != null,
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: Spacing.xxs),
          child: Row(
            children: [
              Text(
                Fmt.duration(_dragFraction != null ? scrubMs : info.positionMs),
                style: context.t.monoReadout.copyWith(color: c.textSecondary),
              ),
              const Spacer(),
              if (buffering != null)
                Flexible(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.downloading, size: 13, color: c.textSecondary),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          'Buffering · '
                          '${(buffering.bufferedMs / 1000).toStringAsFixed(1)} s '
                          'of ${(buffering.targetMs / 1000).toStringAsFixed(0)} s',
                          style: context.t.monoLabel
                              .copyWith(color: c.textSecondary),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                )
              else if (info.bufferAheadMs > 0 && info.bufferAheadMs < 6000)
                Text(
                  'Buffer ${(info.bufferAheadMs / 1000).toStringAsFixed(1)} s',
                  style: context.t.monoLabel.copyWith(color: c.textSecondary),
                ),
              const Spacer(),
              // Tapping the end time toggles total/remaining.
              InkWell(
                onTap: () => setState(() => _showRemaining = !_showRemaining),
                borderRadius: Radii.badgeR,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Semantics(
                    button: true,
                    label: _showRemaining
                        ? 'Remaining time. Tap for total duration.'
                        : 'Total duration. Tap for remaining time.',
                    excludeSemantics: true,
                    child: Text(
                      _showRemaining
                          ? Fmt.remaining(
                              _dragFraction != null ? scrubMs : info.positionMs,
                              duration,
                            )
                          : Fmt.duration(duration),
                      style: context.t.monoReadout
                          .copyWith(color: c.textSecondary),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _updateDrag(double dx, BuildContext context) {
    final width = context.size?.width ?? 1;
    setState(() => _dragFraction = (dx / width).clamp(0.0, 1.0));
  }

  void _commitDrag(int duration) {
    final f = _dragFraction;
    if (f == null) return;
    final target = (f * duration).round();
    // Haptic tick when the scrub lands outside the cached region, so the user
    // feels the "this will stream" boundary.
    final info = ref.read(positionProvider).valueOrNull;
    if (info != null && !info.isCachedAt(target)) {
      HapticFeedback.selectionClick();
    }
    sendCommand(ref, Seek(target));
    setState(() => _dragFraction = null);
  }

  void _seekBy(int deltaMs, int duration) {
    final info = ref.read(positionProvider).valueOrNull;
    final from = info?.positionMs ?? 0;
    sendCommand(ref, Seek((from + deltaMs).clamp(0, duration)));
  }
}

class _ScrubBubble extends StatelessWidget {
  const _ScrubBubble({required this.time, required this.cached});

  final String time;
  final bool cached;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: Spacing.xs, vertical: 3),
      decoration: BoxDecoration(
        color: c.surface3,
        borderRadius: Radii.badgeR,
        border: Border.all(color: c.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            cached ? Icons.download_done : Icons.cloud_download_outlined,
            size: 11,
            color: cached ? c.success : c.textSecondary,
          ),
          const SizedBox(width: 4),
          Text(time, style: context.t.monoLabel),
          Text(
            cached ? ' · Cached' : ' · Will stream',
            style: context.t.monoLabel.copyWith(
              color: cached ? c.success : c.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _SeekPainter extends CustomPainter {
  _SeekPainter({
    required this.fraction,
    required this.durationMs,
    required this.ranges,
    required this.played,
    required this.cached,
    required this.track,
    required this.thumb,
    required this.dragging,
    required this.pulse,
  });

  final double fraction;
  final int durationMs;
  final List<CachedRange> ranges;
  final Color played;
  final Color cached;
  final Color track;
  final Color thumb;
  final bool dragging;
  final bool pulse;

  @override
  void paint(Canvas canvas, Size size) {
    const h = Sizes.seekBarTrack;
    final y = (size.height - h) / 2;
    const radius = Radius.circular(h / 2);

    // Layer 1: not yet fetched.
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(0, y, size.width, h), radius),
      Paint()..color = track,
    );

    // Layer 2: cached byte ranges — drawn individually so gaps stay visible.
    if (durationMs > 0) {
      final paint = Paint()..color = cached;
      for (final r in ranges) {
        final left = (r.startMs / durationMs).clamp(0.0, 1.0) * size.width;
        final right = (r.endMs / durationMs).clamp(0.0, 1.0) * size.width;
        if (right - left < 0.5) continue;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTRB(left, y, right, y + h), radius),
          paint,
        );
      }
    }

    // Layer 3: played.
    final playedW = (fraction.clamp(0.0, 1.0)) * size.width;
    if (playedW > 0.5) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(0, y, playedW, h), radius),
        Paint()..color = played,
      );
    }

    // Thumb. Grows while dragging; a halo marks a buffering stall.
    final cx = playedW.clamp(0.0, size.width);
    final cy = size.height / 2;
    if (pulse) {
      canvas.drawCircle(
        Offset(cx, cy),
        dragging ? 14 : 11,
        Paint()..color = played.withOpacity(0.22),
      );
    }
    canvas.drawCircle(Offset(cx, cy), dragging ? 9 : 7, Paint()..color = thumb);
  }

  @override
  bool shouldRepaint(_SeekPainter old) =>
      old.fraction != fraction ||
      old.ranges != ranges ||
      old.dragging != dragging ||
      old.pulse != pulse ||
      old.durationMs != durationMs;
}

/// The 2 dp line on top of the mini player: played plus buffered.
class MiniProgressLine extends ConsumerWidget {
  const MiniProgressLine({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final info = ref.watch(positionProvider).valueOrNull ?? PositionInfo.empty;
    final duration = info.durationMs;
    final played = duration <= 0 ? 0.0 : info.positionMs / duration;
    final buffered = duration <= 0
        ? 0.0
        : ((info.positionMs + info.bufferAheadMs) / duration).clamp(0.0, 1.0);

    return SizedBox(
      height: Sizes.miniProgress,
      child: CustomPaint(
        painter: _MiniLinePainter(
          played: played.clamp(0.0, 1.0),
          buffered: buffered,
          playedColor: c.accent,
          bufferedColor: c.cacheFill,
          trackColor: c.outline,
        ),
      ),
    );
  }
}

class _MiniLinePainter extends CustomPainter {
  _MiniLinePainter({
    required this.played,
    required this.buffered,
    required this.playedColor,
    required this.bufferedColor,
    required this.trackColor,
  });

  final double played;
  final double buffered;
  final Color playedColor;
  final Color bufferedColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = trackColor);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width * buffered, size.height),
      Paint()..color = bufferedColor,
    );
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width * played, size.height),
      Paint()..color = playedColor,
    );
  }

  @override
  bool shouldRepaint(_MiniLinePainter old) =>
      old.played != played || old.buffered != buffered;
}

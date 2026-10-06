import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core_api/enums.dart';
import '../core_api/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../util/format.dart';
import '../l10n/l10n.dart';

/// Format chip: `FLAC 24/96`.
///
/// Four visual treatments carry the quality class without relying on colour:
/// Hi-Res is filled, CD is outlined, lossy is muted, unsupported is
/// struck through.
class FormatBadge extends StatelessWidget {
  const FormatBadge({
    super.key,
    required this.format,
    this.compact = false,
    this.visibility = BadgeVisibility.always,
  });

  final AudioFormat format;

  /// Drops the codec name, leaving `24/96`.
  final bool compact;
  final BadgeVisibility visibility;

  @override
  Widget build(BuildContext context) {
    if (visibility == BadgeVisibility.never) return const SizedBox.shrink();
    if (visibility == BadgeVisibility.hiResOnly && !format.isHiRes) {
      return const SizedBox.shrink();
    }

    final c = context.c;
    final supported = format.codec.isSupported;
    final lossless = format.codec.isLossless;
    final hiRes = format.isHiRes;

    final (Color fg, Color bg, Color border) = switch ((supported, lossless, hiRes)) {
      (false, _, _) => (c.textTertiary, Colors.transparent, c.outline),
      (true, true, true) => (c.onAccent, c.accent, c.accent),
      (true, true, false) => (c.textSecondary, Colors.transparent, c.outline),
      _ => (c.textTertiary, c.surface3, c.surface3),
    };

    final label = switch (format.codec) {
      Codec.mp3 || Codec.aac => compact
          ? Fmt.kbps(format.bitrateKbps)
          : '${format.codec.label} ${format.bitrateKbps}k',
      Codec.dsf => compact ? 'DSD64' : 'DSF DSD64',
      _ => compact ? format.shortLabel : format.badgeLabel,
    };

    return Semantics(
      label: _semanticLabel(context),
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: Radii.badgeR,
          border: Border.all(color: border),
        ),
        child: Text(
          label,
          style: context.t.monoLabel.copyWith(
            color: fg,
            decoration: supported ? null : TextDecoration.lineThrough,
          ),
        ),
      ),
    );
  }

  String _semanticLabel(BuildContext context) {
    if (!format.codec.isSupported) {
      return '${format.codec.label}, ${context.l10n.formatNotSupported}';
    }
    final quality = format.isHiRes
        ? 'Hi-Res'
        : (format.codec.isLossless ? 'CD quality' : 'Lossy');
    return '${format.codec.label} ${format.longLabel}, $quality';
  }
}

/// Tier chip. Colour, **shape** and text always travel together, so the tier
/// survives greyscale and colour-blindness.
class TierChip extends StatelessWidget {
  const TierChip({
    super.key,
    required this.tier,
    this.detail,
    this.dense = false,
    this.onTap,
  });

  final OutputTier tier;

  /// e.g. `96 → 48 kHz` or `24/96`.
  final String? detail;
  final bool dense;
  final VoidCallback? onTap;

  static IconData iconFor(OutputTier tier) => switch (tier) {
        OutputTier.bitPerfect => Icons.diamond_outlined,
        OutputTier.nativeRate => Icons.circle,
        OutputTier.resampled => Icons.change_history,
        OutputTier.unknown => Icons.help_outline,
      };

  static Color colorFor(BuildContext context, OutputTier tier) =>
      switch (tier) {
        OutputTier.bitPerfect => context.c.tierBitPerfect,
        OutputTier.nativeRate => context.c.tierNativeRate,
        OutputTier.resampled => context.c.tierResampled,
        OutputTier.unknown => context.c.tierUnknown,
      };

  @override
  Widget build(BuildContext context) {
    final color = colorFor(context, tier);
    final body = Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : Spacing.xs,
        vertical: dense ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: Radii.badgeR,
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(iconFor(tier), size: dense ? 11 : 13, color: color),
          const SizedBox(width: 5),
          Text(tier.label,
              style: context.t.monoLabel.copyWith(color: color)),
          if (detail != null) ...[
            Text(' · ', style: context.t.monoLabel.copyWith(color: color)),
            Text(detail!, style: context.t.monoLabel.copyWith(color: color)),
          ],
        ],
      ),
    );

    final labelled = Semantics(
      label: '${context.l10n.outputIs(tier.label)}'
          '${detail == null ? '' : ', $detail'}',
      button: onTap != null,
      excludeSemantics: true,
      child: body,
    );

    if (onTap == null) return labelled;
    return InkWell(
      onTap: onTap,
      borderRadius: Radii.badgeR,
      child: labelled,
    );
  }
}

/// Marks that something in the chain is altering the samples.
class DspBadge extends StatelessWidget {
  const DspBadge({super.key, this.dense = false, this.label = 'DSP'});

  final bool dense;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = context.c.dspActive;
    return Semantics(
      label: context.l10n.dspActive,
      excludeSemantics: true,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: dense ? 5 : 6,
          vertical: dense ? 1 : 2,
        ),
        decoration: BoxDecoration(
          color: color.withOpacity(0.16),
          borderRadius: Radii.badgeR,
          border: Border.all(color: color.withOpacity(0.55)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.graphic_eq, size: dense ? 10 : 12, color: color),
            const SizedBox(width: 4),
            Text(label, style: context.t.monoLabel.copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}

/// Cloud availability. Each state has a distinct glyph *and* a semantics
/// label; `cloudOnly` renders nothing by default to keep lists quiet, since it
/// is the common case.
class AvailabilityGlyph extends StatelessWidget {
  const AvailabilityGlyph({
    super.key,
    required this.availability,
    this.cachedPercent = 0,
    this.downloadProgress,
    this.size = 16,
    this.showCloudOnly = false,
  });

  final Availability availability;
  final int cachedPercent;
  final double? downloadProgress;
  final double size;

  /// Draw an explicit glyph for `cloudOnly` (used in the gallery and filters).
  final bool showCloudOnly;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final label = describe(context, availability, cachedPercent);

    Widget glyph;
    switch (availability) {
      case Availability.cloudOnly:
        if (!showCloudOnly) return const SizedBox.shrink();
        glyph = Icon(Icons.cloud_outlined, size: size, color: c.textTertiary);
      case Availability.partiallyCached:
        glyph = _PartialRing(
          percent: cachedPercent,
          size: size,
          color: c.accent,
          track: c.outline,
        );
      case Availability.cached:
        glyph = Icon(Icons.download_done, size: size, color: c.textSecondary);
      case Availability.pinned:
        glyph = Icon(Icons.push_pin, size: size, color: c.success);
      case Availability.downloading:
        glyph = _DownloadRing(
          progress: downloadProgress ?? 0,
          size: size,
          color: c.accent,
          track: c.outline,
        );
      case Availability.unavailable:
        glyph = Icon(Icons.cloud_off, size: size, color: c.textTertiary);
      case Availability.unsupported:
        glyph = Icon(Icons.block, size: size, color: c.textTertiary);
      case Availability.missing:
        glyph = Icon(Icons.link_off, size: size, color: c.error);
    }

    return Semantics(label: label, excludeSemantics: true, child: glyph);
  }

  /// Screen-reader and tooltip text. Also used by rows that spell the state out.
  static String describe(
    BuildContext context,
    Availability a, [
    int cachedPercent = 0,
  ]) {
    final l = context.l10n;
    return switch (a) {
      Availability.cloudOnly => l.availCloudOnly,
      Availability.partiallyCached => l.availPartial(cachedPercent),
      Availability.cached => l.availCached,
      Availability.pinned => l.availPinned,
      Availability.downloading => l.availDownloading,
      Availability.unavailable => l.availUnavailable,
      Availability.unsupported => l.availUnsupported,
      Availability.missing => l.availMissing,
    };
  }
}

class _PartialRing extends StatelessWidget {
  const _PartialRing({
    required this.percent,
    required this.size,
    required this.color,
    required this.track,
  });

  final int percent;
  final double size;
  final Color color;
  final Color track;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _RingPainter(
            progress: percent / 100,
            color: color,
            track: track,
            dashed: true,
          ),
        ),
      );
}

class _DownloadRing extends StatefulWidget {
  const _DownloadRing({
    required this.progress,
    required this.size,
    required this.color,
    required this.track,
  });

  final double progress;
  final double size;
  final Color color;
  final Color track;

  @override
  State<_DownloadRing> createState() => _DownloadRingState();
}

class _DownloadRingState extends State<_DownloadRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Reduce-motion collapses the sweep to a static ring.
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) => CustomPaint(
          painter: _RingPainter(
            progress: widget.progress,
            color: widget.color,
            track: widget.track,
            rotation: reduce ? 0 : _ctrl.value * 2 * math.pi,
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.color,
    required this.track,
    this.rotation = 0,
    this.dashed = false,
  });

  final double progress;
  final Color color;
  final Color track;
  final double rotation;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = math.max(1.6, size.width / 8);
    final rect = Offset.zero & size;
    final inner = rect.deflate(stroke / 2);

    canvas.drawArc(
      inner,
      0,
      2 * math.pi,
      false,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    if (dashed) {
      // Partial cache: several arcs, hinting at non-contiguous ranges.
      final total = progress.clamp(0.0, 1.0) * 2 * math.pi;
      const segments = 3;
      const gap = 0.22;
      final seg = (total - gap * (segments - 1)) / segments;
      if (seg > 0) {
        for (var i = 0; i < segments; i++) {
          canvas.drawArc(
            inner,
            -math.pi / 2 + i * (seg + gap),
            seg,
            false,
            paint,
          );
        }
      }
    } else {
      canvas.drawArc(
        inner,
        -math.pi / 2 + rotation,
        progress.clamp(0.0, 1.0) * 2 * math.pi,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress ||
      old.rotation != rotation ||
      old.color != color ||
      old.track != track;
}

/// Buffering caption + pulsing dot. Escalates its wording with [attempt],
/// matching the copy rule "what happened + what BitDrop is doing".
class BufferingIndicator extends StatelessWidget {
  const BufferingIndicator({
    super.key,
    required this.state,
    this.compact = false,
  });

  final BufferingState state;
  final bool compact;

  String messageFor(BuildContext context) => state.attempt >= 2
      ? context.l10n.bufferingSlow
      : context.l10n.bufferingLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final message = messageFor(context);
    final detail =
        '${(state.bufferedMs / 1000).toStringAsFixed(1)} s of '
        '${(state.targetMs / 1000).toStringAsFixed(0)} s';
    return Semantics(
      liveRegion: true,
      label: '$message, $detail',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: state.targetMs == 0
                  ? null
                  : (state.bufferedMs / state.targetMs).clamp(0.0, 1.0),
              color: c.accent,
              backgroundColor: c.outline,
            ),
          ),
          const SizedBox(width: Spacing.xs),
          Flexible(
            child: Text(
              compact ? message : '$message · $detail',
              style: context.t.bodySmall.copyWith(color: c.textSecondary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../util/format.dart';

/// Preamp slider with the auto-preamp suggestion and a clipping meter.
///
/// The clip count comes from the core's meter; the UI never guesses whether
/// clipping happened.
class PreampMeter extends StatelessWidget {
  const PreampMeter({
    super.key,
    required this.preampDb,
    required this.onChanged,
    required this.clippedSamples,
    this.suggestedDb,
    this.onApplySuggestion,
    this.peakDb,
  });

  final double preampDb;
  final ValueChanged<double> onChanged;
  final int clippedSamples;
  final double? suggestedDb;
  final VoidCallback? onApplySuggestion;

  /// Peak of the combined EQ curve, used for the headroom warning.
  final double? peakDb;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final clipping = clippedSamples > 0;
    final headroomRisk = (peakDb ?? 0) > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Preamp', style: context.t.titleSmall),
            const Spacer(),
            Text(Fmt.db(preampDb), style: context.t.monoReadout),
          ],
        ),
        Semantics(
          slider: true,
          label: 'Preamp',
          value: Fmt.db(preampDb),
          excludeSemantics: true,
          child: Slider(
            value: preampDb.clamp(-24, 12),
            min: -24,
            max: 12,
            divisions: 72,
            label: Fmt.db(preampDb),
            onChanged: onChanged,
          ),
        ),
        Row(
          children: [
            // Clipping meter: fills from 0 dB upward, red once samples clip.
            Expanded(
              child: Semantics(
                label: clipping
                    ? 'Clipping, $clippedSamples samples clipped'
                    : 'No clipping',
                excludeSemantics: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          clipping
                              ? Icons.warning_amber_rounded
                              : Icons.check_circle_outline,
                          size: 14,
                          color: clipping ? c.error : c.success,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          clipping
                              ? 'Clipping · ${Fmt.count(clippedSamples)} samples'
                              : (headroomRisk
                                  ? 'Peak ${Fmt.db(peakDb!)} · clipping risk'
                                  : 'No clipping'),
                          style: context.t.bodySmall.copyWith(
                            color: clipping
                                ? c.error
                                : (headroomRisk
                                    ? c.tierResampled
                                    : c.textSecondary),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: Spacing.xxs),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: SizedBox(
                        height: 4,
                        child: LinearProgressIndicator(
                          value: ((peakDb ?? -12) + 15) / 27,
                          backgroundColor: c.surface3,
                          color: clipping
                              ? c.error
                              : (headroomRisk ? c.tierResampled : c.accent),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (suggestedDb != null && onApplySuggestion != null) ...[
              const SizedBox(width: Spacing.xs),
              OutlinedButton(
                onPressed: onApplySuggestion,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
                ),
                child: Text(
                  'Auto ${Fmt.db(suggestedDb!)}',
                  style: context.t.monoLabel,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// Stereo peak meter with a hold indicator and a clip LED.
///
/// Values come from the core's low-rate [VisualizerFrame]; nothing is invented.
class VuMeter extends StatelessWidget {
  const VuMeter({
    super.key,
    required this.leftDb,
    required this.rightDb,
    required this.clipping,
    this.height = 90,
  });

  final double leftDb;
  final double rightDb;
  final bool clipping;
  final double height;

  static const double floorDb = -60;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      label: 'Peak meters. Left ${Fmt.db(leftDb)}, right ${Fmt.db(rightDb)}'
          '${clipping ? ', clipping' : ''}',
      excludeSemantics: true,
      child: Column(
        children: [
          Row(
            children: [
              Text('PEAK',
                  style: context.t.monoLabel.copyWith(color: c.textSecondary)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: clipping ? c.error : c.surface3,
                  borderRadius: Radii.badgeR,
                ),
                child: Text(
                  'CLIP',
                  style: context.t.monoLabel.copyWith(
                    color: clipping ? Colors.white : c.textTertiary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          _MeterBar(
              label: 'L', db: leftDb, colors: c, style: context.t.monoLabel),
          const SizedBox(height: Spacing.xxs),
          _MeterBar(
              label: 'R', db: rightDb, colors: c, style: context.t.monoLabel),
          const SizedBox(height: Spacing.xxs),
          // Scale marks so the bars mean something.
          Padding(
            padding: const EdgeInsets.only(left: 18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final m in ['−60', '−40', '−20', '−12', '−6', '0'])
                  Text(m,
                      style: context.t.monoLabel
                          .copyWith(color: c.textTertiary, fontSize: 9)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MeterBar extends StatelessWidget {
  const _MeterBar({
    required this.label,
    required this.db,
    required this.colors,
    required this.style,
  });

  final String label;
  final double db;
  final BitDropColors colors;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final fraction =
        ((db - VuMeter.floorDb) / (0 - VuMeter.floorDb)).clamp(0.0, 1.0);
    return Row(
      children: [
        SizedBox(
          width: 14,
          child:
              Text(label, style: style.copyWith(color: colors.textSecondary)),
        ),
        Expanded(
          child: SizedBox(
            height: 10,
            child: CustomPaint(
              painter: _MeterPainter(
                fraction: fraction,
                safe: colors.tierBitPerfect,
                warn: colors.tierResampled,
                hot: colors.error,
                track: colors.surface3,
              ),
            ),
          ),
        ),
        const SizedBox(width: Spacing.xs),
        SizedBox(
          width: 52,
          child: Text(
            Fmt.db(db),
            style: style.copyWith(color: colors.textSecondary),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}

class _MeterPainter extends CustomPainter {
  _MeterPainter({
    required this.fraction,
    required this.safe,
    required this.warn,
    required this.hot,
    required this.track,
  });

  final double fraction;
  final Color safe;
  final Color warn;
  final Color hot;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    // Segmented bar — reads as instrumentation, and the segments double as a
    // non-colour cue for level.
    const segments = 28;
    final segW = size.width / segments;
    final lit = (fraction * segments).round();
    for (var i = 0; i < segments; i++) {
      final t = i / segments;
      final color =
          i < lit ? (t > 0.92 ? hot : (t > 0.78 ? warn : safe)) : track;
      canvas.drawRect(
        Rect.fromLTWH(i * segW + 0.6, 0, segW - 1.2, size.height),
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_MeterPainter old) => old.fraction != fraction;
}

/// Spectrum analyser for the Studio layout. Mocked, low-rate data.
class SpectrumView extends StatelessWidget {
  const SpectrumView({
    super.key,
    required this.bins,
    this.height = 90,
  });

  final List<double> bins;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      label: 'Spectrum analyser, decorative',
      excludeSemantics: true,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: Radii.chipR,
          border: Border.all(color: c.outline),
        ),
        clipBehavior: Clip.antiAlias,
        child: CustomPaint(
          painter: _SpectrumPainter(
            bins: bins,
            color: c.accent,
            track: c.outline,
          ),
        ),
      ),
    );
  }
}

class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter({
    required this.bins,
    required this.color,
    required this.track,
  });

  final List<double> bins;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    if (bins.isEmpty) {
      canvas.drawLine(
        Offset(0, size.height - 1),
        Offset(size.width, size.height - 1),
        Paint()
          ..color = track
          ..strokeWidth = 2,
      );
      return;
    }
    final w = size.width / bins.length;
    for (var i = 0; i < bins.length; i++) {
      final h = (bins[i].clamp(0.0, 1.0)) * (size.height - 6);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(i * w + 1, size.height - h, math.max(1, w - 2), h),
        const Radius.circular(1.5),
      );
      canvas.drawRRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [color.withOpacity(0.35), color],
          ).createShader(rect.outerRect),
      );
    }
  }

  @override
  bool shouldRepaint(_SpectrumPainter old) => old.bins != bins;
}

/// Small sparkline for the Diagnostics cards.
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    this.height = 32,
    this.color,
  });

  final List<double> values;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _SparkPainter(
            values: values,
            color: color ?? context.c.accent,
            track: context.c.outline,
          ),
        ),
      );
}

class _SparkPainter extends CustomPainter {
  _SparkPainter({
    required this.values,
    required this.color,
    required this.track,
  });

  final List<double> values;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      Paint()
        ..color = track
        ..strokeWidth = 1,
    );
    if (values.length < 2) return;

    final maxV = values.reduce(math.max);
    final scale = maxV <= 0 ? 1.0 : maxV;
    final dx = size.width / (values.length - 1);

    final line = Path();
    final fill = Path()..moveTo(0, size.height);
    for (var i = 0; i < values.length; i++) {
      final x = i * dx;
      final y = size.height - (values[i] / scale) * (size.height - 2);
      i == 0 ? line.moveTo(x, y) : line.lineTo(x, y);
      fill.lineTo(x, y);
    }
    fill
      ..lineTo(size.width, size.height)
      ..close();

    canvas.drawPath(fill, Paint()..color = color.withOpacity(0.14));
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.values != values;
}

/// Storage breakdown bar: Pinned · Cache · Artwork · Database · Free.
class StorageBar extends StatelessWidget {
  const StorageBar({
    super.key,
    required this.segments,
    required this.totalBytes,
    this.height = 14,
  });

  final List<({String label, int bytes, Color color})> segments;
  final int totalBytes;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final used = segments.fold<int>(0, (a, s) => a + s.bytes);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          label: 'Storage: ${segments.map((s) => '${s.label} '
              '${Fmt.bytes(s.bytes)}').join(', ')}',
          excludeSemantics: true,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(height / 2),
            child: SizedBox(
              height: height,
              child: Row(
                children: [
                  for (final s in segments)
                    if (s.bytes > 0)
                      Expanded(
                        flex: math.max(1, s.bytes),
                        child: Container(color: s.color),
                      ),
                  if (totalBytes > used)
                    Expanded(
                      flex: totalBytes - used,
                      child: Container(color: c.surface3),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: Spacing.xs),
        Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.xxs,
          children: [
            for (final s in segments)
              _LegendDot(
                color: s.color,
                label: '${s.label} ${Fmt.bytes(s.bytes)}',
              ),
            _LegendDot(
              color: c.surface3,
              label: 'Free ${Fmt.bytes(totalBytes - used)}',
            ),
          ],
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(label,
              style:
                  context.t.monoLabel.copyWith(color: context.c.textSecondary)),
        ],
      );
}

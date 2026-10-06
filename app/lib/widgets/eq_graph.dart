import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core_api/enums.dart';
import '../core_api/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../util/biquad.dart';
import '../util/format.dart';

/// Interactive frequency-response editor.
///
/// Log frequency axis 20 Hz – 20 kHz, ±15 dB vertical. The combined curve is
/// drawn in the accent colour, individual bands as faint ghosts. Nodes are
/// dragged to set frequency and gain; a horizontal two-finger scale gesture or
/// the band list's numeric field sets Q.
///
/// A haptic tick fires when a band snaps through 0 dB, which is how you find
/// flat without looking.
class EqGraph extends StatefulWidget {
  const EqGraph({
    super.key,
    required this.bands,
    required this.onChanged,
    this.preampDb = 0,
    this.bypassed = false,
    this.targetCurve,
    this.selectedBandId,
    this.onSelect,
    this.interactive = true,
    this.height = 240,
  });

  final List<EqBand> bands;

  /// Called continuously while dragging; the parent forwards to the core.
  final ValueChanged<List<EqBand>> onChanged;
  final double preampDb;
  final bool bypassed;

  /// AutoEQ target overlay, when a profile is applied.
  final List<({double hz, double db})>? targetCurve;
  final int? selectedBandId;
  final ValueChanged<int?>? onSelect;
  final bool interactive;
  final double height;

  static const double maxDb = 15;

  @override
  State<EqGraph> createState() => _EqGraphState();
}

class _EqGraphState extends State<EqGraph> {
  int? _draggingId;
  double _scaleStartQ = 1;
  bool _lastAboveZero = true;

  @override
  Widget build(BuildContext context) {
    final c = context.c;

    return Semantics(
      label: 'Equaliser response graph. '
          '${widget.bands.length} bands. '
          'Use the band list below to edit values precisely.',
      excludeSemantics: true,
      child: Container(
        height: widget.height,
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: Radii.cardR,
          border: Border.all(color: c.outline),
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, box) {
            final size = Size(box.maxWidth, box.maxHeight);
            // Scale is a superset of pan, so this uses only the scale
            // recognizer: one finger drags frequency and gain, two fingers
            // set Q.
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: widget.interactive
                  ? (d) => _selectNearest(d.localPosition, size)
                  : null,
              onScaleStart: widget.interactive
                  ? (d) => _onScaleStart(d, size)
                  : null,
              onScaleUpdate: widget.interactive
                  ? (d) => _onScaleUpdate(d, size)
                  : null,
              onScaleEnd: widget.interactive
                  ? (_) => setState(() => _draggingId = null)
                  : null,
              child: CustomPaint(
                size: size,
                painter: _EqPainter(
                  bands: widget.bands,
                  preampDb: widget.preampDb,
                  bypassed: widget.bypassed,
                  targetCurve: widget.targetCurve,
                  selectedBandId: widget.selectedBandId,
                  draggingId: _draggingId,
                  curve: c.accent,
                  ghost: c.accent.withOpacity(0.22),
                  grid: c.outline,
                  zeroLine: c.textTertiary,
                  label: c.textSecondary,
                  target: c.dspActive,
                  nodeFill: c.surface1,
                  textStyle: context.t.monoLabel.copyWith(color: c.textSecondary),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ---- Coordinate mapping --------------------------------------------------

  double _dbToY(double db, Size size) =>
      size.height / 2 - (db / EqGraph.maxDb) * (size.height / 2 - 12);

  double _yToDb(double y, Size size) =>
      ((size.height / 2 - y) / (size.height / 2 - 12) * EqGraph.maxDb)
          .clamp(-EqGraph.maxDb, EqGraph.maxDb);

  double _hzToX(double hz, Size size) => Biquad.positionOf(hz) * size.width;

  double _xToHz(double x, Size size) =>
      Biquad.logFrequencyAt((x / size.width).clamp(0.0, 1.0));

  void _selectNearest(Offset p, Size size) {
    if (widget.bands.isEmpty) return;
    var bestId = widget.bands.first.id;
    var bestDistance = double.infinity;
    for (final b in widget.bands) {
      final node = Offset(
        _hzToX(b.frequencyHz, size),
        _dbToY(b.gainDb, size),
      );
      final d = (node - p).distance;
      if (d < bestDistance) {
        bestDistance = d;
        bestId = b.id;
      }
    }
    // Only grab a node the finger is actually near.
    if (bestDistance > 56) {
      widget.onSelect?.call(null);
      setState(() => _draggingId = null);
      return;
    }
    widget.onSelect?.call(bestId);
    final band = widget.bands.firstWhere((b) => b.id == bestId);
    setState(() {
      _draggingId = bestId;
      _scaleStartQ = band.q;
      _lastAboveZero = band.gainDb >= 0;
    });
  }

  void _dragNode(Offset p, Size size) {
    final id = _draggingId;
    if (id == null) return;
    final hz = _xToHz(p.dx, size);
    final db = _yToDb(p.dy, size);

    // Snap to exactly 0 dB near the centre line, with a tick.
    final snapped = db.abs() < 0.6 ? 0.0 : db;
    final crossedZero = (snapped >= 0) != _lastAboveZero;
    if (snapped == 0.0 || crossedZero) {
      HapticFeedback.selectionClick();
      _lastAboveZero = snapped >= 0;
    }

    widget.onChanged([
      for (final b in widget.bands)
        if (b.id == id)
          b.copyWith(
            frequencyHz: hz.clamp(Biquad.minHz, Biquad.maxHz),
            gainDb: double.parse(snapped.toStringAsFixed(1)),
            enabled: true,
          )
        else
          b,
    ]);
  }

  void _onScaleStart(ScaleStartDetails d, Size size) {
    _selectNearest(d.localFocalPoint, size);
    final id = _draggingId ?? widget.selectedBandId;
    final band =
        widget.bands.where((b) => b.id == id).cast<EqBand?>().firstOrNull;
    if (band != null) _scaleStartQ = band.q;
  }

  void _onScaleUpdate(ScaleUpdateDetails d, Size size) {
    final id = _draggingId ?? widget.selectedBandId;
    if (id == null) return;

    // Two fingers: pinch horizontally to widen or narrow the band.
    if (d.pointerCount >= 2) {
      final q = (_scaleStartQ * d.horizontalScale).clamp(0.2, 12.0);
      widget.onChanged([
        for (final b in widget.bands)
          if (b.id == id)
            b.copyWith(q: double.parse(q.toStringAsFixed(2)))
          else
            b,
      ]);
      return;
    }

    // One finger: drag frequency and gain.
    _dragNode(d.localFocalPoint, size);
  }
}

class _EqPainter extends CustomPainter {
  _EqPainter({
    required this.bands,
    required this.preampDb,
    required this.bypassed,
    required this.targetCurve,
    required this.selectedBandId,
    required this.draggingId,
    required this.curve,
    required this.ghost,
    required this.grid,
    required this.zeroLine,
    required this.label,
    required this.target,
    required this.nodeFill,
    required this.textStyle,
  });

  final List<EqBand> bands;
  final double preampDb;
  final bool bypassed;
  final List<({double hz, double db})>? targetCurve;
  final int? selectedBandId;
  final int? draggingId;
  final Color curve;
  final Color ghost;
  final Color grid;
  final Color zeroLine;
  final Color label;
  final Color target;
  final Color nodeFill;
  final TextStyle textStyle;

  static const _decades = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000];

  @override
  void paint(Canvas canvas, Size size) {
    final midY = size.height / 2;
    final span = size.height / 2 - 12;

    double dbToY(double db) => midY - (db / EqGraph.maxDb) * span;
    double hzToX(double hz) => Biquad.positionOf(hz) * size.width;

    // Horizontal dB grid at -12, -6, 0, +6, +12.
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final db in [-12.0, -6.0, 6.0, 12.0]) {
      final y = dbToY(db);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
      _text(canvas, '${db > 0 ? '+' : '−'}${db.abs().toInt()}',
          Offset(4, y - 14));
    }

    // Vertical frequency grid.
    for (final hz in _decades) {
      final x = hzToX(hz.toDouble());
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (final hz in [100, 1000, 10000]) {
      final x = hzToX(hz.toDouble());
      _text(canvas, Fmt.hzShort(hz.toDouble()),
          Offset(x + 3, size.height - 16));
    }

    // 0 dB reference, drawn stronger than the rest.
    canvas.drawLine(
      Offset(0, midY),
      Offset(size.width, midY),
      Paint()
        ..color = zeroLine
        ..strokeWidth = 1.4,
    );

    if (bypassed) {
      _text(canvas, 'BYPASSED', Offset(size.width / 2 - 34, midY - 24));
    }

    // AutoEQ target overlay.
    final tc = targetCurve;
    if (tc != null && tc.isNotEmpty) {
      final path = Path();
      for (var i = 0; i < tc.length; i++) {
        final p = Offset(hzToX(tc[i].hz), dbToY(tc[i].db));
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = target.withOpacity(0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    final opacity = bypassed ? 0.3 : 1.0;

    // Ghost curves, one per enabled band.
    final ghostPaint = Paint()
      ..color = ghost.withOpacity(ghost.opacity * opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final b in bands) {
      if (!b.enabled || b.gainDb == 0) continue;
      final path = Path();
      for (var i = 0; i <= 120; i++) {
        final hz = Biquad.logFrequencyAt(i / 120);
        final y = dbToY(Biquad.magnitudeDb(b, hz));
        final x = hzToX(hz);
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      canvas.drawPath(path, ghostPaint);
    }

    // Combined curve, with a soft fill toward the 0 dB line.
    final combined = Path();
    final fill = Path()..moveTo(0, midY);
    for (var i = 0; i <= 220; i++) {
      final hz = Biquad.logFrequencyAt(i / 220);
      final db = Biquad.combinedDb(bands, hz, preampDb: preampDb);
      final x = hzToX(hz);
      final y = dbToY(db.clamp(-EqGraph.maxDb, EqGraph.maxDb));
      i == 0 ? combined.moveTo(x, y) : combined.lineTo(x, y);
      fill.lineTo(x, y);
    }
    fill
      ..lineTo(size.width, midY)
      ..close();

    canvas.drawPath(
      fill,
      Paint()..color = curve.withOpacity(0.12 * opacity),
    );
    canvas.drawPath(
      combined,
      Paint()
        ..color = curve.withOpacity(opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeJoin = StrokeJoin.round,
    );

    // Draggable nodes.
    for (final b in bands) {
      final x = hzToX(b.frequencyHz);
      final y = dbToY(b.gainDb.clamp(-EqGraph.maxDb, EqGraph.maxDb));
      final isSelected = b.id == selectedBandId || b.id == draggingId;
      final r = isSelected ? 9.0 : 6.5;

      if (isSelected) {
        canvas.drawCircle(
          Offset(x, y),
          r + 6,
          Paint()..color = curve.withOpacity(0.18),
        );
        // Q handle: a horizontal bar whose width tracks bandwidth.
        final half = (size.width / (b.q * 6)).clamp(8.0, size.width / 3);
        canvas.drawLine(
          Offset(x - half, y),
          Offset(x + half, y),
          Paint()
            ..color = curve.withOpacity(0.5)
            ..strokeWidth = 2
            ..strokeCap = StrokeCap.round,
        );
      }

      canvas.drawCircle(Offset(x, y), r, Paint()..color = nodeFill);
      canvas.drawCircle(
        Offset(x, y),
        r,
        Paint()
          ..color = b.enabled ? curve : grid
          ..style = PaintingStyle.stroke
          ..strokeWidth = isSelected ? 3 : 2,
      );

      if (isSelected) {
        _text(
          canvas,
          '${Fmt.hzShort(b.frequencyHz)}Hz ${Fmt.db(b.gainDb)} Q${Fmt.q(b.q)}',
          Offset(
            (x - 60).clamp(2.0, math.max(2.0, size.width - 130)),
            (y - 26).clamp(2.0, size.height - 16),
          ),
        );
      }
    }
  }

  void _text(Canvas canvas, String text, Offset at) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: textStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_EqPainter old) =>
      old.bands != bands ||
      old.preampDb != preampDb ||
      old.bypassed != bypassed ||
      old.selectedBandId != selectedBandId ||
      old.draggingId != draggingId ||
      old.targetCurve != targetCurve;
}

/// One editable band: enable, type, frequency, gain, Q.
///
/// This is the non-gesture alternative to dragging nodes, required for
/// accessibility.
class EqBandRow extends StatelessWidget {
  const EqBandRow({
    super.key,
    required this.band,
    required this.onChanged,
    required this.onRemove,
    this.selected = false,
    this.onSelect,
  });

  final EqBand band;
  final ValueChanged<EqBand> onChanged;
  final VoidCallback onRemove;
  final bool selected;
  final VoidCallback? onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return InkWell(
      onTap: onSelect,
      child: Container(
        color: selected ? c.accent.withOpacity(0.08) : null,
        padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md, vertical: Spacing.xs),
        child: Column(
          children: [
            Row(
              children: [
                Semantics(
                  label: 'Band ${band.id} enabled',
                  child: Switch(
                    value: band.enabled,
                    onChanged: (v) => onChanged(band.copyWith(enabled: v)),
                  ),
                ),
                const SizedBox(width: Spacing.xs),
                _TypeMenu(
                  value: band.type,
                  onChanged: (t) => onChanged(band.copyWith(type: t)),
                ),
                const SizedBox(width: Spacing.xs),
                Expanded(
                  child: Text(
                    Fmt.biquadLong(band.type),
                    style: context.t.bodySmall
                        .copyWith(color: c.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  onPressed: onRemove,
                  icon: const Icon(Icons.remove_circle_outline, size: 18),
                  tooltip: 'Remove band ${band.id}',
                  color: c.textSecondary,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: Spacing.xxs),
            Row(
              children: [
                Expanded(
                  child: _Stepper(
                    label: 'Hz',
                    value: band.frequencyHz,
                    digits: 0,
                    step: band.frequencyHz < 200 ? 5 : 25,
                    min: Biquad.minHz,
                    max: Biquad.maxHz,
                    onChanged: (v) =>
                        onChanged(band.copyWith(frequencyHz: v)),
                  ),
                ),
                const SizedBox(width: Spacing.xs),
                Expanded(
                  child: _Stepper(
                    label: 'dB',
                    value: band.gainDb,
                    digits: 1,
                    step: 0.5,
                    min: -EqGraph.maxDb,
                    max: EqGraph.maxDb,
                    onChanged: (v) => onChanged(band.copyWith(gainDb: v)),
                  ),
                ),
                const SizedBox(width: Spacing.xs),
                Expanded(
                  child: _Stepper(
                    label: 'Q',
                    value: band.q,
                    digits: 2,
                    step: 0.1,
                    min: 0.2,
                    max: 12,
                    onChanged: (v) => onChanged(band.copyWith(q: v)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TypeMenu extends StatelessWidget {
  const _TypeMenu({required this.value, required this.onChanged});

  final BiquadType value;
  final ValueChanged<BiquadType> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<BiquadType>(
      initialValue: value,
      onSelected: onChanged,
      tooltip: 'Filter type: ${Fmt.biquadLong(value)}',
      itemBuilder: (_) => [
        for (final t in BiquadType.values)
          PopupMenuItem(value: t, child: Text(Fmt.biquadLong(t))),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        decoration: BoxDecoration(
          color: context.c.surface3,
          borderRadius: Radii.badgeR,
          border: Border.all(color: context.c.outline),
        ),
        child: Text(
          Fmt.biquad(value),
          style: context.t.monoLabel,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

/// Numeric field with steppers, tabular figures and an explicit unit.
class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.value,
    required this.digits,
    required this.step,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final double value;
  final int digits;
  final double step;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final text = digits == 0
        ? value.round().toString()
        : value.toStringAsFixed(digits);

    return Semantics(
      slider: true,
      label: label,
      value: text,
      onIncrease: () => onChanged((value + step).clamp(min, max)),
      onDecrease: () => onChanged((value - step).clamp(min, max)),
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        decoration: BoxDecoration(
          color: c.surface3,
          borderRadius: Radii.badgeR,
          border: Border.all(color: c.outline),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _Tick(
              icon: Icons.remove,
              onTap: () => onChanged((value - step).clamp(min, max)),
            ),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(text, style: context.t.monoReadout),
                    const SizedBox(width: 2),
                    Text(
                      label,
                      style: context.t.monoLabel
                          .copyWith(color: c.textTertiary),
                    ),
                  ],
                ),
              ),
            ),
            _Tick(
              icon: Icons.add,
              onTap: () => onChanged((value + step).clamp(min, max)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tick extends StatelessWidget {
  const _Tick({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Icon(icon, size: 14, color: context.c.textSecondary),
        ),
      );
}

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core_api/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../l10n/l10n.dart';

/// Seeded placeholder artwork.
///
/// No real cover art and no network images anywhere in the prototype: each
/// album gets a deterministic gradient plus a geometric motif derived from its
/// seed, tinted toward the `dominantColor` the core supplies.
class AlbumArtwork extends StatelessWidget {
  const AlbumArtwork({
    super.key,
    required this.artwork,
    required this.size,
    this.borderRadius,
    this.title,
    this.dimmed = false,
  });

  final Artwork artwork;
  final double size;
  final BorderRadius? borderRadius;

  /// Used for the initial glyph and the semantics label.
  final String? title;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ??
        (size >= 200 ? Radii.heroArtR : Radii.gridArtR);
    return Semantics(
      label: title == null
          ? context.l10n.albumArtwork
          : context.l10n.artworkFor(title!),
      image: true,
      child: ClipRRect(
        borderRadius: radius,
        child: SizedBox(
          width: size,
          height: size,
          child: Opacity(
            opacity: dimmed ? 0.45 : 1,
            child: CustomPaint(
              painter: _ArtworkPainter(
                seed: artwork.seed,
                dominant: Color(artwork.dominantColor),
                outline: context.c.outline,
              ),
              child: title == null || size < 56
                  ? null
                  : Center(
                      child: Text(
                        _initials(title!),
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: size * 0.26,
                          fontWeight: FontWeight.w600,
                          color: Colors.white.withOpacity(0.72),
                          letterSpacing: 1,
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  static String _initials(String title) {
    final words = title
        .split(RegExp(r'[\s,·]+'))
        .where((w) => w.isNotEmpty && w[0].toUpperCase() == w[0] || w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    if (words.length == 1) return words.first.substring(0, 1).toUpperCase();
    return (words[0].substring(0, 1) + words[1].substring(0, 1)).toUpperCase();
  }
}

class _ArtworkPainter extends CustomPainter {
  _ArtworkPainter({
    required this.seed,
    required this.dominant,
    required this.outline,
  });

  final int seed;
  final Color dominant;
  final Color outline;

  @override
  void paint(Canvas canvas, Size size) {
    final rand = math.Random(seed);
    final hsl = HSLColor.fromColor(dominant);

    // Two-stop gradient around the dominant hue, luminance clamped so the
    // overlaid initials keep contrast.
    final a = hsl
        .withLightness((hsl.lightness * 0.75).clamp(0.12, 0.42))
        .withSaturation((hsl.saturation * 1.05).clamp(0.2, 0.7))
        .toColor();
    final b = hsl
        .withHue((hsl.hue + 28 + rand.nextDouble() * 26) % 360)
        .withLightness((hsl.lightness * 1.25).clamp(0.22, 0.56))
        .toColor();

    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [a, b],
        ).createShader(rect),
    );

    // Geometric motif: concentric arcs, bars or a grid, chosen by seed.
    final motif = seed.abs() % 3;
    final ink = Paint()
      ..color = Colors.white.withOpacity(0.10)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, size.width / 44);

    switch (motif) {
      case 0:
        for (var i = 1; i <= 4; i++) {
          canvas.drawCircle(
            Offset(size.width * 0.74, size.height * 0.28),
            size.width * 0.16 * i,
            ink,
          );
        }
      case 1:
        for (var i = 0; i < 6; i++) {
          final x = size.width * (0.12 + i * 0.16);
          final h = size.height * (0.2 + rand.nextDouble() * 0.6);
          canvas.drawLine(
            Offset(x, size.height),
            Offset(x, size.height - h),
            ink..strokeWidth = math.max(1.5, size.width / 26),
          );
        }
      default:
        final step = size.width / 5;
        for (var i = 1; i < 5; i++) {
          canvas.drawLine(Offset(step * i, 0), Offset(step * i, size.height), ink);
          canvas.drawLine(Offset(0, step * i), Offset(size.width, step * i), ink);
        }
    }

    // Hairline so light-theme cards keep an edge against white surfaces.
    canvas.drawRect(
      rect.deflate(0.5),
      Paint()
        ..color = Colors.black.withOpacity(0.12)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_ArtworkPainter old) =>
      old.seed != seed || old.dominant != dominant;
}

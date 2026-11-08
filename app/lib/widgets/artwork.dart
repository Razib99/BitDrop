import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../src/rust/api/simple.dart' as rust;

import '../core_api/models.dart';
import '../providers/core_providers.dart';
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
    final radius =
        borderRadius ?? (size >= 200 ? Radii.heroArtR : Radii.gridArtR);
    
    Widget content;
    
    String? uri = artwork.uri;
    if (uri != null && uri.contains('unknown_artist__unknown_album')) {
      uri = null;
    }

    if ((uri == null || uri.isEmpty) && title != null && title!.isNotEmpty) {
      try {
        final cacheDir = globalArtworkCacheDir;
        if (cacheDir.isNotEmpty) {
          final clean = title!.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
          if (!clean.contains('unknown_artist__unknown_album')) {
            final f = File('$cacheDir/$clean.img');
            if (f.existsSync() && f.lengthSync() > 0) {
              uri = f.path;
            }
          }
        }
      } catch (_) {}
    }

    if (uri != null && uri.isNotEmpty) {
      if (uri.startsWith('http://') || uri.startsWith('https://')) {
        content = Image.network(
          uri,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildPlaceholder(context),
        );
      } else {
        String path = uri;
        if (path.startsWith('file://')) {
          path = Uri.parse(path).toFilePath();
        }
        if (path.contains('unknown_artist__unknown_album')) {
          content = _buildPlaceholder(context);
        } else if (_imageCache.containsKey(path)) {
          content = Image.memory(
            _imageCache[path]!,
            width: size,
            height: size,
            fit: BoxFit.cover,
          );
        } else {
          content = FutureBuilder<Uint8List?>(
            future: _loadArt(path),
            builder: (context, snapshot) {
              if (snapshot.hasData && snapshot.data != null) {
                return Image.memory(
                  snapshot.data!,
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                );
              }
              return _buildPlaceholder(context);
            },
          );
        }
      }
    } else {
      content = _buildPlaceholder(context);
    }

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
          child: content,
        ),
      ),
    );
  }

  static final Map<String, Uint8List> _imageCache = {};

  Future<Uint8List?> _loadArt(String path) async {
    if (path.contains('unknown_artist__unknown_album')) return null;
    if (_imageCache.containsKey(path)) return _imageCache[path];
    try {
      final f = File(path);
      if (!f.existsSync() || f.lengthSync() == 0) return null;
      final lower = path.toLowerCase();
      final isImage = lower.endsWith('.img') ||
          lower.endsWith('.jpg') ||
          lower.endsWith('.jpeg') ||
          lower.endsWith('.png') ||
          lower.endsWith('.webp');
      final Uint8List? data = isImage
          ? await f.readAsBytes()
          : rust.getCoverArt(path: path);
      if (data != null && data.isNotEmpty) _imageCache[path] = data;
      return data;
    } catch (e) {
      debugPrint('[art] could not load $path: $e');
      return null;
    }
  }

  Widget _buildPlaceholder(BuildContext context) {
    return Opacity(
      opacity: dimmed ? 0.45 : 1,
      child: Image.asset(
        'assets/default_artwork.jpg',
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => CustomPaint(
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
    );
  }  static String _initials(String title) {
    final words = title
        .split(RegExp(r'[\s,·]+'))
        .where(
            (w) => w.isNotEmpty && w[0].toUpperCase() == w[0] || w.isNotEmpty)
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
          canvas.drawLine(
              Offset(step * i, 0), Offset(step * i, size.height), ink);
          canvas.drawLine(
              Offset(0, step * i), Offset(size.width, step * i), ink);
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

/// A 2x2 album-art mosaic card per genre with graceful fallback to single artwork
/// or procedural themed gradient when fewer than 4 artworks are available.
class GenreMosaicArtwork extends StatelessWidget {
  const GenreMosaicArtwork({
    super.key,
    required this.genre,
    required this.size,
    this.borderRadius,
  });

  final Genre genre;
  final double size;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final radius =
        borderRadius ?? (size >= 200 ? Radii.heroArtR : Radii.gridArtR);
    final arts = genre.artworkPaths.where((p) => p.trim().isNotEmpty).toList();

    Widget content;
    if (arts.length >= 4) {
      final half = size / 2;
      content = Column(
        children: [
          Row(
            children: [
              _buildTile(arts[0], half, genre.name),
              _buildTile(arts[1], half, genre.name),
            ],
          ),
          Row(
            children: [
              _buildTile(arts[2], half, genre.name),
              _buildTile(arts[3], half, genre.name),
            ],
          ),
        ],
      );
    } else if (arts.isNotEmpty) {
      content = _buildTile(arts.first, size, genre.name);
    } else {
      content = _buildFallback(context);
    }

    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(
        width: size,
        height: size,
        child: content,
      ),
    );
  }

  Widget _buildTile(String path, double tileSize, String label) {
    return SizedBox(
      width: tileSize,
      height: tileSize,
      child: AlbumArtwork(
        artwork: Artwork(
          uri: path,
          seed: path.hashCode.abs(),
          dominantColor: 0xFF2196F3,
        ),
        size: tileSize,
        title: label,
        borderRadius: BorderRadius.zero,
      ),
    );
  }

  Widget _buildFallback(BuildContext context) {
    final seed = genre.name.hashCode.abs();
    final rand = math.Random(seed);
    final c1 = HSLColor.fromAHSL(
      1.0,
      (rand.nextDouble() * 360),
      0.65,
      0.45,
    ).toColor();
    final c2 = HSLColor.fromAHSL(
      1.0,
      ((c1.computeLuminance() * 360) + 60) % 360,
      0.75,
      0.25,
    ).toColor();

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [c1, c2],
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Opacity(
            opacity: 0.25,
            child: Icon(
              Icons.music_note_rounded,
              size: size * 0.45,
              color: Colors.white,
            ),
          ),
          Center(
            child: Text(
              genre.name.isNotEmpty ? genre.name[0].toUpperCase() : '?',
              style: TextStyle(
                fontSize: size * 0.35,
                fontWeight: FontWeight.bold,
                color: Colors.white.withOpacity(0.9),
                letterSpacing: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

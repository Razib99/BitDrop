import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import '../core_api/models.dart';
import '../providers/core_providers.dart';

/// Utilities for extracting, enhancing, and providing ambient poster colors
/// derived from music artwork across BitDrop.
class PosterColor {
  static final Map<String, Color> _cache = {};

  /// Normalizes and softens a base color to produce a gentle, velvety ambient aura.
  static Color enhance(Color base) {
    final hsl = HSLColor.fromColor(base);
    // If the color is grey or almost grayscale, preserve with subtle cool warmth
    if (hsl.saturation < 0.08) {
      return base.withOpacity(1.0);
    }
    // Soft, desaturated luminescence tailored for dark OLED backgrounds
    final s = (hsl.saturation * 0.72).clamp(0.26, 0.44);
    final l = hsl.lightness.clamp(0.24, 0.36);
    return hsl.withSaturation(s).withLightness(l).toColor();
  }

  /// Synchronous color provider: returns cached or enhanced dominantColor immediately.
  static Color of(Artwork artwork) {
    final key = artwork.uri ?? '${artwork.seed}';
    if (_cache.containsKey(key)) {
      return _cache[key]!;
    }
    final enhanced = enhance(Color(artwork.dominantColor));
    _cache[key] = enhanced;
    return enhanced;
  }

  /// Resolves the actual image file path for an artwork if it exists on disk.
  static String? resolveImagePath(Artwork artwork, {String? title}) {
    String? uri = artwork.uri;
    if ((uri == null || uri.isEmpty) && title != null && title.isNotEmpty) {
      try {
        final cacheDir = globalArtworkCacheDir;
        if (cacheDir.isNotEmpty) {
          final clean = title.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
          final f = File('$cacheDir/$clean.img');
          if (f.existsSync()) return f.path;
        }
      } catch (_) {}
    }
    if (uri != null && uri.isNotEmpty) {
      if (uri.startsWith('file://')) {
        return Uri.parse(uri).toFilePath();
      }
      return uri;
    }
    return null;
  }

  /// Asynchronously extracts the true dominant color from image bytes if available,
  /// falling back to the enhanced dominantColor.
  static Future<Color> resolve(Artwork artwork, {String? title}) async {
    final key = artwork.uri ?? '${artwork.seed}_$title';
    if (_cache.containsKey(key)) {
      return _cache[key]!;
    }

    final path = resolveImagePath(artwork, title: title);
    if (path != null && !path.startsWith('http')) {
      try {
        final file = File(path);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          final extracted = await extractFromBytes(bytes);
          if (extracted != null) {
            final enhanced = enhance(extracted);
            _cache[key] = enhanced;
            return enhanced;
          }
        }
      } catch (e) {
        debugPrint('[poster-color] extraction error: $e');
      }
    }

    final fallback = enhance(Color(artwork.dominantColor));
    _cache[key] = fallback;
    return fallback;
  }

  /// Fast extraction using a downsampled 24x24 thumbnail decode.
  static Future<Color?> extractFromBytes(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 24,
        targetHeight: 24,
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      codec.dispose();
      if (byteData == null) return null;

      final buffer = byteData.buffer.asUint8List();
      double maxScore = -1.0;
      int bestR = 128, bestG = 128, bestB = 128;
      int rSum = 0, gSum = 0, bSum = 0, count = 0;

      for (int i = 0; i < buffer.length; i += 4) {
        final r = buffer[i];
        final g = buffer[i + 1];
        final b = buffer[i + 2];
        final a = buffer[i + 3];
        if (a < 128) continue;

        final maxVal = math.max(r, math.max(g, b));
        final minVal = math.min(r, math.min(g, b));
        final delta = maxVal - minVal;
        final sat = maxVal == 0 ? 0.0 : delta / maxVal;
        final bright = maxVal / 255.0;

        // Score prioritizing vibrant, colorful elements over pure black or washed white
        if (bright > 0.12 && bright < 0.92) {
          final score = sat * 2.5 + (1.0 - (bright - 0.50).abs());
          if (score > maxScore) {
            maxScore = score;
            bestR = r;
            bestG = g;
            bestB = b;
          }
        }

        rSum += r;
        gSum += g;
        bSum += b;
        count++;
      }

      if (maxScore > 0.4) {
        return Color.fromARGB(255, bestR, bestG, bestB);
      } else if (count > 0) {
        return Color.fromARGB(255, rSum ~/ count, gSum ~/ count, bSum ~/ count);
      }
    } catch (_) {}
    return null;
  }
}

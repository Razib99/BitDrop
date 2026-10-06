import 'dart:math' as math;

import '../core_api/enums.dart';
import '../core_api/models.dart';

/// Biquad magnitude response, for drawing the EQ curve only.
///
/// The real filtering happens in the Rust core's 64-bit float DSP engine; this
/// is the display-side twin so the graph matches what the engine will do.
/// Coefficients follow the RBJ Audio EQ Cookbook.
abstract final class Biquad {
  /// Assumed sample rate for the drawn response. The curve shape above
  /// ~20 kHz is not shown, so any rate >= 44.1 kHz gives the same picture.
  static const double displayFs = 48000;

  /// Magnitude in dB at [hz] for a single band.
  static double magnitudeDb(EqBand band, double hz, {double fs = displayFs}) {
    if (!band.enabled) return 0;
    final (b0, b1, b2, a0, a1, a2) = _coefficients(band, fs);

    final w = 2 * math.pi * hz / fs;
    final cosW = math.cos(w);
    final sinW = math.sin(w);
    final cos2W = math.cos(2 * w);
    final sin2W = math.sin(2 * w);

    // H(z) at z = e^{jw}, evaluated as (b0 + b1 z^-1 + b2 z^-2) / (a0 + ...).
    final numRe = b0 + b1 * cosW + b2 * cos2W;
    final numIm = -(b1 * sinW + b2 * sin2W);
    final denRe = a0 + a1 * cosW + a2 * cos2W;
    final denIm = -(a1 * sinW + a2 * sin2W);

    final numMag = math.sqrt(numRe * numRe + numIm * numIm);
    final denMag = math.sqrt(denRe * denRe + denIm * denIm);
    if (denMag == 0) return 0;
    final ratio = numMag / denMag;
    if (ratio <= 0) return -120;
    return 20 * math.log(ratio) / math.ln10;
  }

  /// Summed response of every enabled band, plus [preampDb].
  static double combinedDb(
    List<EqBand> bands,
    double hz, {
    double preampDb = 0,
    double fs = displayFs,
  }) {
    var sum = preampDb;
    for (final b in bands) {
      sum += magnitudeDb(b, hz, fs: fs);
    }
    return sum;
  }

  /// Peak of the combined curve — what the auto-preamp suggestion is based on.
  static double peakDb(List<EqBand> bands, {double preampDb = 0}) {
    var peak = -120.0;
    for (var i = 0; i <= 160; i++) {
      final hz = logFrequencyAt(i / 160);
      final v = combinedDb(bands, hz, preampDb: preampDb);
      if (v > peak) peak = v;
    }
    return peak;
  }

  /// The preamp that brings the curve's peak back to 0 dB, rounded to 0.1.
  static double suggestedPreamp(List<EqBand> bands) {
    final peak = peakDb(bands);
    if (peak <= 0) return 0;
    return -((peak * 10).ceil() / 10);
  }

  static const double minHz = 20;
  static const double maxHz = 20000;

  /// Maps 0..1 across the graph's log frequency axis.
  static double logFrequencyAt(double t) =>
      minHz * math.pow(maxHz / minHz, t.clamp(0.0, 1.0)).toDouble();

  /// Inverse of [logFrequencyAt].
  static double positionOf(double hz) =>
      (math.log(hz.clamp(minHz, maxHz) / minHz) / math.log(maxHz / minHz))
          .clamp(0.0, 1.0);

  static (double, double, double, double, double, double) _coefficients(
    EqBand band,
    double fs,
  ) {
    final a = math.pow(10, band.gainDb / 40).toDouble();
    final w0 = 2 * math.pi * band.frequencyHz.clamp(10.0, fs / 2 - 10) / fs;
    final cosW0 = math.cos(w0);
    final q = band.q <= 0 ? 0.001 : band.q;
    final alpha = math.sin(w0) / (2 * q);
    final sqrtA = math.sqrt(a);

    switch (band.type) {
      case BiquadType.peak:
        return (
          1 + alpha * a,
          -2 * cosW0,
          1 - alpha * a,
          1 + alpha / a,
          -2 * cosW0,
          1 - alpha / a,
        );
      case BiquadType.lowShelf:
        return (
          a * ((a + 1) - (a - 1) * cosW0 + 2 * sqrtA * alpha),
          2 * a * ((a - 1) - (a + 1) * cosW0),
          a * ((a + 1) - (a - 1) * cosW0 - 2 * sqrtA * alpha),
          (a + 1) + (a - 1) * cosW0 + 2 * sqrtA * alpha,
          -2 * ((a - 1) + (a + 1) * cosW0),
          (a + 1) + (a - 1) * cosW0 - 2 * sqrtA * alpha,
        );
      case BiquadType.highShelf:
        return (
          a * ((a + 1) + (a - 1) * cosW0 + 2 * sqrtA * alpha),
          -2 * a * ((a - 1) + (a + 1) * cosW0),
          a * ((a + 1) + (a - 1) * cosW0 - 2 * sqrtA * alpha),
          (a + 1) - (a - 1) * cosW0 + 2 * sqrtA * alpha,
          2 * ((a - 1) - (a + 1) * cosW0),
          (a + 1) - (a - 1) * cosW0 - 2 * sqrtA * alpha,
        );
      case BiquadType.lowPass:
        return (
          (1 - cosW0) / 2,
          1 - cosW0,
          (1 - cosW0) / 2,
          1 + alpha,
          -2 * cosW0,
          1 - alpha,
        );
      case BiquadType.highPass:
        return (
          (1 + cosW0) / 2,
          -(1 + cosW0),
          (1 + cosW0) / 2,
          1 + alpha,
          -2 * cosW0,
          1 - alpha,
        );
    }
  }

  /// Converts the 10-band graphic EQ gains into equivalent peaking bands, so
  /// one curve renderer serves both modes.
  static List<EqBand> fromGraphicGains(List<double> gains, List<int> centers) {
    final out = <EqBand>[];
    for (var i = 0; i < gains.length && i < centers.length; i++) {
      out.add(EqBand(
        id: i + 1,
        type: BiquadType.peak,
        frequencyHz: centers[i].toDouble(),
        gainDb: gains[i],
        q: 1.41,
      ));
    }
    return out;
  }

  /// Bass/treble tone controls as a shelf pair.
  static List<EqBand> fromTone(double bassDb, double trebleDb) => [
        EqBand(
          id: 1,
          type: BiquadType.lowShelf,
          frequencyHz: 120,
          gainDb: bassDb,
          q: 0.7,
        ),
        EqBand(
          id: 2,
          type: BiquadType.highShelf,
          frequencyHz: 4000,
          gainDb: trebleDb,
          q: 0.7,
        ),
      ];
}

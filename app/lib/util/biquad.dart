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

  static const int maxEngineBands = 20;
  static const List<int> isoGraphicCenters = [
    31,
    62,
    125,
    250,
    500,
    1000,
    2000,
    4000,
    8000,
    16000,
  ];

  /// The preamp that brings the curve's peak back to 0 dB, rounded to 0.1.
  static double suggestedPreamp(List<EqBand> bands) {
    final peak = peakDb(bands);
    if (peak <= 0) return 0;
    return -((peak * 10).ceil() / 10);
  }

  /// Loudness-preserving psychoacoustic smart headroom (dB <= 0), matching Rust
  /// `compute_smart_headroom_db` so display & DSP headroom agree 1:1.
  static double smartHeadroomDb(List<EqBand> bands) {
    if (bands.isEmpty) return 0.0;
    var maxWeighted = 0.0;
    const steps = 160;
    for (var i = 0; i <= steps; i++) {
      final hz = logFrequencyAt(i / steps);
      final boost = combinedDb(bands, hz);
      if (boost <= 0) continue;
      final weight = hz <= 120.0
          ? 0.25
          : (hz >= 500.0 ? 0.55 : 0.25 + ((hz - 120.0) / 380.0) * 0.30);
      final weighted = boost * weight;
      if (weighted > maxWeighted) maxWeighted = weighted;
    }
    if (maxWeighted <= 1e-6) return 0.0;
    return -math.min(maxWeighted, 6.0);
  }

  /// Auto-headroom offset applied by Rust DSP given [eq]'s headroom mode.
  static double autoHeadroomOffsetDb(EqState eq, List<EqBand> bands) {
    if (eq.bypass || bands.isEmpty) return 0.0;
    if (eq.autoPreamp) return suggestedPreamp(bands);
    if (eq.smartHeadroom) return smartHeadroomDb(bands);
    return 0.0;
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

  /// Converts the 10-band graphic EQ gains into Rust-matched biquad bands:
  /// Band 0 (31 Hz slider) acts as a smooth 38 Hz low shelf (`Q = 0.75`) so
  /// sub-bass never suffers narrow-Q phase rolloff, while bands 1..9 use `Q = 1.15`.
  static List<EqBand> fromGraphicGains(
    List<double> gains, [
    List<int> centers = isoGraphicCenters,
  ]) {
    final out = <EqBand>[];
    for (var i = 0; i < gains.length && i < centers.length; i++) {
      if (i == 0) {
        out.add(EqBand(
          id: 1,
          type: BiquadType.lowShelf,
          frequencyHz: 38.0,
          gainDb: gains[0],
          q: 0.75,
        ));
      } else {
        out.add(EqBand(
          id: i + 1,
          type: BiquadType.peak,
          frequencyHz: centers[i].toDouble(),
          gainDb: gains[i],
          q: 1.15,
        ));
      }
    }
    return out;
  }

  /// Pultec-inspired Bass Contour + Treble Air stage:
  /// pairs a low-shelf boost with a subtle 185 Hz (`-0.22 * bassDb`) dip when
  /// bass is boosted so low-end hits stay punchy without low-mid wooliness.
  static List<EqBand> fromTone(
    double bassDb,
    double trebleDb, {
    double bassFreqHz = 65.0,
    double trebleFreqHz = 10000.0,
  }) {
    final out = <EqBand>[];
    if (bassDb.abs() > 0.01) {
      out.add(EqBand(
        id: -1,
        type: BiquadType.lowShelf,
        frequencyHz: bassFreqHz.clamp(30.0, 140.0),
        gainDb: bassDb,
        q: 0.88,
      ));
      if (bassDb > 0.5) {
        out.add(EqBand(
          id: -2,
          type: BiquadType.peak,
          frequencyHz: 185.0,
          gainDb: -math.min(0.22 * bassDb, 3.5),
          q: 1.25,
        ));
      }
    }
    if (trebleDb.abs() > 0.01) {
      out.add(EqBand(
        id: -3,
        type: BiquadType.highShelf,
        frequencyHz: trebleFreqHz.clamp(4000.0, 16000.0),
        gainDb: trebleDb,
        q: 0.75,
      ));
    }
    return out;
  }

  /// Composes the active Pultec Tone Contour stage together with whichever
  /// Graphic or Parametric EQ stage is selected, ready for both UI curve
  /// rendering and Rust `engineSetEq` transmission.
  static List<EqBand> composeBands(
    EqState eq, {
    List<int> graphicCenters = isoGraphicCenters,
  }) {
    final composed = <EqBand>[
      ...fromTone(
        eq.bassDb,
        eq.trebleDb,
        bassFreqHz: eq.bassFreqHz,
        trebleFreqHz: eq.trebleFreqHz,
      ),
    ];

    if (eq.mode == EqMode.graphic) {
      final padded = List<double>.generate(
        graphicCenters.length,
        (i) => i < eq.graphicGains.length ? eq.graphicGains[i] : 0.0,
      );
      composed.addAll(fromGraphicGains(padded, graphicCenters));
    } else if (eq.mode == EqMode.parametric) {
      composed.addAll(eq.bands.where((b) => b.enabled));
    }

    if (composed.length > maxEngineBands) {
      return composed.sublist(0, maxEngineBands);
    }
    return composed;
  }
}

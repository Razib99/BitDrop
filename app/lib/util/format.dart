import '../core_api/enums.dart';

/// Number and unit formatting. Everything here produces strings for *mono*
/// text styles, so the shapes are fixed-width where it matters.
abstract final class Fmt {
  /// `3:41` / `1:02:14`. Clamped so a negative never renders.
  static String duration(int ms) {
    final total = (ms < 0 ? 0 : ms) ~/ 1000;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = h > 0 ? m.toString().padLeft(2, '0') : m.toString();
    return h > 0
        ? '$h:$mm:${s.toString().padLeft(2, '0')}'
        : '$mm:${s.toString().padLeft(2, '0')}';
  }

  /// `-3:41` for remaining time.
  static String remaining(int positionMs, int durationMs) =>
      '−${duration(durationMs - positionMs)}';

  /// `58:31` style total for an album.
  static String longDuration(int ms) {
    final total = ms ~/ 1000;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    final s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// `1.42 GB`, `84.2 MB`. Decimal units, matching what cloud storage reports.
  static String bytes(int b) {
    if (b < 1000) return '$b B';
    const units = ['kB', 'MB', 'GB', 'TB'];
    var value = b / 1000.0;
    var i = 0;
    while (value >= 1000 && i < units.length - 1) {
      value /= 1000;
      i++;
    }
    final digits = value >= 100 ? 0 : (value >= 10 ? 1 : 2);
    return '${value.toStringAsFixed(digits)} ${units[i]}';
  }

  /// `-6.2 dB` with a true minus sign (U+2212), never a hyphen.
  static String db(double v, {int digits = 1}) {
    final sign = v < 0 ? '−' : (v > 0 ? '+' : '');
    return '$sign${v.abs().toStringAsFixed(digits)} dB';
  }

  /// `3.4 Mbps`
  static String mbps(double v) => '${v.toStringAsFixed(1)} Mbps';

  /// `2822 kbps` / `320 kbps`
  static String kbps(int? v) => v == null ? '—' : '$v kbps';

  /// `96 kHz`, `44.1 kHz`
  static String kHz(int hz) {
    final k = hz / 1000;
    final text =
        k == k.roundToDouble() ? k.round().toString() : k.toStringAsFixed(1);
    return '$text kHz';
  }

  /// `96` / `44.1` — bare, for arrows like `96 → 48 kHz`.
  static String kHzBare(int hz) {
    final k = hz / 1000;
    return k == k.roundToDouble() ? k.round().toString() : k.toStringAsFixed(1);
  }

  /// `1.2k`, `16k` for EQ frequency labels.
  static String hzShort(double hz) {
    if (hz >= 1000) {
      final k = hz / 1000;
      return k == k.roundToDouble()
          ? '${k.round()}k'
          : '${k.toStringAsFixed(1)}k';
    }
    return hz.round().toString();
  }

  /// `12,480` — grouped for readability in counters.
  static String count(int n) {
    final s = n.abs().toString();
    final buf = StringBuffer(n < 0 ? '-' : '');
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  static String percent(num fraction01, {int digits = 0}) =>
      '${(fraction01 * 100).toStringAsFixed(digits)}%';

  /// `5 min ago`, `just now`, `12 Sep`.
  static String relativeTime(DateTime? when) {
    if (when == null) return 'never';
    final diff = DateTime.now().difference(when);
    if (diff.inSeconds < 45) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    if (diff.inDays < 7) return '${diff.inDays} d ago';
    return '${when.day} ${_months[when.month - 1]}';
  }

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  /// `Q 0.70`
  static String q(double v) => v.toStringAsFixed(2);

  /// Biquad filter abbreviations, matching AutoEQ's own notation.
  static String biquad(BiquadType t) => switch (t) {
        BiquadType.peak => 'PK',
        BiquadType.lowShelf => 'LSC',
        BiquadType.highShelf => 'HSC',
        BiquadType.lowPass => 'LPQ',
        BiquadType.highPass => 'HPQ',
      };

  static String biquadLong(BiquadType t) => switch (t) {
        BiquadType.peak => 'Peak',
        BiquadType.lowShelf => 'Low shelf',
        BiquadType.highShelf => 'High shelf',
        BiquadType.lowPass => 'Low-pass',
        BiquadType.highPass => 'High-pass',
      };
}

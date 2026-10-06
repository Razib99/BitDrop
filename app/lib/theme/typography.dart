import 'package:flutter/material.dart';

/// BitDrop type scale.
///
/// Two families: Inter for UI, JetBrains Mono for every technical readout.
/// Mono styles carry [FontFeature.tabularFigures] so numbers never shift
/// width as they tick — required for sample rates, times, dB and Hz.
@immutable
class BitDropText extends ThemeExtension<BitDropText> {
  const BitDropText({
    required this.display,
    required this.headline,
    required this.title,
    required this.titleSmall,
    required this.body,
    required this.bodySmall,
    required this.label,
    required this.monoLabel,
    required this.monoReadout,
    required this.monoLarge,
  });

  final TextStyle display;
  final TextStyle headline;
  final TextStyle title;
  final TextStyle titleSmall;
  final TextStyle body;
  final TextStyle bodySmall;
  final TextStyle label;

  /// Uppercase badge text — format chips, tier chips.
  final TextStyle monoLabel;

  /// Inline technical values — `24/96`, `-6.2 dB`, `03:41`.
  final TextStyle monoReadout;

  /// Diagnostics and large meter values.
  final TextStyle monoLarge;

  static const _ui = 'Inter';
  static const _mono = 'JetBrainsMono';
  static const _tabular = <FontFeature>[FontFeature.tabularFigures()];

  static const scale = BitDropText(
    display: TextStyle(
      fontFamily: _ui,
      fontSize: 32,
      height: 40 / 32,
      fontWeight: FontWeight.w600,
    ),
    headline: TextStyle(
      fontFamily: _ui,
      fontSize: 24,
      height: 32 / 24,
      fontWeight: FontWeight.w600,
    ),
    title: TextStyle(
      fontFamily: _ui,
      fontSize: 20,
      height: 28 / 20,
      fontWeight: FontWeight.w600,
    ),
    titleSmall: TextStyle(
      fontFamily: _ui,
      fontSize: 16,
      height: 24 / 16,
      fontWeight: FontWeight.w600,
    ),
    body: TextStyle(
      fontFamily: _ui,
      fontSize: 15,
      height: 22 / 15,
      fontWeight: FontWeight.w400,
    ),
    bodySmall: TextStyle(
      fontFamily: _ui,
      fontSize: 13,
      height: 18 / 13,
      fontWeight: FontWeight.w400,
    ),
    label: TextStyle(
      fontFamily: _ui,
      fontSize: 12,
      height: 16 / 12,
      fontWeight: FontWeight.w500,
    ),
    monoLabel: TextStyle(
      fontFamily: _mono,
      fontSize: 11,
      height: 14 / 11,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.5,
      fontFeatures: _tabular,
    ),
    monoReadout: TextStyle(
      fontFamily: _mono,
      fontSize: 13,
      height: 18 / 13,
      fontWeight: FontWeight.w500,
      fontFeatures: _tabular,
    ),
    monoLarge: TextStyle(
      fontFamily: _mono,
      fontSize: 20,
      height: 26 / 20,
      fontWeight: FontWeight.w500,
      fontFeatures: _tabular,
    ),
  );

  /// Applies [color] to every style in the scale.
  BitDropText withDefaultColor(Color color) => BitDropText(
        display: display.copyWith(color: color),
        headline: headline.copyWith(color: color),
        title: title.copyWith(color: color),
        titleSmall: titleSmall.copyWith(color: color),
        body: body.copyWith(color: color),
        bodySmall: bodySmall.copyWith(color: color),
        label: label.copyWith(color: color),
        monoLabel: monoLabel.copyWith(color: color),
        monoReadout: monoReadout.copyWith(color: color),
        monoLarge: monoLarge.copyWith(color: color),
      );

  @override
  BitDropText copyWith({
    TextStyle? display,
    TextStyle? headline,
    TextStyle? title,
    TextStyle? titleSmall,
    TextStyle? body,
    TextStyle? bodySmall,
    TextStyle? label,
    TextStyle? monoLabel,
    TextStyle? monoReadout,
    TextStyle? monoLarge,
  }) {
    return BitDropText(
      display: display ?? this.display,
      headline: headline ?? this.headline,
      title: title ?? this.title,
      titleSmall: titleSmall ?? this.titleSmall,
      body: body ?? this.body,
      bodySmall: bodySmall ?? this.bodySmall,
      label: label ?? this.label,
      monoLabel: monoLabel ?? this.monoLabel,
      monoReadout: monoReadout ?? this.monoReadout,
      monoLarge: monoLarge ?? this.monoLarge,
    );
  }

  @override
  BitDropText lerp(covariant BitDropText? other, double t) {
    if (other == null) return this;
    return BitDropText(
      display: TextStyle.lerp(display, other.display, t)!,
      headline: TextStyle.lerp(headline, other.headline, t)!,
      title: TextStyle.lerp(title, other.title, t)!,
      titleSmall: TextStyle.lerp(titleSmall, other.titleSmall, t)!,
      body: TextStyle.lerp(body, other.body, t)!,
      bodySmall: TextStyle.lerp(bodySmall, other.bodySmall, t)!,
      label: TextStyle.lerp(label, other.label, t)!,
      monoLabel: TextStyle.lerp(monoLabel, other.monoLabel, t)!,
      monoReadout: TextStyle.lerp(monoReadout, other.monoReadout, t)!,
      monoLarge: TextStyle.lerp(monoLarge, other.monoLarge, t)!,
    );
  }
}

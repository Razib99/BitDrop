import 'package:flutter/material.dart';

/// BitDrop semantic color tokens.
///
/// Every colour the UI paints comes from here, exposed to widgets through
/// [BitDropColors] (a [ThemeExtension]). Widgets must never hard-code a colour.
@immutable
class BitDropColors extends ThemeExtension<BitDropColors> {
  const BitDropColors({
    required this.bg,
    required this.surface1,
    required this.surface2,
    required this.surface3,
    required this.outline,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.onAccent,
    required this.tierBitPerfect,
    required this.tierNativeRate,
    required this.tierResampled,
    required this.tierUnknown,
    required this.dspActive,
    required this.error,
    required this.success,
    required this.cacheFill,
    required this.shimmerBase,
    required this.shimmerHighlight,
  });

  final Color bg;
  final Color surface1;
  final Color surface2;
  final Color surface3;
  final Color outline;
  final Color textPrimary;
  final Color textSecondary;

  /// Disabled and decorative only — never body text (fails AA at body sizes).
  final Color textTertiary;
  final Color accent;
  final Color onAccent;
  final Color tierBitPerfect;
  final Color tierNativeRate;
  final Color tierResampled;
  final Color tierUnknown;
  final Color dspActive;
  final Color error;
  final Color success;

  /// Cached ranges on the seek bar.
  final Color cacheFill;
  final Color shimmerBase;
  final Color shimmerHighlight;

  /// Dark theme — near-black base with four surface steps instead of shadows.
  static const dark = BitDropColors(
    bg: Color(0xFF0E0F12),
    surface1: Color(0xFF16181D),
    surface2: Color(0xFF1D2027),
    surface3: Color(0xFF252932),
    outline: Color(0xFF2F3440),
    textPrimary: Color(0xFFF2F4F7),
    textSecondary: Color(0xFFA6ADBB),
    textTertiary: Color(0xFF6B7280),
    accent: Color(0xFF8B93FF),
    onAccent: Color(0xFF0E0F12),
    tierBitPerfect: Color(0xFF34D399),
    tierNativeRate: Color(0xFF38BDF8),
    tierResampled: Color(0xFFFBBF24),
    tierUnknown: Color(0xFFA6ADBB),
    dspActive: Color(0xFFF472B6),
    error: Color(0xFFF87171),
    success: Color(0xFF34D399),
    cacheFill: Color(0x598B93FF), // accent @ 35%
    shimmerBase: Color(0xFF1D2027),
    shimmerHighlight: Color(0xFF2F3440),
  );

  /// Light theme — warm-neutral paper base, soft shadows for elevation.
  static const light = BitDropColors(
    bg: Color(0xFFF7F7F9),
    surface1: Color(0xFFFFFFFF),
    surface2: Color(0xFFF1F2F5),
    surface3: Color(0xFFE7E9EE),
    outline: Color(0xFFD6D9E0),
    textPrimary: Color(0xFF0F1115),
    textSecondary: Color(0xFF4B5262),
    textTertiary: Color(0xFF8A90A0),
    accent: Color(0xFF4F46E5),
    onAccent: Color(0xFFFFFFFF),
    tierBitPerfect: Color(0xFF047857),
    tierNativeRate: Color(0xFF0369A1),
    tierResampled: Color(0xFFB45309),
    tierUnknown: Color(0xFF4B5262),
    dspActive: Color(0xFFBE185D),
    error: Color(0xFFB91C1C),
    success: Color(0xFF047857),
    cacheFill: Color(0x404F46E5), // accent @ 25%
    shimmerBase: Color(0xFFE7E9EE),
    shimmerHighlight: Color(0xFFF7F7F9),
  );

  /// OLED variant: pure black base, surfaces pulled down one step.
  BitDropColors get oled => copyWith(
        bg: const Color(0xFF000000),
        surface1: const Color(0xFF0B0C0E),
        surface2: const Color(0xFF14161A),
        surface3: const Color(0xFF1D2027),
      );

  @override
  BitDropColors copyWith({
    Color? bg,
    Color? surface1,
    Color? surface2,
    Color? surface3,
    Color? outline,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? accent,
    Color? onAccent,
    Color? tierBitPerfect,
    Color? tierNativeRate,
    Color? tierResampled,
    Color? tierUnknown,
    Color? dspActive,
    Color? error,
    Color? success,
    Color? cacheFill,
    Color? shimmerBase,
    Color? shimmerHighlight,
  }) {
    return BitDropColors(
      bg: bg ?? this.bg,
      surface1: surface1 ?? this.surface1,
      surface2: surface2 ?? this.surface2,
      surface3: surface3 ?? this.surface3,
      outline: outline ?? this.outline,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      tierBitPerfect: tierBitPerfect ?? this.tierBitPerfect,
      tierNativeRate: tierNativeRate ?? this.tierNativeRate,
      tierResampled: tierResampled ?? this.tierResampled,
      tierUnknown: tierUnknown ?? this.tierUnknown,
      dspActive: dspActive ?? this.dspActive,
      error: error ?? this.error,
      success: success ?? this.success,
      cacheFill: cacheFill ?? this.cacheFill,
      shimmerBase: shimmerBase ?? this.shimmerBase,
      shimmerHighlight: shimmerHighlight ?? this.shimmerHighlight,
    );
  }

  @override
  BitDropColors lerp(covariant BitDropColors? other, double t) {
    if (other == null) return this;
    return BitDropColors(
      bg: Color.lerp(bg, other.bg, t)!,
      surface1: Color.lerp(surface1, other.surface1, t)!,
      surface2: Color.lerp(surface2, other.surface2, t)!,
      surface3: Color.lerp(surface3, other.surface3, t)!,
      outline: Color.lerp(outline, other.outline, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      tierBitPerfect: Color.lerp(tierBitPerfect, other.tierBitPerfect, t)!,
      tierNativeRate: Color.lerp(tierNativeRate, other.tierNativeRate, t)!,
      tierResampled: Color.lerp(tierResampled, other.tierResampled, t)!,
      tierUnknown: Color.lerp(tierUnknown, other.tierUnknown, t)!,
      dspActive: Color.lerp(dspActive, other.dspActive, t)!,
      error: Color.lerp(error, other.error, t)!,
      success: Color.lerp(success, other.success, t)!,
      cacheFill: Color.lerp(cacheFill, other.cacheFill, t)!,
      shimmerBase: Color.lerp(shimmerBase, other.shimmerBase, t)!,
      shimmerHighlight:
          Color.lerp(shimmerHighlight, other.shimmerHighlight, t)!,
    );
  }
}

/// 4-pt spacing grid.
abstract final class Spacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 40;
  static const double huge = 56;

  /// Screen side margin: 16 on phones, 24 at tablet width.
  static double screenMargin(double width) => width >= 840 ? xl : md;
}

abstract final class Radii {
  static const double badge = 6;
  static const double chip = 10;
  static const double card = 14;
  static const double gridArt = 8;
  static const double heroArt = 16;
  static const double sheet = 24;

  static const BorderRadius badgeR = BorderRadius.all(Radius.circular(badge));
  static const BorderRadius chipR = BorderRadius.all(Radius.circular(chip));
  static const BorderRadius cardR = BorderRadius.all(Radius.circular(card));
  static const BorderRadius gridArtR =
      BorderRadius.all(Radius.circular(gridArt));
  static const BorderRadius heroArtR =
      BorderRadius.all(Radius.circular(heroArt));
  static const BorderRadius sheetR =
      BorderRadius.vertical(top: Radius.circular(sheet));
}

/// Motion durations and curves. Screens must route every animation through
/// these so the reduce-motion setting can collapse them to crossfades.
abstract final class Motion {
  static const Duration micro = Duration(milliseconds: 120);
  static const Duration standard = Duration(milliseconds: 220);
  static const Duration emphasized = Duration(milliseconds: 320);

  static const Curve enter = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;
  static const Curve emphasizedCurve = Curves.easeInOutCubicEmphasized;
}

/// Minimum interactive size — 48 dp per the accessibility requirement.
abstract final class Sizes {
  static const double touchTarget = 48;
  static const double miniPlayerHeight = 64;
  static const double trackArt = 48;
  static const double playButton = 72;
  static const double seekBarTrack = 6;
  static const double miniProgress = 2;
}

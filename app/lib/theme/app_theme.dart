import 'package:flutter/material.dart';

import 'tokens.dart';
import 'typography.dart';

/// Builds the Material 3 [ThemeData] for each mode and attaches the BitDrop
/// token extensions. Widgets read tokens through [BitDropThemeAccess].
abstract final class AppTheme {
  static ThemeData light() => _build(BitDropColors.light, Brightness.light);

  static ThemeData dark({bool oled = false}) => _build(
      oled ? BitDropColors.dark.oled : BitDropColors.dark, Brightness.dark);

  static ThemeData _build(BitDropColors c, Brightness brightness) {
    const text = BitDropText.scale;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: c.accent,
      onPrimary: c.onAccent,
      secondary: c.accent,
      onSecondary: c.onAccent,
      error: c.error,
      onError: brightness == Brightness.dark
          ? const Color(0xFF0E0F12)
          : const Color(0xFFFFFFFF),
      surface: c.surface1,
      onSurface: c.textPrimary,
      surfaceContainerLowest: c.bg,
      surfaceContainerLow: c.surface1,
      surfaceContainer: c.surface2,
      surfaceContainerHigh: c.surface3,
      surfaceContainerHighest: c.surface3,
      onSurfaceVariant: c.textSecondary,
      outline: c.outline,
      outlineVariant: c.outline,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: c.bg,
      canvasColor: c.bg,
      splashFactory: InkSparkle.splashFactory,
      fontFamily: 'Inter',
      visualDensity: VisualDensity.standard,
      textTheme: TextTheme(
        displayLarge: text.display,
        headlineMedium: text.headline,
        titleLarge: text.title,
        titleMedium: text.titleSmall,
        bodyMedium: text.body,
        bodySmall: text.bodySmall,
        labelMedium: text.label,
      ).apply(
        bodyColor: c.textPrimary,
        displayColor: c.textPrimary,
      ),
      dividerTheme: DividerThemeData(color: c.outline, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: c.bg,
        surfaceTintColor: Colors.transparent,
        foregroundColor: c.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.title.copyWith(color: c.textPrimary),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface1,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: Radii.sheetR),
        showDragHandle: true,
        dragHandleColor: c.outline,
      ),
      cardTheme: CardTheme(
        color: c.surface1,
        surfaceTintColor: Colors.transparent,
        elevation: brightness == Brightness.light ? 1 : 0,
        shadowColor: brightness == Brightness.light
            ? Colors.black.withOpacity(0.08)
            : Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: Radii.cardR),
        margin: EdgeInsets.zero,
      ),
      dialogTheme: DialogTheme(
        backgroundColor: c.surface1,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: Radii.cardR),
        titleTextStyle: text.titleSmall.copyWith(color: c.textPrimary),
        contentTextStyle: text.body.copyWith(color: c.textSecondary),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.surface3,
        contentTextStyle: text.body.copyWith(color: c.textPrimary),
        actionTextColor: c.accent,
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: Radii.chipR),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.accent,
          foregroundColor: c.onAccent,
          textStyle: text.titleSmall,
          minimumSize: const Size(0, Sizes.touchTarget),
          padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
          shape: const RoundedRectangleBorder(borderRadius: Radii.chipR),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.textPrimary,
          textStyle: text.titleSmall,
          minimumSize: const Size(0, Sizes.touchTarget),
          padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
          side: BorderSide(color: c.outline),
          shape: const RoundedRectangleBorder(borderRadius: Radii.chipR),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: c.accent,
          textStyle: text.titleSmall,
          minimumSize: const Size(0, Sizes.touchTarget),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: c.textPrimary,
          minimumSize: const Size(Sizes.touchTarget, Sizes.touchTarget),
        ),
      ),
      iconTheme: IconThemeData(color: c.textPrimary, size: 24),
      listTileTheme: ListTileThemeData(
        iconColor: c.textSecondary,
        textColor: c.textPrimary,
        titleTextStyle: text.body.copyWith(color: c.textPrimary),
        subtitleTextStyle: text.bodySmall.copyWith(color: c.textSecondary),
        minVerticalPadding: Spacing.sm,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) =>
              s.contains(WidgetState.selected) ? c.onAccent : c.textSecondary,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.accent : c.surface3,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) =>
              s.contains(WidgetState.selected) ? Colors.transparent : c.outline,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: c.accent,
        inactiveTrackColor: c.surface3,
        thumbColor: c.accent,
        overlayColor: c.accent.withOpacity(0.12),
        trackHeight: Sizes.seekBarTrack,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.accent,
        linearTrackColor: c.surface3,
        circularTrackColor: c.surface3,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: c.surface2,
        selectedColor: c.accent,
        side: BorderSide(color: c.outline),
        labelStyle: text.label.copyWith(color: c.textPrimary),
        shape: const RoundedRectangleBorder(borderRadius: Radii.chipR),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surface3,
        hintStyle: text.body.copyWith(color: c.textTertiary),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.sm,
        ),
        border: OutlineInputBorder(
          borderRadius: Radii.chipR,
          borderSide: BorderSide(color: c.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: Radii.chipR,
          borderSide: BorderSide(color: c.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: Radii.chipR,
          borderSide: BorderSide(color: c.accent, width: 2),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: c.surface1,
        surfaceTintColor: Colors.transparent,
        indicatorColor: c.accent.withOpacity(0.16),
        height: 64,
        labelTextStyle: WidgetStatePropertyAll(
          text.label.copyWith(color: c.textSecondary),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(
            color:
                s.contains(WidgetState.selected) ? c.accent : c.textSecondary,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: c.surface1,
        indicatorColor: c.accent.withOpacity(0.16),
        selectedIconTheme: IconThemeData(color: c.accent),
        unselectedIconTheme: IconThemeData(color: c.textSecondary),
        selectedLabelTextStyle: text.label.copyWith(color: c.accent),
        unselectedLabelTextStyle: text.label.copyWith(color: c.textSecondary),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: c.surface3,
          borderRadius: Radii.badgeR,
        ),
        textStyle: text.bodySmall.copyWith(color: c.textPrimary),
      ),
      extensions: <ThemeExtension<dynamic>>[
        c,
        BitDropText.scale.withDefaultColor(c.textPrimary),
      ],
    );
  }
}

/// Short accessors so widgets read `context.c.accent` and `context.t.monoReadout`
/// instead of reaching for `Theme.of(context).extension<...>()!` each time.
extension BitDropThemeAccess on BuildContext {
  BitDropColors get c => Theme.of(this).extension<BitDropColors>()!;
  BitDropText get t => Theme.of(this).extension<BitDropText>()!;
}

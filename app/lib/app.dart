import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core_api/settings.dart';
import 'l10n/app_localizations.dart';
import 'providers/core_providers.dart';
import 'routing/router.dart';
import 'theme/app_theme.dart';

/// Root widget: binds theme mode, OLED and text scale to the core's settings
/// so the scenario switcher and the Settings screen drive the same state.
class BitDropApp extends ConsumerWidget {
  const BitDropApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsValueProvider);
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'BitDrop',
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      themeMode: switch (settings.themeMode) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      },
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(oled: settings.oledBlack),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            // The switcher's text-scale presets override the OS value so the
            // 200% check is reproducible on any device.
            textScaler: settings.textScale == 1.0
                ? media.textScaler
                : TextScaler.linear(settings.textScale),
            disableAnimations: settings.reduceMotion || media.disableAnimations,
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// Debug-only overrides read from the process environment.
///
/// They let a headless run open straight onto a given screen in a given
/// scenario, which is how the screenshots in `DESIGN.md` are produced. In a
/// release build every getter returns null.
abstract final class DevEnv {
  static String? _get(String key) {
    if (!kDebugMode) return null;
    final v = Platform.environment[key];
    return (v == null || v.isEmpty) ? null : v;
  }

  /// `BITDROP_ROUTE=/now-playing`
  static String? get initialRoute => _get('BITDROP_ROUTE');

  /// `BITDROP_SCENARIO=bit-perfect`
  static String? get scenarioId => _get('BITDROP_SCENARIO');

  /// `BITDROP_THEME=dark|light`
  static String? get theme => _get('BITDROP_THEME');

  /// `BITDROP_TEXT_SCALE=2.0`
  static double? get textScale {
    final v = _get('BITDROP_TEXT_SCALE');
    return v == null ? null : double.tryParse(v);
  }
}

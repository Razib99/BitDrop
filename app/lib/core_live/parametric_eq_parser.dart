import 'dart:convert';
import 'package:flutter/foundation.dart';

import '../core_api/enums.dart';
import '../core_api/models.dart';
import '../src/rust/api/cloud_library.dart';

/// Result of parsing an EqualizerAPO / Peace / REW / AutoEQ parametric EQ text file.
@immutable
class ParametricEqImportResult {
  const ParametricEqImportResult({
    required this.bands,
    this.preampDb,
  });

  final List<EqBand> bands;
  final double? preampDb;
}

/// Parser for parametric equalizer configuration files in EqualizerAPO / Peace / REW format.
abstract final class ParametricEqParser {
  static final RegExp _preampRegex = RegExp(
    r'Preamp:\s*(-?[\d.]+)\s*(?:dB)?',
    caseSensitive: false,
  );

  static final RegExp _filterRegex = RegExp(
    r'Filter\s+(\d+):\s*(ON|OFF)\s+([A-Za-z0-9]+)\s+Fc\s+([\d.]+)\s*Hz'
    r'(?:\s+Gain\s+(-?[\d.]+)\s*(?:dB)?)?(?:\s+Q\s+([\d.]+))?',
    caseSensitive: false,
  );

  /// Parses text in standard EqualizerAPO / AutoEQ ParametricEQ.txt format:
  /// ```text
  /// Preamp: -6.2 dB
  /// Filter 1: ON PK Fc 105 Hz Gain 3.4 dB Q 0.70
  /// Filter 2: ON LSC Fc 212 Hz Gain -1.8 dB Q 1.10
  /// ```
  static ParametricEqImportResult parse(String text) {
    double? preamp;
    final preampMatch = _preampRegex.firstMatch(text);
    if (preampMatch != null) {
      preamp = double.tryParse(preampMatch.group(1)!);
    }

    final bands = <EqBand>[];
    for (final match in _filterRegex.allMatches(text)) {
      final id = int.tryParse(match.group(1)!) ?? (bands.length + 1);
      final enabled = match.group(2)!.toUpperCase() == 'ON';
      final typeStr = match.group(3)!.toUpperCase();
      final freq = double.tryParse(match.group(4)!) ?? 1000.0;
      final gain = double.tryParse(match.group(5) ?? '0') ?? 0.0;
      final q = double.tryParse(match.group(6) ?? '1.414') ?? 1.414;

      final biquadType = switch (typeStr) {
        'LSC' || 'LS' || 'LOWSHELF' => BiquadType.lowShelf,
        'HSC' || 'HS' || 'HIGHSHELF' => BiquadType.highShelf,
        'LPQ' || 'LP' || 'LOWPASS' => BiquadType.lowPass,
        'HPQ' || 'HP' || 'HIGHPASS' => BiquadType.highPass,
        _ => BiquadType.peak,
      };

      bands.add(EqBand(
        id: id,
        type: biquadType,
        frequencyHz: freq,
        gainDb: gain,
        q: q,
        enabled: enabled,
      ));
    }

    return ParametricEqImportResult(
      bands: bands,
      preampDb: preamp,
    );
  }

  /// Parses JSON bands string stored in SQLite `autoeq_profiles.bands_json`.
  static List<EqBand> parseBandsJson(String jsonStr) {
    try {
      final list = jsonDecode(jsonStr);
      if (list is! List) return const [];
      final result = <EqBand>[];
      for (final raw in list) {
        if (raw is Map) {
          final typeName = raw['type'] as String?;
          final bType = BiquadType.values
                  .where((e) => e.name == typeName)
                  .firstOrNull ??
              (typeName != null
                  ? switch (typeName.toUpperCase()) {
                      'LSC' || 'LS' => BiquadType.lowShelf,
                      'HSC' || 'HS' => BiquadType.highShelf,
                      'LPQ' || 'LP' => BiquadType.lowPass,
                      'HPQ' || 'HP' => BiquadType.highPass,
                      _ => BiquadType.peak,
                    }
                  : BiquadType.peak);

          result.add(EqBand(
            id: (raw['id'] as num?)?.toInt() ?? (result.length + 1),
            type: bType,
            frequencyHz: (raw['frequencyHz'] as num?)?.toDouble() ?? 1000.0,
            gainDb: (raw['gainDb'] as num?)?.toDouble() ?? 0.0,
            q: (raw['q'] as num?)?.toDouble() ?? 1.414,
            enabled: raw['enabled'] as bool? ?? true,
          ));
        }
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  /// Encodes a list of [EqBand] into JSON for SQLite storage.
  static String encodeBandsJson(List<EqBand> bands) {
    final list = bands
        .map((b) => {
              'id': b.id,
              'type': b.type.name,
              'frequencyHz': b.frequencyHz,
              'gainDb': b.gainDb,
              'q': b.q,
              'enabled': b.enabled,
            })
        .toList();
    return jsonEncode(list);
  }

  /// Converts an FRB [AutoEqProfileData] row from Rust into a Dart [AutoEqProfile].
  static AutoEqProfile toAutoEqProfile(AutoEqProfileData data) {
    return AutoEqProfile(
      id: data.id,
      model: data.model,
      measurementSource: data.source,
      target: data.target,
      suggestedPreampDb: data.suggestedPreampDb,
      bands: parseBandsJson(data.bandsJson),
    );
  }

  /// Exports an AutoEQ profile or bands to EqualizerAPO / Peace format text.
  static String exportToParametricEq({
    required List<EqBand> bands,
    double? preampDb,
  }) {
    final buf = StringBuffer();
    if (preampDb != null && preampDb != 0) {
      buf.writeln('Preamp: ${preampDb.toStringAsFixed(1)} dB');
    }
    for (int i = 0; i < bands.length; i++) {
      final b = bands[i];
      final status = b.enabled ? 'ON' : 'OFF';
      final typeStr = switch (b.type) {
        BiquadType.peak => 'PK',
        BiquadType.lowShelf => 'LSC',
        BiquadType.highShelf => 'HSC',
        BiquadType.lowPass => 'LPQ',
        BiquadType.highPass => 'HPQ',
      };
      buf.writeln(
        'Filter ${i + 1}: $status $typeStr '
        'Fc ${b.frequencyHz.toStringAsFixed(1)} Hz '
        'Gain ${b.gainDb.toStringAsFixed(1)} dB '
        'Q ${b.q.toStringAsFixed(2)}',
      );
    }
    return buf.toString();
  }
}

import 'dart:io';

import 'package:bitdrop/core_api/commands.dart';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/core_live/audio_handler.dart';
import 'package:bitdrop/core_live/live_core.dart';
import 'package:bitdrop/core_live/parametric_eq_parser.dart';
import 'package:bitdrop/src/rust/api/cloud_library.dart' as rust_db;
import 'package:bitdrop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Initialize Rust library for testing
    try {
      final soPath = File('rust/target/debug/librust_lib_bitdrop.so').existsSync()
          ? 'rust/target/debug/librust_lib_bitdrop.so'
          : '${Directory.current.path}/rust/target/debug/librust_lib_bitdrop.so';
      await RustLib.init(externalLibrary: ExternalLibrary.open(soPath));
    } catch (_) {
      try {
        await RustLib.init();
      } catch (_) {}
    }
  });

  group('ParametricEqParser Tests', () {
    test('Parses standard EqualizerAPO / AutoEQ ParametricEQ.txt', () {
      const text = '''
Preamp: -6.2 dB
Filter 1: ON PK Fc 105 Hz Gain 3.4 dB Q 0.70
Filter 2: ON LSC Fc 212 Hz Gain -1.8 dB Q 1.10
Filter 3: ON HSC Fc 10500 Hz Gain 1.6 dB Q 0.70
Filter 4: OFF PK Fc 5200 Hz Gain 2.1 dB Q 2.80
Filter 5: ON LPQ Fc 18000 Hz Gain 0.0 dB Q 0.71
Filter 6: ON HPQ Fc 20 Hz Gain 0.0 dB Q 0.71
''';

      final result = ParametricEqParser.parse(text);
      expect(result.preampDb, -6.2);
      expect(result.bands.length, 6);

      // Filter 1
      expect(result.bands[0].id, 1);
      expect(result.bands[0].type, BiquadType.peak);
      expect(result.bands[0].frequencyHz, 105.0);
      expect(result.bands[0].gainDb, 3.4);
      expect(result.bands[0].q, 0.70);
      expect(result.bands[0].enabled, isTrue);

      // Filter 2 (low shelf)
      expect(result.bands[1].id, 2);
      expect(result.bands[1].type, BiquadType.lowShelf);
      expect(result.bands[1].frequencyHz, 212.0);
      expect(result.bands[1].gainDb, -1.8);
      expect(result.bands[1].q, 1.10);
      expect(result.bands[1].enabled, isTrue);

      // Filter 3 (high shelf)
      expect(result.bands[2].id, 3);
      expect(result.bands[2].type, BiquadType.highShelf);
      expect(result.bands[2].frequencyHz, 10500.0);
      expect(result.bands[2].gainDb, 1.6);
      expect(result.bands[2].q, 0.70);
      expect(result.bands[2].enabled, isTrue);

      // Filter 4 (disabled peak)
      expect(result.bands[3].id, 4);
      expect(result.bands[3].type, BiquadType.peak);
      expect(result.bands[3].frequencyHz, 5200.0);
      expect(result.bands[3].gainDb, 2.1);
      expect(result.bands[3].q, 2.80);
      expect(result.bands[3].enabled, isFalse);

      // Filter 5 (low pass)
      expect(result.bands[4].id, 5);
      expect(result.bands[4].type, BiquadType.lowPass);
      expect(result.bands[4].frequencyHz, 18000.0);
      expect(result.bands[4].gainDb, 0.0);
      expect(result.bands[4].q, 0.71);
      expect(result.bands[4].enabled, isTrue);

      // Filter 6 (high pass)
      expect(result.bands[5].id, 6);
      expect(result.bands[5].type, BiquadType.highPass);
      expect(result.bands[5].frequencyHz, 20.0);
      expect(result.bands[5].gainDb, 0.0);
      expect(result.bands[5].q, 0.71);
      expect(result.bands[5].enabled, isTrue);
    });

    test('Parses format without preamp and shorthand filter types (LS, HS, LP, HP)', () {
      const text = '''
Filter 1: ON LS Fc 80.0 Hz Gain 4.0 dB Q 0.7
Filter 2: ON HS Fc 12000.0 Hz Gain -3.0 dB Q 0.7
Filter 3: ON LP Fc 20000.0 Hz Q 0.707
Filter 4: ON HP Fc 15.0 Hz Q 0.707
''';

      final result = ParametricEqParser.parse(text);
      expect(result.preampDb, isNull);
      expect(result.bands.length, 4);

      expect(result.bands[0].type, BiquadType.lowShelf);
      expect(result.bands[0].frequencyHz, 80.0);
      expect(result.bands[0].gainDb, 4.0);

      expect(result.bands[1].type, BiquadType.highShelf);
      expect(result.bands[1].frequencyHz, 12000.0);
      expect(result.bands[1].gainDb, -3.0);

      expect(result.bands[2].type, BiquadType.lowPass);
      expect(result.bands[2].frequencyHz, 20000.0);

      expect(result.bands[3].type, BiquadType.highPass);
      expect(result.bands[3].frequencyHz, 15.0);
    });

    test('Encodes and decodes bands JSON for SQLite roundtrip', () {
      const original = [
        EqBand(id: 1, type: BiquadType.lowShelf, frequencyHz: 105, gainDb: 3.4, q: 0.7),
        EqBand(id: 2, type: BiquadType.peak, frequencyHz: 2500, gainDb: -2.5, q: 2.0, enabled: false),
        EqBand(id: 3, type: BiquadType.highShelf, frequencyHz: 10000, gainDb: 1.5, q: 0.71),
      ];

      final json = ParametricEqParser.encodeBandsJson(original);
      final restored = ParametricEqParser.parseBandsJson(json);

      expect(restored.length, 3);
      expect(restored[0].id, 1);
      expect(restored[0].type, BiquadType.lowShelf);
      expect(restored[0].frequencyHz, 105.0);
      expect(restored[0].gainDb, 3.4);
      expect(restored[0].q, 0.7);
      expect(restored[0].enabled, isTrue);

      expect(restored[1].id, 2);
      expect(restored[1].type, BiquadType.peak);
      expect(restored[1].frequencyHz, 2500.0);
      expect(restored[1].gainDb, -2.5);
      expect(restored[1].q, 2.0);
      expect(restored[1].enabled, isFalse);

      expect(restored[2].id, 3);
      expect(restored[2].type, BiquadType.highShelf);
      expect(restored[2].frequencyHz, 10000.0);
      expect(restored[2].gainDb, 1.5);
    });

    test('Exports bands and preamp to ParametricEQ format', () {
      const bands = [
        EqBand(id: 1, type: BiquadType.lowShelf, frequencyHz: 105, gainDb: 3.4, q: 0.7),
        EqBand(id: 2, type: BiquadType.peak, frequencyHz: 2500, gainDb: -2.5, q: 2.0),
      ];

      final text = ParametricEqParser.exportToParametricEq(bands: bands, preampDb: -5.0);
      expect(text, contains('Preamp: -5.0 dB'));
      expect(text, contains('Filter 1: ON LSC Fc 105.0 Hz Gain 3.4 dB Q 0.70'));
      expect(text, contains('Filter 2: ON PK Fc 2500.0 Hz Gain -2.5 dB Q 2.00'));

      // Roundtrip through parse
      final reParsed = ParametricEqParser.parse(text);
      expect(reParsed.preampDb, -5.0);
      expect(reParsed.bands.length, 2);
      expect(reParsed.bands[0].type, BiquadType.lowShelf);
      expect(reParsed.bands[1].type, BiquadType.peak);
    });
  });

  group('LiveBitDropCore Real AutoEQ Database and Import', () {
    late Directory tempDir;
    late Directory cacheDir;
    late LiveBitDropCore liveCore;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('bitdrop_autoeq_test_');
      cacheDir = Directory('${tempDir.path}/cache')..createSync(recursive: true);
      final dbPath = '${cacheDir.path}/library.db';
      await rust_db.cloudLibraryOpen(dbPath: dbPath, cacheDir: cacheDir.path);

      final handler = BitDropAudioHandler();
      liveCore = LiveBitDropCore(
        handler,
        chunkCacheDir: cacheDir.path,
      );
    });

    tearDown(() {
      liveCore.dispose();
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('searchAutoEq retrieves profiles from SQLite database', () async {
      // 1. Search all (empty query)
      final all = await liveCore.searchAutoEq('');
      expect(all.length, greaterThanOrEqualTo(24), reason: 'Must return at least 24 curated profiles');

      // 2. Search Sennheiser brand
      final sennheiser = await liveCore.searchAutoEq('Sennheiser');
      expect(sennheiser.length, greaterThanOrEqualTo(4));
      for (final p in sennheiser) {
        expect(p.model.toLowerCase(), contains('sennheiser'));
      }

      // 3. Search DUNU Titan
      final titan = await liveCore.searchAutoEq('Titan');
      expect(titan.length, greaterThanOrEqualTo(2));
      expect(titan.any((p) => p.model == 'DUNU Titan X'), isTrue);
      expect(titan.any((p) => p.model == 'DUNU Titan S'), isTrue);
    });

    test('ApplyAutoEqProfile applies curated profile bands and preamp', () async {
      await liveCore.send(const ApplyAutoEqProfile('aeq-titanx'));

      final eq = await liveCore.eq.first;
      expect(eq.mode, EqMode.parametric);
      expect(eq.presetName, 'DUNU Titan X AutoEQ');
      expect(eq.preampDb, -6.2);
      expect(eq.bypass, isFalse);
      expect(eq.bands.length, 7);

      // Verify specific band details
      final b1 = eq.bands[0];
      expect(b1.type, BiquadType.lowShelf);
      expect(b1.frequencyHz, 105.0);
      expect(b1.gainDb, 3.4);
      expect(b1.q, 0.70);
    });

    test('ImportParametricEq parses text and updates EQ state with parametric bands', () async {
      const peacePreset = '''
Preamp: -4.5 dB
Filter 1: ON PK Fc 65 Hz Gain 5.2 dB Q 1.41
Filter 2: ON PK Fc 3500 Hz Gain -3.8 dB Q 2.50
Filter 3: ON HSC Fc 9000 Hz Gain 2.0 dB Q 0.71
''';

      await liveCore.send(const ImportParametricEq(peacePreset));

      final eq = await liveCore.eq.first;
      expect(eq.mode, EqMode.parametric);
      expect(eq.presetName, 'Imported preset');
      expect(eq.preampDb, -4.5);
      expect(eq.bypass, isFalse);
      expect(eq.bands.length, 3);

      expect(eq.bands[0].frequencyHz, 65.0);
      expect(eq.bands[0].gainDb, 5.2);
      expect(eq.bands[0].q, 1.41);

      expect(eq.bands[1].frequencyHz, 3500.0);
      expect(eq.bands[1].gainDb, -3.8);

      expect(eq.bands[2].type, BiquadType.highShelf);
      expect(eq.bands[2].frequencyHz, 9000.0);
      expect(eq.bands[2].gainDb, 2.0);
    });
  });
}

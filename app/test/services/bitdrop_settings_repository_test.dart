import 'dart:io';
import 'package:bitdrop/core_api/commands.dart';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/core_api/settings.dart';
import 'package:bitdrop/services/bitdrop_settings_repository.dart';
import 'package:bitdrop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    const soPath =
        '/home/razib/Desktop/BitDrop/app/rust/target/debug/librust_lib_bitdrop.so';
    if (File(soPath).existsSync()) {
      try {
        await RustLib.init(externalLibrary: ExternalLibrary.open(soPath));
      } catch (_) {}
    }
  });

  group('BitDropSettingsRepository Unit Tests', () {
    late BitDropSettingsRepository repo;
    AppSettings? lastNotifiedSettings;
    EqState? lastNotifiedEq;

    setUp(() {
      lastNotifiedSettings = null;
      lastNotifiedEq = null;
      repo = BitDropSettingsRepository(
        onSettingsChanged: (s) => lastNotifiedSettings = s,
        onEqChanged: (e) => lastNotifiedEq = e,
      );
    });

    tearDown(() {
      repo.dispose();
    });

    test('Initializes with default settings and EQ state', () {
      expect(repo.currentSettings.gapless, isTrue);
      expect(repo.currentSettings.directUsbDriver, isFalse);
      expect(repo.currentEq.mode, equals(EqMode.graphic));
      expect(repo.currentEq.bypass, isTrue);
      expect(repo.currentDeviceProfiles, isNotEmpty);
    });

    test('handleSetSetting updates settings stream and invokes callback', () async {
      await repo.handleSetSetting(
        const SetSetting(key: 'gapless', value: false),
      );
      expect(repo.currentSettings.gapless, isFalse);
      expect(lastNotifiedSettings?.gapless, isFalse);

      await repo.handleSetSetting(
        const SetSetting(key: 'directUsbDriver', value: true),
      );
      expect(repo.currentSettings.directUsbDriver, isTrue);
      expect(lastNotifiedSettings?.directUsbDriver, isTrue);
    });

    test('handleSetSafetyAttenuation updates safety settings', () async {
      await repo.handleSetSafetyAttenuation(
        const SetSafetyAttenuation(enabled: true, db: -15.0),
      );
      expect(repo.currentSettings.safetyAttenuationEnabled, isTrue);
      expect(repo.currentSettings.safetyAttenuationDb, equals(-15.0));
      expect(lastNotifiedSettings?.safetyAttenuationDb, equals(-15.0));
    });

    test('handleSetEqBands updates EQ state to parametric mode', () async {
      const testBands = [
        EqBand(
          id: 1,
          type: BiquadType.peak,
          frequencyHz: 100.0,
          gainDb: 3.5,
          q: 1.0,
          enabled: true,
        ),
      ];
      await repo.handleSetEqBands(const SetEqBands(testBands));

      expect(repo.currentEq.mode, equals(EqMode.parametric));
      expect(repo.currentEq.bands.length, equals(1));
      expect(repo.currentEq.bands.first.gainDb, equals(3.5));
      expect(lastNotifiedEq?.mode, equals(EqMode.parametric));
    });

    test('handleSetGraphicGains updates graphic gains in graphic mode', () async {
      final gains = [1.0, 2.0, -1.0, 0.0, 0.5, -2.0, 3.0, 0.0, 1.5, -0.5];
      await repo.handleSetGraphicGains(SetGraphicGains(gains));

      expect(repo.currentEq.mode, equals(EqMode.graphic));
      expect(repo.currentEq.graphicGains, equals(gains));
      expect(repo.currentEq.bypass, isFalse);
    });

    test('handleSetTone updates simple tone controls', () async {
      await repo.handleSetTone(const SetTone(
        bassDb: 4.0,
        trebleDb: -2.5,
        balance: -0.2,
        mono: true,
      ));

      expect(repo.currentEq.mode, equals(EqMode.simple));
      expect(repo.currentEq.bassDb, equals(4.0));
      expect(repo.currentEq.trebleDb, equals(-2.5));
      expect(repo.currentEq.balance, equals(-0.2));
      expect(repo.currentEq.mono, isTrue);
    });

    test('handleSetBypass toggles DSP bypass', () async {
      await repo.handleSetBypass(const SetBypass(true));
      expect(repo.currentEq.bypass, isTrue);

      await repo.handleSetBypass(const SetBypass(false));
      expect(repo.currentEq.bypass, isFalse);
    });

    test('handleSetPreamp updates preamp gain and clipping calculation', () async {
      await repo.handleSetPreamp(const SetPreamp(3.0));
      expect(repo.currentEq.preampDb, equals(3.0));
      expect(repo.currentEq.clippedSamples, greaterThan(0));

      await repo.handleSetPreamp(const SetPreamp(-2.0));
      expect(repo.currentEq.preampDb, equals(-2.0));
      expect(repo.currentEq.clippedSamples, equals(0));
    });

    test('handleSetReplayGain updates both eq and settings', () async {
      await repo.handleSetReplayGain(const SetReplayGain(
        mode: ReplayGainMode.album,
        preampDb: -1.5,
      ));

      expect(repo.currentEq.replayGain, equals(ReplayGainMode.album));
      expect(repo.currentEq.replayGainPreampDb, equals(-1.5));
      expect(repo.currentSettings.replayGain, equals(ReplayGainMode.album));
    });

    test('handleAssignEqToDevice links profile to device', () async {
      const dev = OutputDevice(
        id: 'dev-titanx',
        name: 'DUNU Titan X',
        type: DeviceType.usb,
        supportedRates: [44100, 48000, 96000],
        bitDepths: [16, 24],
        hardwareVolume: HardwareVolume.unknown,
        maxTier: OutputTier.bitPerfect,
      );

      await repo.handleAssignEqToDevice(
        const AssignEqToDevice(deviceId: 'dev-titanx', assign: true),
        dev,
      );

      expect(repo.currentEq.assignedDeviceName, equals('DUNU Titan X'));
      final profile = repo.currentDeviceProfiles
          .firstWhere((p) => p.deviceId == 'dev-titanx');
      expect(profile.eqPresetName, isNotNull);
    });

    test('handleImportParametricEq parses Peace/REW format and applies', () async {
      const config = '''
Preamp: -4.5 dB
Filter 1: ON PK Fc 105 Hz Gain 3.0 dB Q 1.41
Filter 2: ON LSC Fc 80 Hz Gain 2.0 dB Q 0.71
''';
      await repo.handleImportParametricEq(const ImportParametricEq(config));

      expect(repo.currentEq.mode, equals(EqMode.parametric));
      expect(repo.currentEq.preampDb, equals(-4.5));
      expect(repo.currentEq.bands.length, equals(2));
      expect(repo.currentEq.presetName, equals('Imported Parametric EQ'));
    });
  });
}

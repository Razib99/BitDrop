import 'dart:io';
import 'package:bitdrop/core_api/commands.dart';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/core_api/settings.dart';
import 'package:bitdrop/core_live/persistence_codec.dart';
import 'package:bitdrop/services/bitdrop_settings_repository.dart';
import 'package:bitdrop/src/rust/api/audio_engine.dart' as rust_audio;
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

      await repo.handleSetSetting(
        const SetSetting(key: 'conserveCellularData', value: true),
      );
      expect(repo.currentSettings.conserveCellularData, isTrue);
      expect(repo.currentSettings.networkTransportMode,
          equals(NetworkTransportMode.meteredCellular));
      expect(lastNotifiedSettings?.conserveCellularData, isTrue);
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

    test('handleSetCrossfeed updates eq, engine dsp_active, and persists',
        () async {
      // Ensure EQ is bypassed and ReplayGain is off before toggling crossfeed.
      await repo.handleSetBypass(const SetBypass(true));
      await repo.handleSetReplayGain(
        const SetReplayGain(mode: ReplayGainMode.off, preampDb: 0.0),
      );
      await repo.handleSetCrossfeed(const SetCrossfeed(CrossfeedPreset.chuMoy));

      expect(repo.currentEq.crossfeed, equals(CrossfeedPreset.chuMoy));
      expect(repo.currentEq.isActive, isTrue);
      expect(
        BitDropSettingsRepository.describeDspChain(repo.currentEq),
        contains('BS2B Crossfeed (Chu Moy)'),
      );
      expect(rust_audio.engineOutputState().dspActive, isTrue);

      final roundTripped = PersistenceCodec.deserializeEqState(
        PersistenceCodec.serializeEqState(repo.currentEq),
      );
      expect(roundTripped.crossfeed, equals(CrossfeedPreset.chuMoy));

      await repo.handleSetCrossfeed(const SetCrossfeed(CrossfeedPreset.off));
      expect(rust_audio.engineOutputState().dspActive, isFalse);
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

    test('exportBackupJson exports valid JSON payload with recap metrics', () async {
      await repo.handleSetSetting(const SetSetting(key: 'gapless', value: false));
      const recap = ListeningRecap(
        totalMinutesListened: 120,
        totalPlays: 25,
        topTracks: [
          RecapTrackItem(
            fileId: 'track-1',
            title: 'Comfortably Numb',
            artist: 'Pink Floyd',
            playCount: 10,
            totalMinutes: 62,
          ),
        ],
        topArtists: [
          RecapArtistItem(
            artist: 'Pink Floyd',
            playCount: 15,
            totalMinutes: 90,
          ),
        ],
        topGenre: 'Progressive Rock',
        losslessPercentage: 92.5,
        hiResPercentage: 65.0,
      );

      final jsonStr = await repo.exportBackupJson(recap: recap);
      expect(jsonStr, contains('"app": "BitDrop"'));
      expect(jsonStr, contains('"gapless": false'));
      expect(jsonStr, contains('"Comfortably Numb"'));
      expect(jsonStr, contains('"Pink Floyd"'));
      expect(jsonStr, contains('"Progressive Rock"'));
    });

    test('importBackupJson restores settings, eq state, and device profiles', () async {
      const backupJson = '''
{
  "version": 1,
  "app": "BitDrop",
  "app_settings": {
    "gapless": false,
    "directUsbDriver": true,
    "safetyAttenuationEnabled": true,
    "safetyAttenuationDb": -20.0
  },
  "eq_state": {
    "mode": "parametric",
    "preampDb": -3.5,
    "bypass": false,
    "bands": [
      {
        "id": 1,
        "type": "peak",
        "frequencyHz": 120.0,
        "gainDb": 4.0,
        "q": 1.2,
        "enabled": true
      }
    ]
  },
  "device_profiles": [
    {
      "deviceId": "custom-dac",
      "deviceName": "Custom Audiophile DAC",
      "replayGain": "album",
      "autoApply": true
    }
  ]
}
''';
      final ok = await repo.importBackupJson(backupJson);
      expect(ok, isTrue);
      expect(repo.currentSettings.gapless, isFalse);
      expect(repo.currentSettings.directUsbDriver, isTrue);
      expect(repo.currentSettings.safetyAttenuationDb, equals(-20.0));
      expect(repo.currentEq.mode, equals(EqMode.parametric));
      expect(repo.currentEq.preampDb, equals(-3.5));
      expect(repo.currentEq.bands.length, equals(1));
      expect(repo.currentEq.bands.first.frequencyHz, equals(120.0));
      expect(repo.currentDeviceProfiles.any((p) => p.deviceId == 'custom-dac'), isTrue);
    });

    test('exportBackupJson includes schemaVersion, cloud_providers and recap', () async {
      const providers = [
        {
          'provider_id': 'webdav-nas',
          'name': 'Synology NAS',
          'base_url': 'https://nas.local:5006',
          'root_folder': '/Music/FLAC',
        }
      ];

      final jsonStr = await repo.exportBackupJson(cloudProviderConfigs: providers);
      expect(jsonStr, contains('"schemaVersion": 1'));
      expect(jsonStr, contains('"provider_id": "webdav-nas"'));
      expect(jsonStr, contains('"Synology NAS"'));
      expect(jsonStr, contains('"https://nas.local:5006"'));
    });

    test('importBackupJson rejects unsupported schemaVersion and invalid app', () async {
      const futureVersionJson = '''
{
  "schemaVersion": 99,
  "app": "BitDrop",
  "app_settings": {}
}
''';
      expect(await repo.importBackupJson(futureVersionJson), isFalse);

      const invalidAppJson = '''
{
  "schemaVersion": 1,
  "app": "OtherPlayer",
  "app_settings": {}
}
''';
      expect(await repo.importBackupJson(invalidAppJson), isFalse);
    });

    test('importBackupJson rejects malformed JSON cleanly without exception', () async {
      expect(await repo.importBackupJson('not valid json {[[['), isFalse);
      expect(await repo.importBackupJson('["array", "not", "map"]'), isFalse);
    });

    test('export and import roundtrip preserves app settings and eq state', () async {
      await repo.handleSetSetting(const SetSetting(key: 'gapless', value: false));
      await repo.handleSetSetting(const SetSetting(key: 'directUsbDriver', value: true));

      final exported = await repo.exportBackupJson();
      final newRepo = BitDropSettingsRepository();
      final success = await newRepo.importBackupJson(exported);
      expect(success, isTrue);
      expect(newRepo.currentSettings.gapless, isFalse);
      expect(newRepo.currentSettings.directUsbDriver, isTrue);
    });
  });
}

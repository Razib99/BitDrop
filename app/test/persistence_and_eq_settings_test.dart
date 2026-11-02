import 'dart:io';

import 'package:bitdrop/core_api/commands.dart';
import 'package:bitdrop/core_api/enums.dart';
import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/core_api/settings.dart';
import 'package:bitdrop/core_live/audio_handler.dart';
import 'package:bitdrop/core_live/live_core.dart';
import 'package:bitdrop/core_live/persistence_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PersistenceCodec Roundtrips', () {
    test('EqState roundtrip serialization and deserialization', () {
      final initial = EqState(
        mode: EqMode.parametric,
        bands: const [
          EqBand(
            id: 1,
            type: BiquadType.peak,
            frequencyHz: 2500,
            gainDb: 3.5,
            q: 1.8,
            enabled: true,
          ),
          EqBand(
            id: 2,
            type: BiquadType.lowShelf,
            frequencyHz: 120,
            gainDb: -2.0,
            q: 0.707,
            enabled: false,
          ),
        ],
        preampDb: -3.5,
        bypass: false,
        graphicGains: const [1.0, 2.0, 3.0, 0, 0, -1.0, -2.0, -3.0, 0, 1.5],
        bassDb: 2.0,
        trebleDb: -1.0,
        balance: -0.2,
        mono: true,
        replayGain: ReplayGainMode.album,
        replayGainPreampDb: 6.0,
        presetName: 'Test Preset',
        assignedDeviceName: 'DUNU Titan X',
      );

      final json = PersistenceCodec.serializeEqState(initial);
      final restored = PersistenceCodec.deserializeEqState(json);

      expect(restored.mode, EqMode.parametric);
      expect(restored.bypass, isFalse);
      expect(restored.preampDb, -3.5);
      expect(restored.graphicGains, [1.0, 2.0, 3.0, 0, 0, -1.0, -2.0, -3.0, 0, 1.5]);
      expect(restored.bassDb, 2.0);
      expect(restored.trebleDb, -1.0);
      expect(restored.balance, -0.2);
      expect(restored.mono, isTrue);
      expect(restored.replayGain, ReplayGainMode.album);
      expect(restored.replayGainPreampDb, 6.0);
      expect(restored.presetName, 'Test Preset');
      expect(restored.assignedDeviceName, 'DUNU Titan X');
      expect(restored.bands.length, 2);
      expect(restored.bands[0].id, 1);
      expect(restored.bands[0].type, BiquadType.peak);
      expect(restored.bands[0].frequencyHz, 2500);
      expect(restored.bands[0].gainDb, 3.5);
      expect(restored.bands[0].q, 1.8);
      expect(restored.bands[0].enabled, isTrue);
      expect(restored.bands[1].id, 2);
      expect(restored.bands[1].type, BiquadType.lowShelf);
      expect(restored.bands[1].enabled, isFalse);
    });

    test('AppSettings roundtrip serialization and deserialization', () {
      const initial = AppSettings(
        themeMode: AppThemeMode.dark,
        oledBlack: true,
        nowPlayingStyle: NowPlayingStyle.minimal,
        adaptiveColor: false,
        reduceMotion: true,
        textScale: 1.3,
        formatBadges: BadgeVisibility.hiResOnly,
        gridDensity: GridDensity.compact,
        showTechnicalDetails: true,
        preferBitPerfect: true,
        safetyAttenuationEnabled: true,
        safetyAttenuationDb: -6.0,
        gapless: true,
        crossfadeSeconds: 3,
        replayGain: ReplayGainMode.track,
        resumeOnHeadsetConnect: false,
        sleepTimerDefaultMinutes: 45,
        mobileDataPolicy: MobileDataPolicy.stream,
        prefetchPolicy: PrefetchPolicy.always,
        bufferProfile: BufferProfile.safe,
        showUnsupportedFiles: false,
        groupCompilations: false,
        ignoreLeadingThe: false,
        artistSeparators: ' & ',
        scanWifiOnly: false,
        includeSharedDrives: true,
        artworkPreference: ArtworkPreference.folderImage,
        notificationsEnabled: false,
        lockScreenArtwork: false,
      );

      final json = PersistenceCodec.serializeAppSettings(initial);
      final restored = PersistenceCodec.deserializeAppSettings(json);

      expect(restored.themeMode, AppThemeMode.dark);
      expect(restored.oledBlack, isTrue);
      expect(restored.nowPlayingStyle, NowPlayingStyle.minimal);
      expect(restored.adaptiveColor, isFalse);
      expect(restored.reduceMotion, isTrue);
      expect(restored.textScale, 1.3);
      expect(restored.formatBadges, BadgeVisibility.hiResOnly);
      expect(restored.gridDensity, GridDensity.compact);
      expect(restored.showTechnicalDetails, isTrue);
      expect(restored.safetyAttenuationEnabled, isTrue);
      expect(restored.safetyAttenuationDb, -6.0);
      expect(restored.crossfadeSeconds, 3);
      expect(restored.replayGain, ReplayGainMode.track);
      expect(restored.resumeOnHeadsetConnect, isFalse);
      expect(restored.sleepTimerDefaultMinutes, 45);
      expect(restored.mobileDataPolicy, MobileDataPolicy.stream);
      expect(restored.prefetchPolicy, PrefetchPolicy.always);
      expect(restored.bufferProfile, BufferProfile.safe);
      expect(restored.showUnsupportedFiles, isFalse);
      expect(restored.groupCompilations, isFalse);
      expect(restored.ignoreLeadingThe, isFalse);
      expect(restored.artistSeparators, ' & ');
      expect(restored.scanWifiOnly, isFalse);
      expect(restored.includeSharedDrives, isTrue);
      expect(restored.artworkPreference, ArtworkPreference.folderImage);
      expect(restored.notificationsEnabled, isFalse);
      expect(restored.lockScreenArtwork, isFalse);
    });

    test('DeviceProfile list roundtrip serialization and deserialization', () {
      final initial = const [
        DeviceProfile(
          deviceId: 'dev-usb-1',
          deviceName: 'FiiO KA17',
          eqPresetName: 'Warm Tilt',
          replayGain: ReplayGainMode.track,
          safetyAttenuationDb: -3.0,
          preferredVolumeDb: -14.0,
          autoApply: true,
        ),
        DeviceProfile(
          deviceId: 'dev-bt-1',
          deviceName: 'Sony WH-1000XM4',
          eqPresetName: null,
          replayGain: ReplayGainMode.off,
          autoApply: false,
        ),
      ];

      final json = PersistenceCodec.serializeDeviceProfiles(initial);
      final restored = PersistenceCodec.deserializeDeviceProfiles(json);

      expect(restored.length, 2);
      expect(restored[0].deviceId, 'dev-usb-1');
      expect(restored[0].deviceName, 'FiiO KA17');
      expect(restored[0].eqPresetName, 'Warm Tilt');
      expect(restored[0].replayGain, ReplayGainMode.track);
      expect(restored[0].safetyAttenuationDb, -3.0);
      expect(restored[0].preferredVolumeDb, -14.0);
      expect(restored[0].autoApply, isTrue);

      expect(restored[1].deviceId, 'dev-bt-1');
      expect(restored[1].deviceName, 'Sony WH-1000XM4');
      expect(restored[1].eqPresetName, isNull);
      expect(restored[1].autoApply, isFalse);
    });
  });

  group('LiveBitDropCore Settings and EQ State Dispatching', () {
    late Directory tempDir;
    late Directory cacheDir;
    late LiveBitDropCore liveCore;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('bitdrop_test_core_');
      cacheDir = Directory('${tempDir.path}/cache')..createSync(recursive: true);
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

    test('SetSetting updates settings stream', () async {
      await liveCore.send(const SetSetting(key: 'oledBlack', value: true));
      final s1 = await liveCore.settings.first;
      expect(s1.oledBlack, isTrue);

      await liveCore.send(const SetSetting(key: 'textScale', value: 1.3));
      final s2 = await liveCore.settings.first;
      expect(s2.textScale, 1.3);

      await liveCore.send(const SetSafetyAttenuation(enabled: true, db: -15.0));
      final s3 = await liveCore.settings.first;
      expect(s3.safetyAttenuationEnabled, isTrue);
      expect(s3.safetyAttenuationDb, -15.0);
    });

    test('EQ commands update eq stream with correct mode and parameters', () async {
      // 1. Graphic EQ
      await liveCore.send(const SetGraphicGains([1.0, 2.0, 3.0, 0, 0, 0, 0, 0, 0, -2.0]));
      var eq = await liveCore.eq.first;
      expect(eq.mode, EqMode.graphic);
      expect(eq.bypass, isFalse);
      expect(eq.graphicGains[0], 1.0);
      expect(eq.graphicGains[1], 2.0);
      expect(eq.graphicGains[9], -2.0);

      // 2. Preamp
      await liveCore.send(const SetPreamp(-3.0));
      eq = await liveCore.eq.first;
      expect(eq.preampDb, -3.0);

      // 3. Bypass
      await liveCore.send(const SetBypass(true));
      eq = await liveCore.eq.first;
      expect(eq.bypass, isTrue);

      // 4. Simple Tone Mode
      await liveCore.send(const SetTone(bassDb: 4.0, trebleDb: -2.0, balance: 0.1, mono: true));
      eq = await liveCore.eq.first;
      expect(eq.mode, EqMode.simple);
      expect(eq.bassDb, 4.0);
      expect(eq.trebleDb, -2.0);
      expect(eq.balance, 0.1);
      expect(eq.mono, isTrue);
      expect(eq.bypass, isFalse);

      // 5. Parametric Mode
      const testBands = [
        EqBand(id: 0, type: BiquadType.peak, frequencyHz: 1000, gainDb: 2.5, q: 1.414),
      ];
      await liveCore.send(const SetEqBands(testBands));
      eq = await liveCore.eq.first;
      expect(eq.mode, EqMode.parametric);
      expect(eq.bands.length, 1);
      expect(eq.bands[0].gainDb, 2.5);
    });

    test('AssignEqToDevice updates assigned device and device profile', () async {
      await liveCore.send(const SetGraphicGains([0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
      await liveCore.send(const AssignEqToDevice(deviceId: 'dev-titanx', assign: true));

      final eq = await liveCore.eq.first;
      expect(eq.assignedDeviceName, isNotNull);

      final profiles = await liveCore.deviceProfiles.first;
      final titan = profiles.firstWhere((p) => p.deviceId == 'dev-titanx');
      expect(titan.eqPresetName, isNotNull);
    });
  });
}

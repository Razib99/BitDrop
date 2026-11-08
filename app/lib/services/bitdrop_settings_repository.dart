import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:rxdart/rxdart.dart';

import '../core_api/commands.dart';
import '../core_api/enums.dart';
import '../core_api/models.dart';
import '../core_api/settings.dart';
import '../core_live/parametric_eq_parser.dart';
import '../core_live/persistence_codec.dart';
import '../src/rust/api/audio_engine.dart' as rust;
import '../src/rust/api/cloud_library.dart' as rust_cache;
import '../util/biquad.dart';

/// Manages and persists user preferences, EQ presets, AutoEQ profiles,
/// device EQ profile mappings, and audio engine DSP state.
class BitDropSettingsRepository {
  final _settings = BehaviorSubject<AppSettings>.seeded(const AppSettings());
  final _eq = BehaviorSubject<EqState>.seeded(PersistenceCodec.defaultEqState());
  final _deviceProfiles = BehaviorSubject<List<DeviceProfile>>.seeded(const [
    DeviceProfile(
      deviceId: 'dev-titanx',
      deviceName: 'DUNU Titan X',
      replayGain: ReplayGainMode.off,
    ),
    DeviceProfile(
      deviceId: 'dev-qudelix',
      deviceName: 'Qudelix 5K',
      replayGain: ReplayGainMode.album,
    ),
    DeviceProfile(
      deviceId: 'dev-schiit',
      deviceName: 'Schiit Hel',
      replayGain: ReplayGainMode.track,
    ),
    DeviceProfile(
      deviceId: 'dev-s23-spk',
      deviceName: 'Phone Speaker',
      replayGain: ReplayGainMode.off,
    ),
  ]);

  void Function(AppSettings settings)? onSettingsChanged;
  void Function(EqState eq)? onEqChanged;
  Track? Function()? currentTrackProvider;

  BitDropSettingsRepository({
    this.onSettingsChanged,
    this.onEqChanged,
    this.currentTrackProvider,
  });

  Stream<AppSettings> get settings => _settings.stream;
  AppSettings get currentSettings => _settings.value;

  Stream<EqState> get eq => _eq.stream;
  EqState get currentEq => _eq.value;

  Stream<List<DeviceProfile>> get deviceProfiles => _deviceProfiles.stream;
  List<DeviceProfile> get currentDeviceProfiles => _deviceProfiles.value;

  Future<void> loadSettingsAndEq() async {
    try {
      final eqJson = await rust_cache.cloudDbGetKv(key: 'eq_state');
      if (eqJson != null && eqJson.isNotEmpty) {
        final loadedEq = PersistenceCodec.deserializeEqState(eqJson);
        _eq.add(loadedEq);
        pushEqToEngine(loadedEq);
      }
    } catch (e) {
      debugPrint('[persistence] failed to restore eq state: $e');
    }

    try {
      final settingsJson = await rust_cache.cloudDbGetKv(key: 'app_settings');
      if (settingsJson != null && settingsJson.isNotEmpty) {
        final loadedSettings =
            PersistenceCodec.deserializeAppSettings(settingsJson);
        _settings.add(loadedSettings);
        onSettingsChanged?.call(loadedSettings);
      }
    } catch (e) {
      debugPrint('[persistence] failed to restore app settings: $e');
    }

    try {
      final profilesJson =
          await rust_cache.cloudDbGetKv(key: 'device_profiles');
      if (profilesJson != null && profilesJson.isNotEmpty) {
        final loadedProfiles =
            PersistenceCodec.deserializeDeviceProfiles(profilesJson);
        if (loadedProfiles.isNotEmpty) {
          _deviceProfiles.add(loadedProfiles);
        }
      }
    } catch (e) {
      debugPrint('[persistence] failed to restore device profiles: $e');
    }
  }

  Future<void> saveEqState() async {
    try {
      final json = PersistenceCodec.serializeEqState(_eq.value);
      await rust_cache.cloudDbSetKv(key: 'eq_state', value: json);
    } catch (e) {
      debugPrint('[persistence] failed to save eq state: $e');
    }
  }

  Future<void> saveSettings() async {
    try {
      final json = PersistenceCodec.serializeAppSettings(_settings.value);
      await rust_cache.cloudDbSetKv(key: 'app_settings', value: json);
    } catch (e) {
      debugPrint('[persistence] failed to save app settings: $e');
    }
  }

  Future<void> saveDeviceProfiles() async {
    try {
      final json =
          PersistenceCodec.serializeDeviceProfiles(_deviceProfiles.value);
      await rust_cache.cloudDbSetKv(key: 'device_profiles', value: json);
    } catch (e) {
      debugPrint('[persistence] failed to save device profiles: $e');
    }
  }

  /// Exports app preferences, EQ presets, device profiles, and optional listening recap
  /// to a portable, human-readable JSON string formatted for 1-tap backup.
  Future<String> exportBackupJson({ListeningRecap? recap}) async {
    final payload = <String, dynamic>{
      'version': 1,
      'app': 'BitDrop',
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'app_settings':
          jsonDecode(PersistenceCodec.serializeAppSettings(_settings.value)),
      'eq_state': jsonDecode(PersistenceCodec.serializeEqState(_eq.value)),
      'device_profiles': jsonDecode(
          PersistenceCodec.serializeDeviceProfiles(_deviceProfiles.value)),
    };
    if (recap != null) {
      payload['listening_recap'] = {
        'totalMinutesListened': recap.totalMinutesListened,
        'losslessPlaybackPercent': recap.losslessPercentage,
        'hiResPlaybackPercent': recap.hiResPercentage,
        'topGenre': recap.topGenre,
        'topTracks': recap.topTracks
            .map((t) => {
                  'fileId': t.fileId,
                  'title': t.title,
                  'artist': t.artist,
                  'playCount': t.playCount,
                  'totalMinutes': t.totalMinutes,
                })
            .toList(),
        'topArtists': recap.topArtists
            .map((a) => {
                  'artist': a.artist,
                  'playCount': a.playCount,
                  'totalMinutes': a.totalMinutes,
                })
            .toList(),
      };
    }
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// Restores app settings, EQ preset state, and device profile mappings from
  /// a backup JSON string, persisting to SQLite and updating DSP engine state.
  Future<bool> importBackupJson(String jsonStr) async {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map) return false;

      if (decoded.containsKey('app_settings')) {
        final sJson = jsonEncode(decoded['app_settings']);
        final loaded = PersistenceCodec.deserializeAppSettings(sJson);
        _settings.add(loaded);
        await saveSettings();
        onSettingsChanged?.call(loaded);
      }

      if (decoded.containsKey('eq_state')) {
        final eqJson = jsonEncode(decoded['eq_state']);
        final loaded = PersistenceCodec.deserializeEqState(eqJson);
        _eq.add(loaded);
        pushEqToEngine(loaded);
        await saveEqState();
      }

      if (decoded.containsKey('device_profiles')) {
        final dpJson = jsonEncode(decoded['device_profiles']);
        final loaded = PersistenceCodec.deserializeDeviceProfiles(dpJson);
        if (loaded.isNotEmpty) {
          _deviceProfiles.add(loaded);
          await saveDeviceProfiles();
        }
      }

      return true;
    } catch (e) {
      debugPrint('[persistence] failed to import backup json: $e');
      return false;
    }
  }

  void pushEqToEngine([EqState? state]) {
    final eqState = state ?? _eq.value;

    double effectivePreamp = eqState.preampDb;
    if (eqState.replayGain != ReplayGainMode.off) {
      final currentTrack = currentTrackProvider?.call();
      if (currentTrack?.replayGainDb != null) {
        effectivePreamp += currentTrack!.replayGainDb!;
      } else {
        effectivePreamp += eqState.replayGainPreampDb;
      }
    }

    final balance = eqState.balance;
    final mono = eqState.mono ? 1.0 : 0.0;

    final List<double> enginePayload;

    if (eqState.mode == EqMode.simple) {
      final toneBands = Biquad.fromTone(eqState.bassDb, eqState.trebleDb);
      enginePayload = [
        -999.0,
        toneBands.length.toDouble(),
        for (final b in toneBands) ...[
          b.type.index.toDouble(),
          b.frequencyHz,
          b.gainDb,
          b.q,
        ],
        effectivePreamp,
        balance,
        mono,
      ];
    } else if (eqState.mode == EqMode.parametric) {
      final activeBands = eqState.bands.where((b) => b.enabled).toList();
      enginePayload = [
        -999.0,
        activeBands.length.toDouble(),
        for (final b in activeBands) ...[
          b.type.index.toDouble(),
          b.frequencyHz,
          b.gainDb,
          b.q,
        ],
        effectivePreamp,
        balance,
        mono,
      ];
    } else {
      // EqMode.graphic
      final gains = eqState.graphicGains.isNotEmpty
          ? List<double>.from(eqState.graphicGains.take(10))
          : List.filled(10, 0.0);
      while (gains.length < 10) {
        gains.add(0.0);
      }
      enginePayload = [
        ...gains,
        effectivePreamp,
        balance,
        mono,
      ];
    }

    try {
      rust.engineSetEq(gains: enginePayload);
      rust.engineSetEqEnabled(enabled: !eqState.bypass);
    } catch (_) {}
    onEqChanged?.call(eqState);
  }

  Future<void> handleSetSetting(SetSetting cmd) async {
    final updated = _settings.value.withKey(cmd.key, cmd.value);
    _settings.add(updated);
    await saveSettings();
    onSettingsChanged?.call(updated);
  }

  Future<void> handleSetSafetyAttenuation(SetSafetyAttenuation cmd) async {
    final updated = _settings.value.copyWith(
      safetyAttenuationEnabled: cmd.enabled,
      safetyAttenuationDb: cmd.db ?? _settings.value.safetyAttenuationDb,
    );
    _settings.add(updated);
    await saveSettings();
    onSettingsChanged?.call(updated);
  }

  Future<void> handleSetEqBands(SetEqBands cmd) async {
    final updated = _eq.value.copyWith(
      bands: cmd.bands,
      mode: EqMode.parametric,
      bypass: false,
    );
    _eq.add(updated);
    pushEqToEngine(updated);
    await saveEqState();
  }

  Future<void> handleSetEqMode(SetEqMode cmd) async {
    final updated = _eq.value.copyWith(mode: cmd.mode);
    _eq.add(updated);
    pushEqToEngine(updated);
    await saveEqState();
  }

  Future<void> handleSetGraphicGains(SetGraphicGains cmd) async {
    final updated = _eq.value.copyWith(
      graphicGains: cmd.gains,
      mode: EqMode.graphic,
      bypass: false,
    );
    _eq.add(updated);
    pushEqToEngine(updated);
    await saveEqState();
  }

  Future<void> handleSetBypass(SetBypass cmd) async {
    final updated = _eq.value.copyWith(bypass: cmd.bypass);
    _eq.add(updated);
    pushEqToEngine(updated);
    await saveEqState();
  }

  Future<void> handleSetPreamp(SetPreamp cmd) async {
    final clipped = cmd.db > 0 ? (cmd.db * 420).round() : 0;
    final updated =
        _eq.value.copyWith(preampDb: cmd.db, clippedSamples: clipped);
    _eq.add(updated);
    pushEqToEngine(updated);
    await saveEqState();
  }

  Future<void> handleSetTone(SetTone cmd) async {
    final updated = _eq.value.copyWith(
      mode: EqMode.simple,
      bassDb: cmd.bassDb,
      trebleDb: cmd.trebleDb,
      balance: cmd.balance,
      mono: cmd.mono,
      bypass: false,
    );
    _eq.add(updated);
    pushEqToEngine(updated);
    await saveEqState();
  }

  Future<void> handleSetReplayGain(SetReplayGain cmd) async {
    final updatedEq = _eq.value.copyWith(
      replayGain: cmd.mode,
      replayGainPreampDb: cmd.preampDb,
    );
    _eq.add(updatedEq);

    final updatedSettings = _settings.value.copyWith(replayGain: cmd.mode);
    _settings.add(updatedSettings);

    pushEqToEngine(updatedEq);
    await saveEqState();
    await saveSettings();
    onSettingsChanged?.call(updatedSettings);
  }

  Future<void> handleAssignEqToDevice(
    AssignEqToDevice cmd,
    OutputDevice? currentDev,
  ) async {
    final devName = currentDev?.id == cmd.deviceId
        ? currentDev?.name
        : (cmd.assign ? 'Headphones' : null);
    final updatedEq = _eq.value.copyWith(
      assignedDeviceName: cmd.assign ? devName : null,
    );
    _eq.add(updatedEq);

    final updatedProfiles = _deviceProfiles.value.map((p) {
      if (p.deviceId == cmd.deviceId) {
        return DeviceProfile(
          deviceId: p.deviceId,
          deviceName: p.deviceName,
          eqPresetName:
              cmd.assign ? (_eq.value.presetName ?? 'Custom EQ') : null,
          replayGain: p.replayGain,
          safetyAttenuationDb: p.safetyAttenuationDb,
          preferredVolumeDb: p.preferredVolumeDb,
          autoApply: p.autoApply,
        );
      }
      return p;
    }).toList();
    _deviceProfiles.add(updatedProfiles);
    await saveEqState();
    await saveDeviceProfiles();
  }

  Future<void> handleApplyAutoEqProfile(ApplyAutoEqProfile cmd) async {
    try {
      final profileData =
          await rust_cache.cloudDbGetAutoeqProfile(id: cmd.profileId);
      if (profileData != null) {
        final profile = ParametricEqParser.toAutoEqProfile(profileData);
        final updated = _eq.value.copyWith(
          mode: EqMode.parametric,
          bands: profile.bands,
          preampDb: profile.suggestedPreampDb,
          bypass: false,
          presetName: '${profile.model} AutoEQ',
        );
        _eq.add(updated);
        pushEqToEngine(updated);
        await saveEqState();
      }
    } catch (e) {
      debugPrint('[autoeq] failed to apply profile ${cmd.profileId}: $e');
    }
  }

  Future<void> handleImportParametricEq(ImportParametricEq cmd) async {
    final parsed = ParametricEqParser.parse(cmd.text);
    if (parsed.bands.isNotEmpty) {
      final updated = _eq.value.copyWith(
        mode: EqMode.parametric,
        bands: parsed.bands,
        preampDb: parsed.preampDb ?? _eq.value.preampDb,
        bypass: false,
        presetName: 'Imported Parametric EQ',
      );
      _eq.add(updated);
      pushEqToEngine(updated);
      await saveEqState();
    }
  }

  Future<List<AutoEqProfile>> searchAutoEq(String model) async {
    try {
      final rows = await rust_cache.cloudDbSearchAutoeq(query: model);
      return rows.map(ParametricEqParser.toAutoEqProfile).toList();
    } catch (e) {
      debugPrint('[autoeq] searchAutoEq error: $e');
      return const [];
    }
  }

  void dispose() {
    _settings.close();
    _eq.close();
    _deviceProfiles.close();
  }
}

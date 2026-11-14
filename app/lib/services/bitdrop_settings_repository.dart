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
import '../src/rust/cloud/media_source.dart' as rust_media;
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
  void Function(List<DeviceProfile> profiles)? onDeviceProfilesChanged;
  Track? Function()? currentTrackProvider;
  @visibleForTesting
  void Function(double gainDb, double trackPeak)? onReplayGainPushed;

  BitDropSettingsRepository({
    this.onSettingsChanged,
    this.onEqChanged,
    this.onDeviceProfilesChanged,
    this.currentTrackProvider,
    this.onReplayGainPushed,
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
        syncNetworkTransportMode(loadedSettings.networkTransportMode);
        onSettingsChanged?.call(loadedSettings);
      } else {
        syncNetworkTransportMode(_settings.value.networkTransportMode);
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

  /// Exports app preferences, EQ presets, device profiles, non-secret cloud configurations,
  /// and optional listening recap to a portable, human-readable JSON string formatted for 1-tap backup.
  Future<String> exportBackupJson({
    ListeningRecap? recap,
    List<Map<String, dynamic>>? cloudProviderConfigs,
  }) async {
    final payload = <String, dynamic>{
      'version': 1,
      'schemaVersion': 1,
      'app': 'BitDrop',
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'app_settings':
          jsonDecode(PersistenceCodec.serializeAppSettings(_settings.value)),
      'eq_state': jsonDecode(PersistenceCodec.serializeEqState(_eq.value)),
      'device_profiles': jsonDecode(
          PersistenceCodec.serializeDeviceProfiles(_deviceProfiles.value)),
    };
    if (cloudProviderConfigs != null && cloudProviderConfigs.isNotEmpty) {
      // Export non-secret metadata (provider_id, name, base_url, root_folder) excluding secrets/tokens
      payload['cloud_providers'] = cloudProviderConfigs
          .map((c) => {
                'provider_id': c['provider_id'] ?? c['id'] ?? '',
                'name': c['name'] ?? '',
                'base_url': c['base_url'] ?? '',
                'root_folder': c['root_folder'] ?? '',
              })
          .toList();
    }
    if (recap != null) {
      payload['listening_recap'] = {
        'totalMinutesListened': recap.totalMinutesListened,
        'totalPlays': recap.totalPlays,
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
  /// a backup JSON string with full schema version validation, persisting to SQLite
  /// and updating DSP engine state.
  Future<bool> importBackupJson(String jsonStr) async {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map) return false;

      // Full schema version validation:
      final version = decoded['schemaVersion'] ?? decoded['version'];
      if (version == null || version is! int || version < 1 || version > 1) {
        debugPrint('[persistence] unsupported backup schema version: $version');
        return false;
      }

      if (decoded['app'] != null && decoded['app'] != 'BitDrop') {
        debugPrint('[persistence] invalid app identifier in backup: ${decoded['app']}');
        return false;
      }

      if (decoded.containsKey('app_settings')) {
        final sJson = jsonEncode(decoded['app_settings']);
        final loaded = PersistenceCodec.deserializeAppSettings(sJson);
        _settings.add(loaded);
        syncNetworkTransportMode(loaded.networkTransportMode);
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
          onDeviceProfilesChanged?.call(loaded);
        }
      }

      return true;
    } catch (e) {
      debugPrint('[persistence] failed to import backup json: $e');
      return false;
    }
  }

  /// Builds the human-readable DSP stage labels for Signal Path reporting.
  static List<String> describeDspChain(EqState eq, {bool? engineDspActive}) {
    final stages = <String>[];
    if (!eq.bypass &&
        (eq.bands.any((b) => b.enabled && b.gainDb != 0) ||
            eq.preampDb != 0 ||
            eq.bassDb != 0 ||
            eq.trebleDb != 0 ||
            eq.balance != 0 ||
            eq.mono ||
            eq.graphicGains.any((g) => g != 0))) {
      stages.add('Equaliser');
    }
    if (eq.replayGain != ReplayGainMode.off) {
      stages.add('ReplayGain (${eq.replayGain.name})');
    }
    if (eq.crossfeed != CrossfeedPreset.off) {
      stages.add('BS2B Crossfeed (${eq.crossfeed.shortLabel})');
    }
    if (stages.isEmpty && (engineDspActive ?? false)) {
      stages.add('Equaliser');
    }
    return stages;
  }

  /// Resolves effective ReplayGain gain (dB) and peak ceiling from [eqState] and [track].
  static ({double gainDb, double peak}) resolveReplayGain(
    EqState eqState,
    Track? track,
  ) {
    if (eqState.replayGain == ReplayGainMode.off) {
      return (gainDb: 0.0, peak: 1.0);
    }
    final isAlbum = eqState.replayGain == ReplayGainMode.album;
    final gainDb = isAlbum
        ? (track?.replayGainAlbumDb ??
            track?.replayGainDb ??
            eqState.replayGainPreampDb)
        : (track?.replayGainDb ?? eqState.replayGainPreampDb);
    final rawPeak =
        isAlbum ? (track?.albumPeak ?? track?.trackPeak) : track?.trackPeak;
    final peak = (rawPeak != null && rawPeak > 0) ? rawPeak : 1.0;
    return (gainDb: gainDb, peak: peak);
  }

  /// Pushes only the ReplayGain gain and peak for [track] under [eqState]
  /// without re-uploading EQ biquads (used on dynamic track/gapless switches).
  void pushReplayGainForTrack(EqState eqState, Track? track) {
    final rg = resolveReplayGain(eqState, track);
    onReplayGainPushed?.call(rg.gainDb, rg.peak);
    try {
      rust.engineSetReplayGain(gainDb: rg.gainDb, trackPeak: rg.peak);
    } catch (_) {}
  }

  /// Builds EQ band payload + decoupled ReplayGain/BS2B parameters and pushes
  /// them into the lock-free Rust engine without mutating reactive streams.
  void pushEqSnapshotToEngine(EqState eqState) {
    final balance = eqState.balance;
    final mono = eqState.mono ? 1.0 : 0.0;
    final rg = resolveReplayGain(eqState, currentTrackProvider?.call());
    final replayGainDb = rg.gainDb;
    final trackPeak = rg.peak;

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
        eqState.preampDb,
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
        eqState.preampDb,
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
        eqState.preampDb,
        balance,
        mono,
      ];
    }

    onReplayGainPushed?.call(replayGainDb, trackPeak);
    try {
      rust.engineSetEq(gains: enginePayload);
      rust.engineSetEqEnabled(enabled: !eqState.bypass);
      rust.engineSetReplayGain(gainDb: replayGainDb, trackPeak: trackPeak);
      rust.engineSetCrossfeed(preset: eqState.crossfeed.rustId);
    } catch (_) {}
  }

  void pushEqToEngine([EqState? state]) {
    final eqState = state ?? _eq.value;
    pushEqSnapshotToEngine(eqState);
    onEqChanged?.call(eqState);
  }

  void syncNetworkTransportMode(NetworkTransportMode mode) {
    try {
      final rustMode = mode == NetworkTransportMode.meteredCellular
          ? rust_media.NetworkTransportMode.meteredCellular
          : rust_media.NetworkTransportMode.unmeteredWifi;
      rust.engineSetNetworkTransportMode(mode: rustMode);
    } catch (_) {}
  }

  void syncFromLiveState({
    AppSettings? settings,
    EqState? eq,
    List<DeviceProfile>? deviceProfiles,
  }) {
    if (settings != null && !_settings.isClosed) {
      _settings.add(settings);
      syncNetworkTransportMode(settings.networkTransportMode);
    }
    if (eq != null && !_eq.isClosed) {
      _eq.add(eq);
    }
    if (deviceProfiles != null && !_deviceProfiles.isClosed) {
      _deviceProfiles.add(deviceProfiles);
    }
  }

  Future<void> handleSetSetting(SetSetting cmd) async {
    final updated = _settings.value.withKey(cmd.key, cmd.value);
    _settings.add(updated);
    if (cmd.key == 'conserveCellularData' || cmd.key == 'networkTransportMode') {
      syncNetworkTransportMode(updated.networkTransportMode);
    }
    if (cmd.key == 'replayGain' && cmd.value is ReplayGainMode) {
      final updatedEq = _eq.value.copyWith(replayGain: cmd.value as ReplayGainMode);
      _eq.add(updatedEq);
      pushEqToEngine(updatedEq);
      await saveEqState();
    }
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

  Future<void> handleSetCrossfeed(SetCrossfeed cmd) async {
    final updatedEq = _eq.value.copyWith(crossfeed: cmd.preset);
    _eq.add(updatedEq);

    pushEqToEngine(updatedEq);
    await saveEqState();
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
    onDeviceProfilesChanged?.call(updatedProfiles);
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

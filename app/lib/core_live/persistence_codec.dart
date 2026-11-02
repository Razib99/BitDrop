import 'dart:convert';

import '../core_api/enums.dart';
import '../core_api/models.dart';
import '../core_api/settings.dart';

/// Codecs for serializing and deserializing EqState, AppSettings, and DeviceProfiles
/// to/from JSON for SQLite persistence in Rust (\`app_kv\` table).
abstract final class PersistenceCodec {
  // --- EqState ---

  static String serializeEqState(EqState eq) {
    final map = {
      'mode': eq.mode.name,
      'bypass': eq.bypass,
      'preampDb': eq.preampDb,
      'graphicGains': eq.graphicGains,
      'bassDb': eq.bassDb,
      'trebleDb': eq.trebleDb,
      'balance': eq.balance,
      'mono': eq.mono,
      'replayGain': eq.replayGain.name,
      'replayGainPreampDb': eq.replayGainPreampDb,
      'presetName': eq.presetName,
      'assignedDeviceName': eq.assignedDeviceName,
      'bands': eq.bands
          .map((b) => {
                'id': b.id,
                'type': b.type.name,
                'frequencyHz': b.frequencyHz,
                'gainDb': b.gainDb,
                'q': b.q,
                'enabled': b.enabled,
              })
          .toList(),
    };
    return jsonEncode(map);
  }

  static EqState deserializeEqState(String jsonStr) {
    try {
      final map = jsonDecode(jsonStr);
      if (map is! Map) return defaultEqState();
      final modeName = map['mode'] as String?;
      final mode =
          EqMode.values.where((e) => e.name == modeName).firstOrNull ??
              EqMode.graphic;
      final bypass = map['bypass'] as bool? ?? false;
      final preampDb = (map['preampDb'] as num?)?.toDouble() ?? 0.0;
      final graphicGains = (map['graphicGains'] as List?)
              ?.map((e) => (e as num).toDouble())
              .toList() ??
          const [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
      final bassDb = (map['bassDb'] as num?)?.toDouble() ?? 0.0;
      final trebleDb = (map['trebleDb'] as num?)?.toDouble() ?? 0.0;
      final balance = (map['balance'] as num?)?.toDouble() ?? 0.0;
      final mono = map['mono'] as bool? ?? false;
      final rgName = map['replayGain'] as String?;
      final replayGain =
          ReplayGainMode.values.where((e) => e.name == rgName).firstOrNull ??
              ReplayGainMode.off;
      final replayGainPreampDb =
          (map['replayGainPreampDb'] as num?)?.toDouble() ?? 0.0;
      final presetName = map['presetName'] as String?;
      final assignedDeviceName = map['assignedDeviceName'] as String?;

      final rawBands = map['bands'] as List?;
      final bands = <EqBand>[];
      if (rawBands != null) {
        for (final raw in rawBands) {
          if (raw is Map) {
            final bType = BiquadType.values
                    .where((e) => e.name == raw['type'])
                    .firstOrNull ??
                BiquadType.peak;
            bands.add(EqBand(
              id: (raw['id'] as num?)?.toInt() ?? 0,
              type: bType,
              frequencyHz: (raw['frequencyHz'] as num?)?.toDouble() ?? 1000.0,
              gainDb: (raw['gainDb'] as num?)?.toDouble() ?? 0.0,
              q: (raw['q'] as num?)?.toDouble() ?? 1.414,
              enabled: raw['enabled'] as bool? ?? true,
            ));
          }
        }
      }

      return EqState(
        mode: mode,
        bands: bands,
        preampDb: preampDb,
        bypass: bypass,
        graphicGains: graphicGains,
        bassDb: bassDb,
        trebleDb: trebleDb,
        balance: balance,
        mono: mono,
        replayGain: replayGain,
        replayGainPreampDb: replayGainPreampDb,
        presetName: presetName,
        assignedDeviceName: assignedDeviceName,
      );
    } catch (_) {
      return defaultEqState();
    }
  }

  static EqState defaultEqState() => const EqState(
        mode: EqMode.graphic,
        bands: [],
        preampDb: 0.0,
        bypass: true,
        graphicGains: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
      );

  // --- AppSettings ---

  static String serializeAppSettings(AppSettings s) {
    final map = {
      'themeMode': s.themeMode.name,
      'oledBlack': s.oledBlack,
      'nowPlayingStyle': s.nowPlayingStyle.name,
      'adaptiveColor': s.adaptiveColor,
      'reduceMotion': s.reduceMotion,
      'textScale': s.textScale,
      'formatBadges': s.formatBadges.name,
      'gridDensity': s.gridDensity.name,
      'showTechnicalDetails': s.showTechnicalDetails,
      'preferBitPerfect': s.preferBitPerfect,
      'safetyAttenuationEnabled': s.safetyAttenuationEnabled,
      'safetyAttenuationDb': s.safetyAttenuationDb,
      'gapless': s.gapless,
      'crossfadeSeconds': s.crossfadeSeconds,
      'replayGain': s.replayGain.name,
      'resumeOnHeadsetConnect': s.resumeOnHeadsetConnect,
      'sleepTimerDefaultMinutes': s.sleepTimerDefaultMinutes,
      'mobileDataPolicy': s.mobileDataPolicy.name,
      'prefetchPolicy': s.prefetchPolicy.name,
      'bufferProfile': s.bufferProfile.name,
      'showUnsupportedFiles': s.showUnsupportedFiles,
      'groupCompilations': s.groupCompilations,
      'ignoreLeadingThe': s.ignoreLeadingThe,
      'artistSeparators': s.artistSeparators,
      'scanWifiOnly': s.scanWifiOnly,
      'includeSharedDrives': s.includeSharedDrives,
      'artworkPreference': s.artworkPreference.name,
      'notificationsEnabled': s.notificationsEnabled,
      'lockScreenArtwork': s.lockScreenArtwork,
    };
    return jsonEncode(map);
  }

  static AppSettings deserializeAppSettings(String jsonStr) {
    try {
      final map = jsonDecode(jsonStr);
      if (map is! Map) return const AppSettings();
      var s = const AppSettings();
      for (final entry in map.entries) {
        final key = entry.key.toString();
        final val = entry.value;
        if (val == null) continue;
        switch (key) {
          case 'themeMode':
            final v = AppThemeMode.values
                .where((e) => e.name == val)
                .firstOrNull;
            if (v != null) s = s.copyWith(themeMode: v);
          case 'oledBlack':
            if (val is bool) s = s.copyWith(oledBlack: val);
          case 'nowPlayingStyle':
            final v = NowPlayingStyle.values
                .where((e) => e.name == val)
                .firstOrNull;
            if (v != null) s = s.copyWith(nowPlayingStyle: v);
          case 'adaptiveColor':
            if (val is bool) s = s.copyWith(adaptiveColor: val);
          case 'reduceMotion':
            if (val is bool) s = s.copyWith(reduceMotion: val);
          case 'textScale':
            if (val is num) s = s.copyWith(textScale: val.toDouble());
          case 'formatBadges':
            final v = BadgeVisibility.values
                .where((e) => e.name == val)
                .firstOrNull;
            if (v != null) s = s.copyWith(formatBadges: v);
          case 'gridDensity':
            final v = GridDensity.values
                .where((e) => e.name == val)
                .firstOrNull;
            if (v != null) s = s.copyWith(gridDensity: v);
          case 'showTechnicalDetails':
            if (val is bool) s = s.copyWith(showTechnicalDetails: val);
          case 'preferBitPerfect':
            if (val is bool) s = s.copyWith(preferBitPerfect: val);
          case 'safetyAttenuationEnabled':
            if (val is bool) s = s.copyWith(safetyAttenuationEnabled: val);
          case 'safetyAttenuationDb':
            if (val is num) s = s.copyWith(safetyAttenuationDb: val.toDouble());
          case 'gapless':
            if (val is bool) s = s.copyWith(gapless: val);
          case 'crossfadeSeconds':
            if (val is num) s = s.copyWith(crossfadeSeconds: val.toInt());
          case 'replayGain':
            final v = ReplayGainMode.values
                .where((e) => e.name == val)
                .firstOrNull;
            if (v != null) s = s.copyWith(replayGain: v);
          case 'resumeOnHeadsetConnect':
            if (val is bool) s = s.copyWith(resumeOnHeadsetConnect: val);
          case 'sleepTimerDefaultMinutes':
            if (val is num) {
              s = s.copyWith(sleepTimerDefaultMinutes: val.toInt());
            }
          case 'mobileDataPolicy':
            final v = MobileDataPolicy.values
                .where((e) => e.name == val)
                .firstOrNull;
            if (v != null) s = s.copyWith(mobileDataPolicy: v);
          case 'prefetchPolicy':
            final v = PrefetchPolicy.values
                .where((e) => e.name == val)
                .firstOrNull;
            if (v != null) s = s.copyWith(prefetchPolicy: v);
          case 'bufferProfile':
            final v = BufferProfile.values
                .where((e) => e.name == val)
                .firstOrNull;
            if (v != null) s = s.copyWith(bufferProfile: v);
          case 'showUnsupportedFiles':
            if (val is bool) s = s.copyWith(showUnsupportedFiles: val);
          case 'groupCompilations':
            if (val is bool) s = s.copyWith(groupCompilations: val);
          case 'ignoreLeadingThe':
            if (val is bool) s = s.copyWith(ignoreLeadingThe: val);
          case 'artistSeparators':
            if (val is String) s = s.copyWith(artistSeparators: val);
          case 'scanWifiOnly':
            if (val is bool) s = s.copyWith(scanWifiOnly: val);
          case 'includeSharedDrives':
            if (val is bool) s = s.copyWith(includeSharedDrives: val);
          case 'artworkPreference':
            final v = ArtworkPreference.values
                .where((e) => e.name == val)
                .firstOrNull;
            if (v != null) s = s.copyWith(artworkPreference: v);
          case 'notificationsEnabled':
            if (val is bool) s = s.copyWith(notificationsEnabled: val);
          case 'lockScreenArtwork':
            if (val is bool) s = s.copyWith(lockScreenArtwork: val);
        }
      }
      return s;
    } catch (_) {
      return const AppSettings();
    }
  }

  // --- DeviceProfiles ---

  static String serializeDeviceProfiles(List<DeviceProfile> profiles) {
    final list = profiles
        .map((d) => {
              'deviceId': d.deviceId,
              'deviceName': d.deviceName,
              'eqPresetName': d.eqPresetName,
              'replayGain': d.replayGain.name,
              'safetyAttenuationDb': d.safetyAttenuationDb,
              'preferredVolumeDb': d.preferredVolumeDb,
              'autoApply': d.autoApply,
            })
        .toList();
    return jsonEncode(list);
  }

  static List<DeviceProfile> deserializeDeviceProfiles(String jsonStr) {
    try {
      final list = jsonDecode(jsonStr);
      if (list is! List) return const [];
      final result = <DeviceProfile>[];
      for (final raw in list) {
        if (raw is Map) {
          final rgName = raw['replayGain'] as String?;
          final replayGain = ReplayGainMode.values
                  .where((e) => e.name == rgName)
                  .firstOrNull ??
              ReplayGainMode.off;
          result.add(DeviceProfile(
            deviceId: raw['deviceId'] as String? ?? '',
            deviceName: raw['deviceName'] as String? ?? '',
            eqPresetName: raw['eqPresetName'] as String?,
            replayGain: replayGain,
            safetyAttenuationDb:
                (raw['safetyAttenuationDb'] as num?)?.toDouble(),
            preferredVolumeDb:
                (raw['preferredVolumeDb'] as num?)?.toDouble(),
            autoApply: raw['autoApply'] as bool? ?? true,
          ));
        }
      }
      return result;
    } catch (_) {
      return const [];
    }
  }
}

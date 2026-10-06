import 'package:flutter/foundation.dart';

import 'enums.dart';

/// Theme choice. Kept free of `material.dart` so `core_api/` stays a pure
/// contract layer; `app.dart` maps it onto Flutter's `ThemeMode`.
enum AppThemeMode { system, light, dark }

enum GridDensity { comfortable, compact }

enum ArtworkPreference { embedded, folderImage }

/// Every user-settable option, owned by the core and written with
/// [SetSetting]. The UI renders this and never keeps its own copy.
@immutable
class AppSettings {
  const AppSettings({
    this.themeMode = AppThemeMode.system,
    this.oledBlack = false,
    this.nowPlayingStyle = NowPlayingStyle.classic,
    this.adaptiveColor = true,
    this.reduceMotion = false,
    this.textScale = 1.0,
    this.formatBadges = BadgeVisibility.always,
    this.gridDensity = GridDensity.comfortable,
    this.showTechnicalDetails = false,
    this.preferBitPerfect = true,
    this.safetyAttenuationEnabled = false,
    this.safetyAttenuationDb = -12.0,
    this.gapless = true,
    this.crossfadeSeconds = 0,
    this.replayGain = ReplayGainMode.off,
    this.resumeOnHeadsetConnect = true,
    this.sleepTimerDefaultMinutes = 30,
    this.mobileDataPolicy = MobileDataPolicy.ask,
    this.prefetchPolicy = PrefetchPolicy.wifiOnly,
    this.bufferProfile = BufferProfile.balanced,
    this.showUnsupportedFiles = true,
    this.groupCompilations = true,
    this.ignoreLeadingThe = true,
    this.artistSeparators = '; / feat.',
    this.scanWifiOnly = true,
    this.includeSharedDrives = false,
    this.artworkPreference = ArtworkPreference.embedded,
    this.notificationsEnabled = true,
    this.lockScreenArtwork = true,
  });

  final AppThemeMode themeMode;
  final bool oledBlack;
  final NowPlayingStyle nowPlayingStyle;
  final bool adaptiveColor;
  final bool reduceMotion;

  /// 1.0, 1.3 or 2.0 in the scenario switcher; the OS value otherwise.
  final double textScale;
  final BadgeVisibility formatBadges;
  final GridDensity gridDensity;
  final bool showTechnicalDetails;

  final bool preferBitPerfect;
  final bool safetyAttenuationEnabled;
  final double safetyAttenuationDb;

  final bool gapless;
  final int crossfadeSeconds;
  final ReplayGainMode replayGain;
  final bool resumeOnHeadsetConnect;
  final int sleepTimerDefaultMinutes;

  final MobileDataPolicy mobileDataPolicy;
  final PrefetchPolicy prefetchPolicy;
  final BufferProfile bufferProfile;

  final bool showUnsupportedFiles;
  final bool groupCompilations;
  final bool ignoreLeadingThe;
  final String artistSeparators;
  final bool scanWifiOnly;
  final bool includeSharedDrives;
  final ArtworkPreference artworkPreference;

  final bool notificationsEnabled;
  final bool lockScreenArtwork;

  AppSettings copyWith({
    AppThemeMode? themeMode,
    bool? oledBlack,
    NowPlayingStyle? nowPlayingStyle,
    bool? adaptiveColor,
    bool? reduceMotion,
    double? textScale,
    BadgeVisibility? formatBadges,
    GridDensity? gridDensity,
    bool? showTechnicalDetails,
    bool? preferBitPerfect,
    bool? safetyAttenuationEnabled,
    double? safetyAttenuationDb,
    bool? gapless,
    int? crossfadeSeconds,
    ReplayGainMode? replayGain,
    bool? resumeOnHeadsetConnect,
    int? sleepTimerDefaultMinutes,
    MobileDataPolicy? mobileDataPolicy,
    PrefetchPolicy? prefetchPolicy,
    BufferProfile? bufferProfile,
    bool? showUnsupportedFiles,
    bool? groupCompilations,
    bool? ignoreLeadingThe,
    String? artistSeparators,
    bool? scanWifiOnly,
    bool? includeSharedDrives,
    ArtworkPreference? artworkPreference,
    bool? notificationsEnabled,
    bool? lockScreenArtwork,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        oledBlack: oledBlack ?? this.oledBlack,
        nowPlayingStyle: nowPlayingStyle ?? this.nowPlayingStyle,
        adaptiveColor: adaptiveColor ?? this.adaptiveColor,
        reduceMotion: reduceMotion ?? this.reduceMotion,
        textScale: textScale ?? this.textScale,
        formatBadges: formatBadges ?? this.formatBadges,
        gridDensity: gridDensity ?? this.gridDensity,
        showTechnicalDetails: showTechnicalDetails ?? this.showTechnicalDetails,
        preferBitPerfect: preferBitPerfect ?? this.preferBitPerfect,
        safetyAttenuationEnabled:
            safetyAttenuationEnabled ?? this.safetyAttenuationEnabled,
        safetyAttenuationDb: safetyAttenuationDb ?? this.safetyAttenuationDb,
        gapless: gapless ?? this.gapless,
        crossfadeSeconds: crossfadeSeconds ?? this.crossfadeSeconds,
        replayGain: replayGain ?? this.replayGain,
        resumeOnHeadsetConnect:
            resumeOnHeadsetConnect ?? this.resumeOnHeadsetConnect,
        sleepTimerDefaultMinutes:
            sleepTimerDefaultMinutes ?? this.sleepTimerDefaultMinutes,
        mobileDataPolicy: mobileDataPolicy ?? this.mobileDataPolicy,
        prefetchPolicy: prefetchPolicy ?? this.prefetchPolicy,
        bufferProfile: bufferProfile ?? this.bufferProfile,
        showUnsupportedFiles: showUnsupportedFiles ?? this.showUnsupportedFiles,
        groupCompilations: groupCompilations ?? this.groupCompilations,
        ignoreLeadingThe: ignoreLeadingThe ?? this.ignoreLeadingThe,
        artistSeparators: artistSeparators ?? this.artistSeparators,
        scanWifiOnly: scanWifiOnly ?? this.scanWifiOnly,
        includeSharedDrives: includeSharedDrives ?? this.includeSharedDrives,
        artworkPreference: artworkPreference ?? this.artworkPreference,
        notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
        lockScreenArtwork: lockScreenArtwork ?? this.lockScreenArtwork,
      );

  /// Writes one key by name. Keeps [SetSetting] generic without reflection.
  AppSettings withKey(String key, Object? value) => switch (key) {
        'themeMode' => copyWith(themeMode: value as AppThemeMode),
        'oledBlack' => copyWith(oledBlack: value as bool),
        'nowPlayingStyle' =>
          copyWith(nowPlayingStyle: value as NowPlayingStyle),
        'adaptiveColor' => copyWith(adaptiveColor: value as bool),
        'reduceMotion' => copyWith(reduceMotion: value as bool),
        'textScale' => copyWith(textScale: value as double),
        'formatBadges' => copyWith(formatBadges: value as BadgeVisibility),
        'gridDensity' => copyWith(gridDensity: value as GridDensity),
        'showTechnicalDetails' => copyWith(showTechnicalDetails: value as bool),
        'preferBitPerfect' => copyWith(preferBitPerfect: value as bool),
        'safetyAttenuationEnabled' =>
          copyWith(safetyAttenuationEnabled: value as bool),
        'safetyAttenuationDb' => copyWith(safetyAttenuationDb: value as double),
        'gapless' => copyWith(gapless: value as bool),
        'crossfadeSeconds' => copyWith(crossfadeSeconds: value as int),
        'replayGain' => copyWith(replayGain: value as ReplayGainMode),
        'resumeOnHeadsetConnect' =>
          copyWith(resumeOnHeadsetConnect: value as bool),
        'sleepTimerDefaultMinutes' =>
          copyWith(sleepTimerDefaultMinutes: value as int),
        'mobileDataPolicy' =>
          copyWith(mobileDataPolicy: value as MobileDataPolicy),
        'prefetchPolicy' => copyWith(prefetchPolicy: value as PrefetchPolicy),
        'bufferProfile' => copyWith(bufferProfile: value as BufferProfile),
        'showUnsupportedFiles' => copyWith(showUnsupportedFiles: value as bool),
        'groupCompilations' => copyWith(groupCompilations: value as bool),
        'ignoreLeadingThe' => copyWith(ignoreLeadingThe: value as bool),
        'artistSeparators' => copyWith(artistSeparators: value as String),
        'scanWifiOnly' => copyWith(scanWifiOnly: value as bool),
        'includeSharedDrives' => copyWith(includeSharedDrives: value as bool),
        'artworkPreference' =>
          copyWith(artworkPreference: value as ArtworkPreference),
        'notificationsEnabled' => copyWith(notificationsEnabled: value as bool),
        'lockScreenArtwork' => copyWith(lockScreenArtwork: value as bool),
        _ => this,
      };
}

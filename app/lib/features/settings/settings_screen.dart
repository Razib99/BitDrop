import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core_api/commands.dart';
import '../../core_api/enums.dart';
import '../../core_api/models.dart';
import '../../core_api/settings.dart';
import '../../l10n/l10n.dart';
import '../../providers/core_providers.dart';
import '../../routing/routes.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_tile.dart';

/// Settings, searchable.
///
/// Poweramp's worst habit is burying hundreds of options in deep trees. Here
/// every option lives in one flat, grouped list with a one-line explanation,
/// the search field filters by name *and* description, and a disabled option
/// always says why.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsValueProvider);
    final signal = ref.watch(signalPathProvider).valueOrNull;
    final storage = ref.watch(storageProvider).valueOrNull;
    final sources = ref.watch(sourcesProvider).valueOrNull ?? const [];
    final device = ref.watch(outputDeviceProvider).valueOrNull;

    final groups = _buildGroups(s, signal, storage, sources, device);
    final q = _query.trim().toLowerCase();

    // Filtering keeps a group only if one of its tiles matches, and shows
    // just the matching tiles, so a search lands on the answer.
    final filtered = q.isEmpty
        ? groups
        : [
            for (final g in groups)
              if (g.tiles.any((t) => t.searchText.contains(q)))
                SettingsGroup(
                  title: g.title,
                  icon: g.icon,
                  initiallyExpandedAdvanced: true,
                  tiles: g.tiles
                      .where((t) => t.searchText.contains(q))
                      .toList(),
                ),
          ];

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.navSettings)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                Spacing.md, Spacing.xs, Spacing.md, Spacing.xs),
            child: TextField(
              controller: _controller,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: 'Search settings',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: context.l10n.actionClear,
                        onPressed: () {
                          _controller.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
            ),
          ),
          Expanded(
            child: filtered.isEmpty
                ? EmptyState(
                    icon: Icons.search_off,
                    title: 'No setting matches "$_query"',
                    message: 'Try a word from the option or its description.',
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: Spacing.xxl),
                    children: [
                      ...filtered,
                      if (q.isEmpty) const _PrivacyFooter(),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  void _set(String key, Object? value) =>
      sendCommand(ref, SetSetting(key: key, value: value));

  List<SettingsGroup> _buildGroups(
    AppSettings s,
    SignalPath? signal,
    StorageState? storage,
    List<SourceAccount> sources,
    OutputDevice? device,
  ) {
    final bitPerfectActive = signal?.tier == OutputTier.bitPerfect;

    return [
      SettingsGroup(
        title: 'Audio output',
        icon: Icons.headphones,
        tiles: [
          NavigationSettingsTile(
            title: 'Current device',
            subtitle: device == null
                ? 'Nothing connected'
                : '${device.name} · ${signal?.tier.label ?? 'Unknown'}',
            icon: Icons.usb,
            onTap: () => context.push(Routes.output),
          ),
          SwitchSettingsTile(
            title: 'Prefer bit-perfect when available',
            subtitle: 'Asks Android for an untouched path. Needs Android 14 '
                'or later and a DAC that supports it.',
            value: s.preferBitPerfect,
            onChanged: (v) => _set('preferBitPerfect', v),
          ),
          SwitchSettingsTile(
            title: 'Safety attenuation',
            subtitle:
                '${Fmt.db(s.safetyAttenuationDb)} of digital attenuation for '
                'DACs with no volume control. Costs bit-perfect.',
            value: s.safetyAttenuationEnabled,
            onChanged: (v) => _set('safetyAttenuationEnabled', v),
          ),
          NavigationSettingsTile(
            title: 'Run hearing safety check',
            subtitle: 'Remembered per phone and DAC pair',
            onTap: () => context.push(Routes.safety),
            advanced: true,
          ),
          NavigationSettingsTile(
            title: 'Per-device profiles',
            subtitle: 'EQ, volume and safety settings follow each device',
            onTap: () => context.push(Routes.output),
            advanced: true,
          ),
        ],
      ),
      SettingsGroup(
        title: 'Playback',
        icon: Icons.play_circle_outline,
        tiles: [
          SwitchSettingsTile(
            title: 'Gapless playback',
            subtitle: 'Seamless between tracks that share a format. A sample '
                'rate change still causes a brief gap.',
            value: s.gapless,
            onChanged: (v) => _set('gapless', v),
          ),
          SliderSettingsTile(
            title: 'Crossfade',
            subtitle: 'Overlaps the end of one track with the start of the '
                'next.',
            enabled: !bitPerfectActive,
            disabledReason: 'Not available while bit-perfect output is on — '
                'mixing two tracks would change the samples.',
            value: s.crossfadeSeconds.toDouble(),
            min: 0,
            max: 12,
            divisions: 12,
            valueLabel: (v) => v == 0 ? 'Off' : '${v.round()} s',
            onChanged: (v) => _set('crossfadeSeconds', v.round()),
          ),
          ChoiceSettingsTile<ReplayGainMode>(
            title: 'ReplayGain',
            subtitle: 'Evens out loudness between tracks. Applies digital '
                'gain, so it costs bit-perfect.',
            value: s.replayGain,
            options: ReplayGainMode.values,
            labelOf: (m) => switch (m) {
              ReplayGainMode.off => 'Off',
              ReplayGainMode.track => 'Track',
              ReplayGainMode.album => 'Album',
            },
            onChanged: (v) => _set('replayGain', v),
          ),
          SwitchSettingsTile(
            title: 'Resume on headset connect',
            subtitle: 'Starts playing again when you plug in or connect.',
            value: s.resumeOnHeadsetConnect,
            onChanged: (v) => _set('resumeOnHeadsetConnect', v),
            advanced: true,
          ),
          SliderSettingsTile(
            title: 'Default sleep timer',
            subtitle: 'Pre-filled when you open the sleep timer.',
            value: s.sleepTimerDefaultMinutes.toDouble(),
            min: 5,
            max: 120,
            divisions: 23,
            valueLabel: (v) => '${v.round()} min',
            onChanged: (v) => _set('sleepTimerDefaultMinutes', v.round()),
            advanced: true,
          ),
        ],
      ),
      SettingsGroup(
        title: 'Streaming & data',
        icon: Icons.signal_cellular_alt,
        tiles: [
          ChoiceSettingsTile<MobileDataPolicy>(
            title: 'On mobile data',
            subtitle: 'What BitDrop may do when you are not on Wi-Fi.',
            value: s.mobileDataPolicy,
            options: MobileDataPolicy.values,
            labelOf: (m) => switch (m) {
              MobileDataPolicy.stream => 'Stream',
              MobileDataPolicy.cachedOnly => 'Cached only',
              MobileDataPolicy.ask => 'Ask',
            },
            onChanged: (v) => _set('mobileDataPolicy', v),
          ),
          ChoiceSettingsTile<PrefetchPolicy>(
            title: 'Prefetch next tracks',
            subtitle: 'Fetching ahead makes gapless work and hides network '
                'hiccups, at the cost of data.',
            value: s.prefetchPolicy,
            options: PrefetchPolicy.values,
            labelOf: (p) => switch (p) {
              PrefetchPolicy.wifiOnly => 'Wi-Fi only',
              PrefetchPolicy.always => 'Always',
              PrefetchPolicy.never => 'Never',
            },
            onChanged: (v) => _set('prefetchPolicy', v),
          ),
          ChoiceSettingsTile<BufferProfile>(
            title: 'Start-up buffering',
            subtitle: 'How much to buffer before playback starts.',
            value: s.bufferProfile,
            options: BufferProfile.values,
            labelOf: (b) => switch (b) {
              BufferProfile.fast => 'Fast',
              BufferProfile.balanced => 'Balanced',
              BufferProfile.safe => 'Safe',
            },
            onChanged: (v) => _set('bufferProfile', v),
            advanced: true,
          ),
        ],
      ),
      SettingsGroup(
        title: 'Offline & storage',
        icon: Icons.sd_storage_outlined,
        tiles: [
          NavigationSettingsTile(
            title: 'Offline & storage',
            subtitle: 'Cache limit, pinned albums, download queue',
            trailingText: storage == null
                ? null
                : Fmt.bytes(storage.pinnedBytes + storage.cacheBytes),
            onTap: () => context.push(Routes.storage),
          ),
        ],
      ),
      SettingsGroup(
        title: 'Library',
        icon: Icons.library_music_outlined,
        tiles: [
          NavigationSettingsTile(
            title: 'Sources and folders',
            subtitle: sources.isEmpty
                ? 'No source connected'
                : '${sources.first.provider} · '
                    '${Fmt.count(sources.first.trackCount)} tracks',
            onTap: () => context.go(Routes.sources),
          ),
          SwitchSettingsTile(
            title: 'Show unsupported files',
            subtitle: 'APE, WavPack, DSF and Opus appear greyed out rather '
                'than vanishing from your library.',
            value: s.showUnsupportedFiles,
            onChanged: (v) => _set('showUnsupportedFiles', v),
          ),
          SwitchSettingsTile(
            title: 'Scan on Wi-Fi only',
            subtitle: 'Tag reading waits for Wi-Fi.',
            value: s.scanWifiOnly,
            onChanged: (v) => _set('scanWifiOnly', v),
          ),
          SwitchSettingsTile(
            title: 'Group compilations',
            subtitle: 'Keeps "Various Artists" albums together instead of '
                'splitting them per track artist.',
            value: s.groupCompilations,
            onChanged: (v) => _set('groupCompilations', v),
            advanced: true,
          ),
          SwitchSettingsTile(
            title: 'Ignore leading "The"',
            subtitle: '"The Lowlands" sorts under L.',
            value: s.ignoreLeadingThe,
            onChanged: (v) => _set('ignoreLeadingThe', v),
            advanced: true,
          ),
          SwitchSettingsTile(
            title: 'Include Shared drives',
            subtitle: 'Also index "Shared with me" and Shared drives.',
            value: s.includeSharedDrives,
            onChanged: (v) => _set('includeSharedDrives', v),
            advanced: true,
          ),
          ChoiceSettingsTile<ArtworkPreference>(
            title: 'Artwork preference',
            subtitle: 'Where to take album art from.',
            value: s.artworkPreference,
            options: ArtworkPreference.values,
            labelOf: (a) => switch (a) {
              ArtworkPreference.embedded => 'Embedded',
              ArtworkPreference.folderImage => 'folder.jpg',
            },
            onChanged: (v) => _set('artworkPreference', v),
            advanced: true,
          ),
          NavigationSettingsTile(
            title: 'Rescan library',
            subtitle: 'Re-reads folders and tags from your cloud',
            onTap: () => sendCommand(ref, const Rescan()),
            advanced: true,
          ),
        ],
      ),
      SettingsGroup(
        title: 'Equalizer',
        icon: Icons.graphic_eq,
        tiles: [
          NavigationSettingsTile(
            title: 'Equalizer & DSP',
            subtitle: 'Parametric, graphic and tone, with AutoEQ',
            onTap: () => context.push(Routes.equalizer),
          ),
          NavigationSettingsTile(
            title: 'AutoEQ browser',
            subtitle: 'Find a profile for your IEM or headphones',
            onTap: () => context.push(Routes.autoEq),
            advanced: true,
          ),
        ],
      ),
      SettingsGroup(
        title: 'Appearance',
        icon: Icons.palette_outlined,
        tiles: [
          ChoiceSettingsTile<AppThemeMode>(
            title: 'Theme',
            subtitle: 'Light, dark, or follow the system.',
            value: s.themeMode,
            options: AppThemeMode.values,
            labelOf: (m) => switch (m) {
              AppThemeMode.system => context.l10n.themeSystem,
              AppThemeMode.light => context.l10n.themeLight,
              AppThemeMode.dark => context.l10n.themeDark,
            },
            onChanged: (v) => _set('themeMode', v),
          ),
          SwitchSettingsTile(
            title: 'OLED pure black',
            subtitle: 'Saves power on OLED screens in dark mode.',
            value: s.oledBlack,
            enabled: s.themeMode != AppThemeMode.light,
            disabledReason: 'Only applies in dark mode.',
            onChanged: (v) => _set('oledBlack', v),
          ),
          ChoiceSettingsTile<NowPlayingStyle>(
            title: 'Now Playing style',
            subtitle: 'Artwork-led, text-led, or meters and readouts.',
            value: s.nowPlayingStyle,
            options: NowPlayingStyle.values,
            labelOf: (n) => switch (n) {
              NowPlayingStyle.classic => 'Classic',
              NowPlayingStyle.minimal => 'Minimal',
              NowPlayingStyle.studio => 'Studio',
            },
            onChanged: (v) => _set('nowPlayingStyle', v),
          ),
          SwitchSettingsTile(
            title: 'Adaptive colour from album art',
            subtitle: 'Tints Now Playing from the cover, with a contrast '
                'guard so text stays readable.',
            value: s.adaptiveColor,
            onChanged: (v) => _set('adaptiveColor', v),
          ),
          ChoiceSettingsTile<BadgeVisibility>(
            title: 'Format badges',
            subtitle: 'Where to show FLAC 24/96 style chips.',
            value: s.formatBadges,
            options: BadgeVisibility.values,
            labelOf: (b) => switch (b) {
              BadgeVisibility.always => 'Always',
              BadgeVisibility.hiResOnly => 'Hi-Res only',
              BadgeVisibility.never => 'Never',
            },
            onChanged: (v) => _set('formatBadges', v),
          ),
          ChoiceSettingsTile<GridDensity>(
            title: 'Album grid density',
            subtitle: 'How many covers fit across.',
            value: s.gridDensity,
            options: GridDensity.values,
            labelOf: (g) => switch (g) {
              GridDensity.comfortable => 'Comfortable',
              GridDensity.compact => 'Compact',
            },
            onChanged: (v) => _set('gridDensity', v),
            advanced: true,
          ),
          SwitchSettingsTile(
            title: 'Reduce motion',
            subtitle: 'Replaces movement with crossfades.',
            value: s.reduceMotion,
            onChanged: (v) => _set('reduceMotion', v),
            advanced: true,
          ),
        ],
      ),
      SettingsGroup(
        title: 'Notifications & lock screen',
        icon: Icons.notifications_none,
        tiles: [
          SwitchSettingsTile(
            title: 'Media notification',
            subtitle: 'Playback controls in your notification shade.',
            value: s.notificationsEnabled,
            onChanged: (v) => _set('notificationsEnabled', v),
          ),
          SwitchSettingsTile(
            title: 'Artwork on the lock screen',
            subtitle: 'Android draws these from BitDrop\'s media session.',
            value: s.lockScreenArtwork,
            onChanged: (v) => _set('lockScreenArtwork', v),
          ),
        ],
      ),
      SettingsGroup(
        title: 'Diagnostics',
        icon: Icons.monitor_heart_outlined,
        tiles: [
          NavigationSettingsTile(
            title: 'Open diagnostics',
            subtitle: 'Live output, buffer, network, cache and decoder',
            onTap: () => context.push(Routes.diagnostics),
          ),
          NavigationSettingsTile(
            title: 'Export diagnostic report',
            subtitle: 'File names, folder names and tags are removed before '
                'the report is written.',
            onTap: () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Report saved. File names and tags were left out.',
                ),
              ),
            ),
            advanced: true,
          ),
          NavigationSettingsTile(
            title: 'Component gallery',
            subtitle: 'Every component, in every state (developer)',
            onTap: () => context.push(Routes.gallery),
            advanced: true,
          ),
        ],
      ),
      SettingsGroup(
        title: 'Privacy',
        icon: Icons.lock_outline,
        tiles: [
          NavigationSettingsTile(
            title: 'How BitDrop handles your data',
            subtitle: 'There are no BitDrop servers. Nothing leaves this '
                'phone except requests to your own cloud.',
            onTap: () {},
          ),
          NavigationSettingsTile(
            title: 'Sign out and delete local data',
            subtitle: 'Removes the index, the cache and your pinned music '
                'from this device. Your Drive is untouched.',
            onTap: () => _confirmSignOut(context),
            advanced: true,
          ),
        ],
      ),
      SettingsGroup(
        title: 'About',
        icon: Icons.info_outline,
        tiles: [
          NavigationSettingsTile(
            title: 'Version',
            trailingText: '0.1.0 (prototype)',
            onTap: () {},
          ),
          NavigationSettingsTile(
            title: 'Open-source licenses',
            subtitle: 'Inter and JetBrains Mono are used under the SIL Open '
                'Font License.',
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'BitDrop',
              applicationVersion: '0.1.0',
            ),
          ),
        ],
      ),
    ];
  }

  Future<void> _confirmSignOut(BuildContext context) async {
    final ok = await ConfirmDialog.show(
      context,
      title: 'Sign out and delete local data?',
      message: 'Your library index, cache and pinned music are removed from '
          'this device. Nothing in your Google Drive changes.',
      confirmLabel: 'Sign out',
      destructive: true,
    );
    if (ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Signed out. Local data deleted.')),
      );
    }
  }
}

class _PrivacyFooter extends StatelessWidget {
  const _PrivacyFooter();

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      margin: const EdgeInsets.all(Spacing.md),
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: Radii.cardR,
        border: Border.all(color: c.outline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline, size: 18, color: c.success),
          const SizedBox(width: Spacing.xs),
          Expanded(
            child: Text(
              'BitDrop has no servers. Your music, your account and your '
              'listening history never leave this phone and your cloud.',
              style: context.t.bodySmall.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

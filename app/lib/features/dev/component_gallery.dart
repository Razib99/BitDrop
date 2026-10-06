import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core_api/commands.dart';
import '../../core_api/enums.dart';
import '../../core_api/models.dart';
import '../../core_api/settings.dart';
import '../../core_mock/catalog.dart';
import '../../l10n/l10n.dart';
import '../../providers/core_providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../../widgets/cards.dart';
import '../../widgets/common.dart';
import '../../widgets/eq_graph.dart';
import '../../widgets/indicators.dart';
import '../../widgets/meters.dart';
import '../../widgets/rows.dart';
import '../../widgets/settings_tile.dart';
import '../../widgets/signal_path_diagram.dart';
import '../../widgets/transport.dart';

/// Every component from Section 7, in every state, in whichever theme is
/// active. Reachable from the scenario switcher and Settings › Developer.
class ComponentGallery extends ConsumerStatefulWidget {
  const ComponentGallery({super.key});

  @override
  ConsumerState<ComponentGallery> createState() => _ComponentGalleryState();
}

class _ComponentGalleryState extends ConsumerState<ComponentGallery> {
  List<EqBand> _bands = MockCatalog.autoEqProfiles.first.bands;
  int? _selectedBand = 3;
  double _preamp = -6.2;
  bool _switchValue = true;
  double _sliderValue = 16;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final settings = ref.watch(settingsValueProvider);
    final albums = MockCatalog.albums;
    final tracks = MockCatalog.tracks;

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.componentGallery),
        actions: [
          IconButton(
            tooltip: 'Toggle theme',
            icon: Icon(settings.themeMode == AppThemeMode.dark
                ? Icons.light_mode
                : Icons.dark_mode),
            onPressed: () => sendCommand(
              ref,
              SetSetting(
                key: 'themeMode',
                value: settings.themeMode == AppThemeMode.dark
                    ? AppThemeMode.light
                    : AppThemeMode.dark,
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Spacing.huge),
        children: [
          _Group(
            title: 'FormatBadge',
            note: 'Hi-Res filled · CD outlined · lossy muted · unsupported '
                'struck through',
            child: Wrap(
              spacing: Spacing.xs,
              runSpacing: Spacing.xs,
              children: [
                FormatBadge(format: MockCatalog.flac24192),
                FormatBadge(format: MockCatalog.flac2496),
                FormatBadge(format: MockCatalog.alac2448),
                FormatBadge(format: MockCatalog.flac1644),
                FormatBadge(format: MockCatalog.wav2496),
                FormatBadge(format: MockCatalog.mp3320),
                FormatBadge(format: MockCatalog.ape1644),
                FormatBadge(format: MockCatalog.dsf64),
                FormatBadge(format: MockCatalog.flac2496, compact: true),
                FormatBadge(
                  format: MockCatalog.flac1644,
                  visibility: BadgeVisibility.hiResOnly,
                ),
              ],
            ),
          ),
          const _Group(
            title: 'TierChip',
            note: 'Colour + shape + label, always together',
            child: Wrap(
              spacing: Spacing.xs,
              runSpacing: Spacing.xs,
              children: [
                TierChip(tier: OutputTier.bitPerfect, detail: '24/96'),
                TierChip(tier: OutputTier.nativeRate, detail: '24/96'),
                TierChip(tier: OutputTier.resampled, detail: '96 → 48 kHz'),
                TierChip(tier: OutputTier.unknown),
                TierChip(tier: OutputTier.bitPerfect, dense: true),
                DspBadge(),
                DspBadge(dense: true, label: 'EQ'),
              ],
            ),
          ),
          _Group(
            title: 'AvailabilityGlyph',
            note: 'Every cloud state, each with a screen-reader label',
            child: Wrap(
              spacing: Spacing.md,
              runSpacing: Spacing.sm,
              children: [
                for (final a in Availability.values)
                  _Labelled(
                    label: a.name,
                    child: AvailabilityGlyph(
                      availability: a,
                      cachedPercent: 64,
                      downloadProgress: 0.42,
                      size: 20,
                      showCloudOnly: true,
                    ),
                  ),
              ],
            ),
          ),
          _Group(
            title: 'TrackRow',
            padded: false,
            note: 'Default · now playing · partially cached · unsupported · '
                'missing · selected · tags pending',
            child: Column(
              children: [
                TrackRow(track: tracks[0], onTap: () {}),
                TrackRow(track: tracks[2], isPlaying: true, onTap: () {}),
                TrackRow(
                  track: tracks.firstWhere(
                      (t) => t.availability == Availability.partiallyCached),
                  onTap: () {},
                ),
                TrackRow(
                  track: tracks.firstWhere(
                      (t) => t.availability == Availability.unsupported),
                ),
                TrackRow(
                  track: tracks.firstWhere(
                      (t) => t.availability == Availability.missing),
                ),
                TrackRow(
                  track: tracks[1],
                  selectionMode: true,
                  selected: true,
                  onTap: () {},
                ),
                TrackRow(
                  track: tracks[4].copyWith(tagsPending: true),
                  onTap: () {},
                ),
                TrackRow(
                  track: tracks[5],
                  showTrackNumber: true,
                  showAlbumLine: false,
                  onTap: () {},
                ),
              ],
            ),
          ),
          _Group(
            title: 'AlbumCard · AlbumRow · ArtistTile',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: AlbumCard.heightFor(context, 132),
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: 5,
                    separatorBuilder: (_, __) =>
                        const SizedBox(width: Spacing.sm),
                    itemBuilder: (_, i) => SizedBox(
                      width: 132,
                      child: AlbumCard(album: albums[i], onTap: () {}),
                    ),
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                AlbumRow(album: albums[5], onTap: () {}),
                ArtistTile(artist: MockCatalog.artists.first, onTap: () {}),
              ],
            ),
          ),
          _Group(
            title: 'FolderRow · PlaylistRow',
            padded: false,
            child: Column(
              children: [
                FolderRow(
                  entry: const FolderEntry(
                    id: 'fo-hires',
                    name: 'Hi-Res',
                    isDirectory: true,
                    itemCount: 4,
                    sizeBytes: 15710000000,
                  ),
                  onTap: () {},
                  onPlay: () {},
                  onPin: () {},
                ),
                FolderRow(
                  entry: FolderEntry(
                    id: 'file-1',
                    name: '03 - Glass.flac',
                    isDirectory: false,
                    sizeBytes: tracks[2].sizeBytes,
                    track: tracks[2],
                  ),
                  onTap: () {},
                ),
                PlaylistRow(playlist: MockCatalog.playlists[1], onTap: () {}),
                PlaylistRow(playlist: MockCatalog.playlists[4], onTap: () {}),
              ],
            ),
          ),
          _Group(
            title: 'StatusBanner',
            padded: false,
            child: Column(
              children: [
                StatusBanner(
                  kind: BannerKind.info,
                  message: 'Reading tags · 8,214 of 12,480 · Wi-Fi only',
                  onDismiss: () {},
                ),
                StatusBanner(
                  kind: BannerKind.warning,
                  message: 'Google Drive needs you to reconnect. Cached music '
                      'keeps playing.',
                  actionLabel: context.l10n.actionReconnect,
                  onAction: () {},
                ),
                const StatusBanner(
                  kind: BannerKind.error,
                  message: 'Playback stopped — the file is no longer in Drive.',
                ),
                const StatusBanner(
                  kind: BannerKind.success,
                  message: 'Quiet Machines is now available offline.',
                ),
              ],
            ),
          ),
          const _Group(
            title: 'BufferingIndicator · SkeletonLoader',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                BufferingIndicator(
                  state: BufferingState(bufferedMs: 3100, targetMs: 5000),
                ),
                SizedBox(height: Spacing.xs),
                BufferingIndicator(
                  state: BufferingState(
                      bufferedMs: 900, targetMs: 10000, attempt: 3),
                ),
                SizedBox(height: Spacing.md),
                Row(
                  children: [
                    SkeletonLoader(
                        width: 48, height: 48, borderRadius: Radii.gridArtR),
                    SizedBox(width: Spacing.sm),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonLoader(width: 160, height: 14),
                        SizedBox(height: 6),
                        SkeletonLoader(width: 100, height: 11),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          _Group(
            title: 'SegmentedTabs · FilterChipRow · BitChip',
            padded: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedTabs<String>(
                  values: const [
                    'Albums',
                    'Artists',
                    'Tracks',
                    'Folders',
                    'Genres',
                    'Playlists'
                  ],
                  labels: (v) => v,
                  selected: 'Albums',
                  onChanged: (_) {},
                ),
                const SizedBox(height: Spacing.sm),
                FilterChipRow(
                  children: [
                    BitChip(
                        label: 'Filter',
                        icon: Icons.tune,
                        trailingCount: 2,
                        onTap: () {}),
                    BitChip(label: 'Hi-Res', selected: true, onTap: () {}),
                    BitChip(label: 'Lossless only', onTap: () {}),
                    BitChip(label: 'FLAC', mono: true, onTap: () {}),
                    BitChip(
                        label: 'Offline', icon: Icons.push_pin, onTap: () {}),
                  ],
                ),
              ],
            ),
          ),
          _Group(
            title: 'TransportControls · ActionPill',
            child: Column(
              children: [
                const TransportControls(),
                const SizedBox(height: Spacing.md),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ActionPill(
                        icon: Icons.queue_music, label: 'Queue', onTap: () {}),
                    ActionPill(
                        icon: Icons.graphic_eq,
                        label: 'EQ',
                        dot: true,
                        onTap: () {}),
                    ActionPill(
                        icon: Icons.headphones, label: 'Output', onTap: () {}),
                    ActionPill(
                        icon: Icons.lyrics_outlined,
                        label: 'Lyrics',
                        onTap: () {}),
                  ],
                ),
              ],
            ),
          ),
          _Group(
            title: 'SignalPathDiagram',
            padded: false,
            note: 'Resampled verdict with the expert table',
            child: SignalPathDiagram(
              path: _demoPath(OutputTier.resampled),
              showActions: false,
            ),
          ),
          _Group(
            title: 'SignalPathDiagram · DSP active',
            padded: false,
            child: SignalPathDiagram(
              path: _demoPath(OutputTier.nativeRate, dsp: true),
              showActions: false,
            ),
          ),
          _Group(
            title: 'EqGraph + EqBandNode',
            note: 'Drag a node; pinch sets Q. Band list is the non-gesture '
                'alternative.',
            child: Column(
              children: [
                EqGraph(
                  bands: _bands,
                  preampDb: _preamp,
                  selectedBandId: _selectedBand,
                  onSelect: (id) => setState(() => _selectedBand = id),
                  onChanged: (b) => setState(() => _bands = b),
                ),
                const SizedBox(height: Spacing.sm),
                PreampMeter(
                  preampDb: _preamp,
                  clippedSamples: _preamp > 0 ? 1842 : 0,
                  peakDb: _preamp + 3.4,
                  suggestedDb: -6.2,
                  onApplySuggestion: () => setState(() => _preamp = -6.2),
                  onChanged: (v) => setState(() => _preamp = v),
                ),
              ],
            ),
          ),
          _Group(
            title: 'EqBandRow',
            padded: false,
            child: Column(
              children: [
                for (final b in _bands.take(3))
                  EqBandRow(
                    band: b,
                    selected: b.id == _selectedBand,
                    onSelect: () => setState(() => _selectedBand = b.id),
                    onChanged: (nb) => setState(() {
                      _bands = [
                        for (final x in _bands)
                          if (x.id == nb.id) nb else x
                      ];
                    }),
                    onRemove: () {},
                  ),
              ],
            ),
          ),
          _Group(
            title: 'VuMeter · SpectrumView · Sparkline',
            child: Column(
              children: [
                const VuMeter(leftDb: -14.2, rightDb: -11.8, clipping: false),
                const SizedBox(height: Spacing.md),
                const VuMeter(leftDb: -1.2, rightDb: -0.4, clipping: true),
                const SizedBox(height: Spacing.md),
                SpectrumView(
                  bins: List.generate(
                      24, (i) => 0.9 * (1 - i / 26) + (i % 3) * 0.06),
                ),
                const SizedBox(height: Spacing.md),
                const Sparkline(
                  values: [1.2, 2.4, 3.1, 2.8, 4.2, 3.6, 2.1, 3.9, 4.6],
                ),
              ],
            ),
          ),
          _Group(
            title: 'StorageBar',
            child: StorageBar(
              totalBytes: 128000000000,
              segments: [
                (label: 'Pinned', bytes: 18400000000, color: c.success),
                (label: 'Cache', bytes: 6800000000, color: c.accent),
                (label: 'Artwork', bytes: 412000000, color: c.tierNativeRate),
                (label: 'Database', bytes: 96000000, color: c.tierResampled),
              ],
            ),
          ),
          _Group(
            title: 'DeviceCard',
            child: Column(
              children: [
                DeviceCard(
                  device: MockCatalog.titanX,
                  tier: OutputTier.resampled,
                  profile: const DeviceProfile(
                    deviceId: 'dev-titanx',
                    deviceName: 'DUNU Titan X',
                    eqPresetName: 'DUNU Titan X AutoEQ',
                    replayGain: ReplayGainMode.album,
                    preferredVolumeDb: -14,
                  ),
                  onRunSafetyCheck: () {},
                ),
                const SizedBox(height: Spacing.sm),
                const DeviceCard(
                  device: MockCatalog.btBuds,
                  tier: OutputTier.resampled,
                  expanded: false,
                  note: 'Bluetooth uses its own codec — lossless bit-perfect '
                      'is not possible.',
                ),
              ],
            ),
          ),
          _Group(
            title: 'SourceCard',
            child: Column(
              children: [
                SourceCard(
                  account: SourceAccount(
                    id: 's1',
                    provider: 'Google Drive',
                    accountLabel: 'razib@gmail.com',
                    trackCount: 12480,
                    folderCount: 2,
                    status: SourceStatus.syncing,
                    lastSync:
                        DateTime.now().subtract(const Duration(minutes: 5)),
                    activityLabel: 'Reading tags',
                    activityProgress: 0.66,
                    changesSinceLastSync: '+24 new, 3 changed, 1 removed',
                  ),
                  onRescan: () {},
                  showAdvanced: true,
                ),
                const SizedBox(height: Spacing.sm),
                SourceCard(
                  account: SourceAccount(
                    id: 's2',
                    provider: 'Google Drive',
                    accountLabel: 'razib@gmail.com',
                    trackCount: 12480,
                    folderCount: 2,
                    status: SourceStatus.needsReconnect,
                    lastSync: DateTime.now().subtract(const Duration(days: 7)),
                  ),
                  onReconnect: () {},
                ),
              ],
            ),
          ),
          _Group(
            title: 'SettingsTile',
            padded: false,
            child: SettingsGroup(
              title: 'Playback',
              icon: Icons.play_circle_outline,
              tiles: [
                SwitchSettingsTile(
                  title: 'Gapless playback',
                  subtitle: 'Seamless between tracks of the same format.',
                  value: _switchValue,
                  onChanged: (v) => setState(() => _switchValue = v),
                ),
                SwitchSettingsTile(
                  title: 'Crossfade',
                  value: false,
                  enabled: false,
                  disabledReason:
                      'Not available while bit-perfect output is on.',
                  onChanged: (_) {},
                ),
                ChoiceSettingsTile<String>(
                  title: 'ReplayGain',
                  subtitle: 'Evens out loudness between tracks.',
                  value: 'Off',
                  options: const ['Off', 'Track', 'Album'],
                  labelOf: (v) => v,
                  onChanged: (_) {},
                ),
                SliderSettingsTile(
                  title: 'Cache limit',
                  subtitle: 'Pinned albums are never evicted.',
                  value: _sliderValue,
                  min: 1,
                  max: 64,
                  divisions: 63,
                  valueLabel: (v) => '${v.round()} GB',
                  onChanged: (v) => setState(() => _sliderValue = v),
                ),
                NavigationSettingsTile(
                  title: 'Offline & storage',
                  trailingText: Fmt.bytes(25200000000),
                  onTap: () {},
                  advanced: true,
                ),
              ],
            ),
          ),
          _Group(
            title: 'EmptyState',
            child: SizedBox(
              height: 420,
              child: EmptyState(
                icon: Icons.search_off,
                title: 'No results for "24/384"',
                message: 'Nothing in your library matches that.',
                hints: const ['24/192', 'ALAC', 'hi-res', 'flac'],
                actionLabel: 'Clear filters',
                onAction: () {},
              ),
            ),
          ),
          _Group(
            title: 'ConfirmDialog',
            child: Wrap(
              spacing: Spacing.xs,
              children: [
                OutlinedButton(
                  onPressed: () => ConfirmDialog.show(
                    context,
                    title: 'Clear cache?',
                    message: 'Frees 6.8 GB. Pinned albums stay on your device.',
                    confirmLabel: 'Clear cache',
                  ),
                  child: const Text('Standard'),
                ),
                OutlinedButton(
                  onPressed: () => ConfirmDialog.show(
                    context,
                    title: 'Continue without volume control?',
                    message:
                        'This DAC has no hardware volume. BitDrop will apply '
                        '−12 dB of safety attenuation.',
                    confirmLabel: 'I understand',
                    checkboxLabel:
                        'I have removed my earphones and understand the risk.',
                    destructive: true,
                  ),
                  child: const Text('With checkbox'),
                ),
              ],
            ),
          ),
          _Group(
            title: 'Typography',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('display 32/40', style: context.t.display),
                Text('headline 24/32', style: context.t.headline),
                Text('title 20/28', style: context.t.title),
                Text('titleSmall 16/24', style: context.t.titleSmall),
                Text('body 15/22 — the quick brown fox', style: context.t.body),
                Text('bodySmall 13/18 — metadata line',
                    style:
                        context.t.bodySmall.copyWith(color: c.textSecondary)),
                Text('label 12/16', style: context.t.label),
                Text('MONOLABEL 11/14 · FLAC 24/96',
                    style: context.t.monoLabel),
                Text('monoReadout 13/18 · 03:41 · −6.2 dB · 8.4 Mbps',
                    style: context.t.monoReadout),
                Text('monoLarge 20/26 · 192.0 kHz', style: context.t.monoLarge),
              ],
            ),
          ),
          _Group(
            title: 'Colour tokens',
            child: Wrap(
              spacing: Spacing.xs,
              runSpacing: Spacing.xs,
              children: [
                _Swatch('bg', c.bg),
                _Swatch('surface1', c.surface1),
                _Swatch('surface2', c.surface2),
                _Swatch('surface3', c.surface3),
                _Swatch('outline', c.outline),
                _Swatch('accent', c.accent),
                _Swatch('bitPerfect', c.tierBitPerfect),
                _Swatch('nativeRate', c.tierNativeRate),
                _Swatch('resampled', c.tierResampled),
                _Swatch('dspActive', c.dspActive),
                _Swatch('error', c.error),
                _Swatch('success', c.success),
              ],
            ),
          ),
        ],
      ),
    );
  }

  SignalPath _demoPath(OutputTier tier, {bool dsp = false}) => SignalPath(
        tier: tier,
        source: MockCatalog.flac2496,
        requested: MockCatalog.flac2496,
        actual: tier == OutputTier.resampled
            ? MockCatalog.flac2496.copyWith(sampleRate: 48000)
            : MockCatalog.flac2496,
        dspActive: dsp,
        dspChain: dsp
            ? const ['EQ: DUNU Titan X AutoEQ (7 bands)', 'Preamp −6.2 dB']
            : const [],
        volume: dsp ? VolumeMode.softwareDithered : VolumeMode.system,
        device: MockCatalog.titanX,
        cachedPercent: 64,
        throughputMbps: 3.4,
        decoderLabel: 'FLAC → 24-bit integer PCM',
        explanation: dsp
            ? 'Your DAC supports bit-perfect, but the equaliser changes the '
                'samples, so the output is Native rate.'
            : 'Android 12 mixes all audio at 48 kHz before it reaches your '
                'DAC. Bit-perfect output needs Android 14 or later and a '
                'supported DAC.',
      );
}

class _Group extends StatelessWidget {
  const _Group({
    required this.title,
    required this.child,
    this.note,
    this.padded = true,
  });

  final String title;
  final Widget child;
  final String? note;
  final bool padded;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              Spacing.md, Spacing.xl, Spacing.md, Spacing.xxs),
          child: Text(title.toUpperCase(),
              style: context.t.monoLabel.copyWith(color: c.accent)),
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
                Spacing.md, 0, Spacing.md, Spacing.xs),
            child: Text(note!,
                style: context.t.bodySmall.copyWith(color: c.textSecondary)),
          ),
        Padding(
          padding: padded
              ? const EdgeInsets.symmetric(horizontal: Spacing.md)
              : EdgeInsets.zero,
          child: child,
        ),
        const SizedBox(height: Spacing.xs),
        Divider(height: 1, color: c.outline),
      ],
    );
  }
}

class _Labelled extends StatelessWidget {
  const _Labelled({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(height: 24, child: Center(child: child)),
          const SizedBox(height: 4),
          Text(label,
              style:
                  context.t.monoLabel.copyWith(color: context.c.textSecondary)),
        ],
      );
}

class _Swatch extends StatelessWidget {
  const _Swatch(this.name, this.color);

  final String name;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 40,
            decoration: BoxDecoration(
              color: color,
              borderRadius: Radii.badgeR,
              border: Border.all(color: context.c.outline),
            ),
          ),
          const SizedBox(height: 3),
          SizedBox(
            width: 64,
            child: Text(name,
                style: context.t.monoLabel
                    .copyWith(color: context.c.textSecondary),
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis),
          ),
        ],
      );
}

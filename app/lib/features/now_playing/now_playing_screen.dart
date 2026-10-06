import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core_api/commands.dart';
import '../../core_api/enums.dart';
import '../../core_api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/core_providers.dart';
import '../../routing/routes.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../../widgets/artwork.dart';
import '../../widgets/cache_seek_bar.dart';
import '../../widgets/common.dart';
import '../../widgets/indicators.dart';
import '../../widgets/marquee.dart';
import '../../widgets/meters.dart';
import '../../widgets/transport.dart';
import '../signal_path/signal_path_sheet.dart';
import 'track_info_sheet.dart';

/// The hero screen, in three curated styles (Settings › Appearance).
///
/// Nothing here computes a quality claim: the signal chip and every readout
/// render what [signalPathProvider] emits.
class NowPlayingScreen extends ConsumerWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final np = ref.watch(nowPlayingProvider).valueOrNull;
    if (np == null) {
      return Scaffold(
        appBar: AppBar(leading: const _CollapseButton()),
        body: EmptyState(
          icon: Icons.music_note_outlined,
          title: 'Nothing is playing',
          message: 'Pick an album or a playlist to get started.',
          actionLabel: context.l10n.navLibrary,
          onAction: () => context.go(Routes.library),
        ),
      );
    }

    final settings = ref.watch(settingsValueProvider);
    final signal = ref.watch(signalPathProvider).valueOrNull;
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    return Scaffold(
      body: _AdaptiveBackground(
        artwork: np.track.artwork,
        enabled: settings.adaptiveColor,
        child: SafeArea(
          child: Column(
            children: [
              _TopBar(nowPlaying: np),
              Expanded(
                child: landscape
                    ? _LandscapeLayout(
                        nowPlaying: np, signal: signal, style: settings.nowPlayingStyle)
                    : switch (settings.nowPlayingStyle) {
                        NowPlayingStyle.classic =>
                          _ClassicLayout(nowPlaying: np, signal: signal),
                        NowPlayingStyle.minimal =>
                          _MinimalLayout(nowPlaying: np, signal: signal),
                        NowPlayingStyle.studio =>
                          _StudioLayout(nowPlaying: np, signal: signal),
                      },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CollapseButton extends StatelessWidget {
  const _CollapseButton();

  @override
  Widget build(BuildContext context) => IconButton(
        icon: const Icon(Icons.expand_more),
        tooltip: context.l10n.actionBack,
        onPressed: () => Navigator.of(context).maybePop(),
      );
}

class _TopBar extends ConsumerWidget {
  const _TopBar({required this.nowPlaying});

  final NowPlaying nowPlaying;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    return Row(
      children: [
        const _CollapseButton(),
        Expanded(
          child: InkWell(
            onTap: nowPlaying.contextId == null
                ? null
                : () => context.push(Routes.album(nowPlaying.contextId!)),
            borderRadius: Radii.badgeR,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
              child: Column(
                children: [
                  Text(
                    'Playing from',
                    style: context.t.monoLabel.copyWith(color: c.textSecondary),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    nowPlaying.contextLabel,
                    style: context.t.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
        ),
        _OverflowMenu(nowPlaying: nowPlaying),
      ],
    );
  }
}

class _OverflowMenu extends ConsumerWidget {
  const _OverflowMenu({required this.nowPlaying});

  final NowPlaying nowPlaying;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      tooltip: context.l10n.actionMore,
      onSelected: (v) => _handle(context, ref, v),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'album',
          child: ListTile(
            leading: const Icon(Icons.album_outlined),
            title: Text(context.l10n.actionGoToAlbum),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'artist',
          child: ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text(context.l10n.actionGoToArtist),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const PopupMenuItem(
          value: 'info',
          child: ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Track info'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'pin',
          child: ListTile(
            leading: const Icon(Icons.push_pin_outlined),
            title: Text(context.l10n.actionPinOffline),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const PopupMenuItem(
          value: 'sleep',
          child: ListTile(
            leading: Icon(Icons.bedtime_outlined),
            title: Text('Sleep timer'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }

  void _handle(BuildContext context, WidgetRef ref, String value) {
    switch (value) {
      case 'album':
        if (nowPlaying.contextId != null) {
          context.push(Routes.album(nowPlaying.track.albumId));
        }
      case 'artist':
        final album = nowPlaying.album;
        if (album != null) context.push(Routes.artist(album.artistId));
      case 'info':
        showTrackInfoSheet(context, nowPlaying.track);
      case 'pin':
        sendCommand(ref, Pin(id: nowPlaying.track.id, kind: 'track'));
      case 'sleep':
        _showSleepTimer(context, ref);
    }
  }

  void _showSleepTimer(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(Spacing.md),
              child: Text('Sleep timer'),
            ),
            for (final m in [15, 30, 45, 60, 90])
              ListTile(
                title: Text('$m minutes'),
                onTap: () {
                  sendCommand(ref, SetSleepTimer(m));
                  Navigator.of(context).pop();
                },
              ),
            ListTile(
              title: const Text('Off'),
              onTap: () {
                sendCommand(ref, const SetSleepTimer(null));
                Navigator.of(context).pop();
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Classic: art-led, the default.
class _ClassicLayout extends ConsumerWidget {
  const _ClassicLayout({required this.nowPlaying, required this.signal});

  final NowPlaying nowPlaying;
  final SignalPath? signal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = MediaQuery.sizeOf(context).width;
    final scale = MediaQuery.textScalerOf(context).scale(1);

    // At large text sizes the controls alone fill the screen, so the whole
    // layout becomes scrollable with a smaller, fixed piece of art. Below
    // that, the art takes whatever height is left over.
    if (scale > 1.3) {
      return SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: Spacing.md),
            _SwipeableArt(
              nowPlaying: nowPlaying,
              size: (width - Spacing.xl * 2).clamp(120.0, 220.0),
            ),
            const SizedBox(height: Spacing.lg),
            ..._controls(context),
            const SizedBox(height: Spacing.lg),
          ],
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              final side = width - Spacing.xl * 2;
              final size = (side < box.maxHeight ? side : box.maxHeight)
                  .clamp(96.0, 420.0);
              return Center(
                child: _SwipeableArt(
                  nowPlaying: nowPlaying,
                  size: size.toDouble(),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: Spacing.md),
        ..._controls(context),
        const SizedBox(height: Spacing.sm),
      ],
    );
  }

  /// Everything below the artwork, shared by both height strategies.
  List<Widget> _controls(BuildContext context) => [
        _TitleBlock(nowPlaying: nowPlaying),
        const SizedBox(height: Spacing.sm),
        if (signal != null) _SignalChip(signal: signal!),
        const SizedBox(height: Spacing.md),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.xl),
          child: CacheSeekBar(durationMs: nowPlaying.track.durationMs),
        ),
        const SizedBox(height: Spacing.xs),
        const _VolumeHint(),
        const SizedBox(height: Spacing.sm),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: Spacing.md),
          child: TransportControls(),
        ),
        const SizedBox(height: Spacing.sm),
        _BottomActions(nowPlaying: nowPlaying),
      ];
}

/// Minimal: small art, large type, technical detail up front.
class _MinimalLayout extends ConsumerWidget {
  const _MinimalLayout({required this.nowPlaying, required this.signal});

  final NowPlaying nowPlaying;
  final SignalPath? signal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final track = nowPlaying.track;

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: Spacing.xl),
            AlbumArtwork(
              artwork: track.artwork,
              size: 96,
              title: track.albumTitle,
            ),
            const SizedBox(height: Spacing.xl),
            Marquee(text: track.title, style: context.t.display),
            const SizedBox(height: Spacing.xs),
            Text(
              track.artist,
              style: context.t.title.copyWith(color: c.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              track.albumTitle,
              style: context.t.body.copyWith(color: c.textTertiary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: Spacing.lg),
            if (signal != null) ...[
              _TechLine(label: 'SOURCE', value: signal!.source.badgeLabel),
              _TechLine(label: 'OUTPUT', value: signal!.actual.longLabel),
              _TechLine(
                  label: 'BITRATE', value: Fmt.kbps(signal!.source.bitrateKbps)),
              _TechLine(
                label: 'DEVICE',
                value: signal!.device?.name ?? context.l10n.signalNoDevice,
              ),
              const SizedBox(height: Spacing.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: _SignalChip(signal: signal!),
              ),
            ],
            const SizedBox(height: Spacing.lg),
            CacheSeekBar(durationMs: track.durationMs),
            const SizedBox(height: Spacing.md),
            const TransportControls(compact: true),
            const SizedBox(height: Spacing.md),
            _BottomActions(nowPlaying: nowPlaying),
            const SizedBox(height: Spacing.lg),
          ],
        ),
      ),
    );
  }
}

/// Studio: meters, spectrum and a full technical readout.
class _StudioLayout extends ConsumerWidget {
  const _StudioLayout({required this.nowPlaying, required this.signal});

  final NowPlaying nowPlaying;
  final SignalPath? signal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final frame =
        ref.watch(visualizerProvider).valueOrNull ?? VisualizerFrame.silent;
    final info = ref.watch(positionProvider).valueOrNull;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AlbumArtwork(
                artwork: nowPlaying.track.artwork,
                size: 84,
                title: nowPlaying.track.albumTitle,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Marquee(text: nowPlaying.track.title, style: context.t.title),
                    const SizedBox(height: 2),
                    Text(
                      '${nowPlaying.track.artist} · '
                      '${nowPlaying.track.albumTitle}',
                      style:
                          context.t.bodySmall.copyWith(color: c.textSecondary),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: Spacing.xs),
                    if (signal != null) _SignalChip(signal: signal!),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          VuMeter(
            leftDb: frame.peakLeftDb,
            rightDb: frame.peakRightDb,
            clipping: frame.clipping,
          ),
          const SizedBox(height: Spacing.sm),
          SpectrumView(bins: frame.spectrum),
          const SizedBox(height: Spacing.sm),
          if (signal != null)
            Container(
              padding: const EdgeInsets.all(Spacing.sm),
              decoration: BoxDecoration(
                color: c.surface2,
                borderRadius: Radii.chipR,
                border: Border.all(color: c.outline),
              ),
              child: Column(
                children: [
                  _TechLine(
                      label: 'SOURCE FORMAT',
                      value: signal!.source.badgeLabel),
                  _TechLine(
                      label: 'OUTPUT FORMAT', value: signal!.actual.longLabel),
                  _TechLine(
                      label: 'BITRATE',
                      value: Fmt.kbps(signal!.source.bitrateKbps)),
                  _TechLine(
                    label: 'BUFFER',
                    value: info == null
                        ? '—'
                        : '${(info.bufferAheadMs / 1000).toStringAsFixed(1)} s',
                  ),
                  _TechLine(
                    label: 'CACHED',
                    value: '${signal!.cachedPercent}%',
                  ),
                  _TechLine(
                    label: 'VOLUME',
                    value: switch (signal!.volume) {
                      VolumeMode.dacHardware => 'DAC hardware',
                      VolumeMode.softwareDithered => 'Software, dithered',
                      VolumeMode.system => 'System',
                    },
                  ),
                ],
              ),
            ),
          const SizedBox(height: Spacing.sm),
          CacheSeekBar(durationMs: nowPlaying.track.durationMs),
          const SizedBox(height: Spacing.xs),
          const TransportControls(compact: true),
          const SizedBox(height: Spacing.xs),
          _BottomActions(nowPlaying: nowPlaying),
          const SizedBox(height: Spacing.md),
        ],
      ),
    );
  }
}

class _LandscapeLayout extends ConsumerWidget {
  const _LandscapeLayout({
    required this.nowPlaying,
    required this.signal,
    required this.style,
  });

  final NowPlaying nowPlaying;
  final SignalPath? signal;
  final NowPlayingStyle style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final height = MediaQuery.sizeOf(context).height;
    final artSize = (height - 120).clamp(100.0, 340.0);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Padding(
          padding: const EdgeInsets.all(Spacing.md),
          child: _SwipeableArt(
            nowPlaying: nowPlaying,
            size: artSize.toDouble(),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(right: Spacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _TitleBlock(nowPlaying: nowPlaying, alignStart: true),
                const SizedBox(height: Spacing.xs),
                if (signal != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _SignalChip(signal: signal!),
                  ),
                const SizedBox(height: Spacing.sm),
                CacheSeekBar(durationMs: nowPlaying.track.durationMs),
                const SizedBox(height: Spacing.sm),
                const TransportControls(compact: true),
                const SizedBox(height: Spacing.xs),
                _BottomActions(nowPlaying: nowPlaying),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Album art with horizontal swipe-to-skip. Double-tap deliberately does
/// nothing, so a mistaken tap cannot change playback.
class _SwipeableArt extends ConsumerWidget {
  const _SwipeableArt({required this.nowPlaying, required this.size});

  final NowPlaying nowPlaying;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v < -180) {
          sendCommand(ref, const Next());
        } else if (v > 180) {
          sendCommand(ref, const Previous());
        }
      },
      onLongPress: () => context.push(Routes.album(nowPlaying.track.albumId)),
      child: Hero(
        tag: 'art-${nowPlaying.track.albumId}',
        child: AnimatedSwitcher(
          duration: Motion.emphasized,
          switchInCurve: Motion.enter,
          child: AlbumArtwork(
            key: ValueKey(nowPlaying.track.id),
            artwork: nowPlaying.track.artwork,
            size: size,
            title: nowPlaying.track.albumTitle,
            borderRadius: Radii.heroArtR,
          ),
        ),
      ),
    );
  }
}

class _TitleBlock extends ConsumerWidget {
  const _TitleBlock({required this.nowPlaying, this.alignStart = false});

  final NowPlaying nowPlaying;
  final bool alignStart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final track = nowPlaying.track;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.xl),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: alignStart
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.center,
              children: [
                Marquee(
                  text: track.title,
                  style: context.t.title,
                  textAlign: alignStart ? TextAlign.start : TextAlign.center,
                ),
                const SizedBox(height: 2),
                Text(
                  '${track.artist} · ${track.albumTitle}',
                  style: context.t.bodySmall.copyWith(color: c.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: alignStart ? TextAlign.start : TextAlign.center,
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => sendCommand(
              ref,
              SetFavorite(trackId: track.id, favorite: !track.favorite),
            ),
            icon: Icon(
              track.favorite ? Icons.favorite : Icons.favorite_border,
              color: track.favorite ? c.accent : c.textSecondary,
            ),
            tooltip: track.favorite ? 'Remove from favourites' : 'Favourite',
          ),
        ],
      ),
    );
  }
}

/// The one-line verdict, tappable into the full Signal Path.
class _SignalChip extends StatelessWidget {
  const _SignalChip({required this.signal});

  final SignalPath signal;

  @override
  Widget build(BuildContext context) {
    final detail = signal.tier == OutputTier.resampled
        ? '${Fmt.kHzBare(signal.source.sampleRate)} → '
            '${Fmt.kHz(signal.actual.sampleRate)}'
        : signal.actual.shortLabel;
    final device = signal.device?.name;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Spacing.xs,
        runSpacing: Spacing.xxs,
        children: [
          TierChip(
            tier: signal.tier,
            detail: device == null ? detail : '$detail → $device',
            onTap: () => showSignalPathSheet(context),
          ),
          if (signal.dspActive) const DspBadge(),
        ],
      ),
    );
  }
}

/// In bit-perfect mode BitDrop applies no digital gain, so the user needs to
/// know where the volume actually lives.
class _VolumeHint extends ConsumerWidget {
  const _VolumeHint();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signal = ref.watch(signalPathProvider).valueOrNull;
    if (signal == null || signal.volume != VolumeMode.dacHardware) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: Spacing.xl, vertical: Spacing.xxs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.volume_up_outlined,
              size: 14, color: context.c.textSecondary),
          const SizedBox(width: Spacing.xxs),
          Flexible(
            child: Text(
              'Volume is controlled by your DAC. Use the volume keys.',
              style: context.t.bodySmall
                  .copyWith(color: context.c.textSecondary),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomActions extends ConsumerWidget {
  const _BottomActions({required this.nowPlaying});

  final NowPlaying nowPlaying;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eq = ref.watch(eqProvider).valueOrNull;
    final signal = ref.watch(signalPathProvider).valueOrNull;
    final l = context.l10n;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        ActionPill(
          icon: Icons.queue_music,
          label: l.navQueue,
          onTap: () => context.push(Routes.queue),
        ),
        ActionPill(
          icon: Icons.graphic_eq,
          label: l.navEq,
          dot: eq?.isActive ?? false,
          onTap: () => context.push(Routes.equalizer),
        ),
        ActionPill(
          icon: switch (signal?.device?.type) {
            DeviceType.bluetooth => Icons.bluetooth,
            DeviceType.phoneSpeaker => Icons.smartphone,
            _ => Icons.headphones,
          },
          label: l.navOutput,
          onTap: () => context.push(Routes.output),
        ),
        // Lyrics appear only when the file actually carries them: BitDrop has
        // no servers, so there is nowhere to fetch them from.
        if (nowPlaying.track.hasLyrics)
          ActionPill(
            icon: Icons.lyrics_outlined,
            label: l.navLyrics,
            onTap: () => showLyricsSheet(context, nowPlaying.track),
          ),
        ActionPill(
          icon: Icons.more_horiz,
          label: l.actionMore,
          onTap: () => showTrackInfoSheet(context, nowPlaying.track),
        ),
      ],
    );
  }
}

/// Tints the background from the album's dominant colour, with a luminance
/// clamp so text contrast still passes.
class _AdaptiveBackground extends StatelessWidget {
  const _AdaptiveBackground({
    required this.artwork,
    required this.enabled,
    required this.child,
  });

  final Artwork artwork;
  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    if (!enabled) return ColoredBox(color: c.bg, child: child);

    final dark = Theme.of(context).brightness == Brightness.dark;
    final hsl = HSLColor.fromColor(Color(artwork.dominantColor));
    final tint = hsl
        .withSaturation((hsl.saturation * (dark ? 0.55 : 0.35)).clamp(0.0, 0.6))
        .withLightness(dark
            ? (hsl.lightness * 0.35).clamp(0.06, 0.18)
            : (hsl.lightness * 1.5).clamp(0.86, 0.97))
        .toColor();

    return AnimatedContainer(
      duration: Motion.emphasized,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [tint, c.bg],
          stops: const [0, 0.7],
        ),
      ),
      child: child,
    );
  }
}

class _TechLine extends StatelessWidget {
  const _TechLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 118,
              child: Text(
                label,
                style: context.t.monoLabel
                    .copyWith(color: context.c.textSecondary),
              ),
            ),
            Expanded(
              child: Text(value,
                  style: context.t.monoReadout,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      );
}

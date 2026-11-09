import 'dart:math' as math;
import 'dart:ui';
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
import '../../util/poster_color.dart';
import '../../widgets/artwork.dart';
import '../../widgets/cache_seek_bar.dart';
import '../../widgets/common.dart';
import '../../widgets/marquee.dart';
import '../../widgets/meters.dart';
import '../../widgets/transport.dart';
import '../signal_path/signal_path_sheet.dart';
import 'ambient_lyrics_view.dart';
import 'track_info_sheet.dart';

/// The hero screen, in three curated styles (Settings › Appearance).
///
/// Nothing here computes a quality claim: the signal chip and every readout
/// render what [signalPathProvider] emits.
class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen> {
  double _dragOffset = 0.0;
  bool _isDragging = false;
  bool _showLyrics = false;

  void _onVerticalDragStart(DragStartDetails details) {
    _isDragging = true;
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    final delta = details.primaryDelta ?? 0.0;
    if (delta > 0 || _dragOffset > 0) {
      setState(() {
        _dragOffset = math.max(0.0, _dragOffset + delta);
      });
    }
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    _isDragging = false;
    final velocity = details.primaryVelocity ?? 0.0;
    if (_dragOffset > 90 || velocity > 320) {
      Navigator.of(context).maybePop();
    } else {
      setState(() {
        _dragOffset = 0.0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final np = ref.watch(nowPlayingProvider).valueOrNull;
    if (np == null) {
      return Scaffold(
        appBar: AppBar(leading: const NowPlayingCollapseButton()),
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

    return GestureDetector(
      onVerticalDragStart: _onVerticalDragStart,
      onVerticalDragUpdate: _onVerticalDragUpdate,
      onVerticalDragEnd: _onVerticalDragEnd,
      behavior: HitTestBehavior.translucent,
      child: AnimatedContainer(
        duration:
            _isDragging ? Duration.zero : const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        transform: Matrix4.translationValues(0, _dragOffset, 0),
        child: Scaffold(
          body: NowPlayingAdaptiveBackground(
            artwork: np.track.artwork,
            trackTitle: np.track.albumTitle,
            enabled: settings.adaptiveColor,
            child: SafeArea(
              child: Column(
                children: [
                  NowPlayingTopBar(nowPlaying: np),
                  Expanded(
                    child: landscape
                        ? _LandscapeLayout(
                            nowPlaying: np,
                            signal: signal,
                            style: settings.nowPlayingStyle)
                        : switch (settings.nowPlayingStyle) {
                            NowPlayingStyle.classic =>
                              _ClassicLayout(
                                nowPlaying: np,
                                signal: signal,
                                showLyrics: _showLyrics,
                                onToggleLyrics: () =>
                                    setState(() => _showLyrics = !_showLyrics),
                              ),
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
        ),
      ),
    );
  }
}

class NowPlayingCollapseButton extends StatelessWidget {
  const NowPlayingCollapseButton({super.key, this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
        icon: const Icon(Icons.expand_more),
        tooltip: context.l10n.actionBack,
        onPressed: onPressed ?? () => Navigator.of(context).maybePop(),
      );
}

class NowPlayingTopBar extends ConsumerWidget {
  const NowPlayingTopBar({super.key, required this.nowPlaying, this.onCollapse});

  final NowPlaying nowPlaying;
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    return Row(
      children: [
        NowPlayingCollapseButton(onPressed: onCollapse),
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
        NowPlayingOverflowMenu(nowPlaying: nowPlaying),
      ],
    );
  }
}

class NowPlayingOverflowMenu extends ConsumerWidget {
  const NowPlayingOverflowMenu({super.key, required this.nowPlaying});

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
  const _ClassicLayout({
    required this.nowPlaying,
    required this.signal,
    this.showLyrics = false,
    this.onToggleLyrics,
  });

  final NowPlaying nowPlaying;
  final SignalPath? signal;
  final bool showLyrics;
  final VoidCallback? onToggleLyrics;

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
            AnimatedCrossFade(
              firstChild: Center(
                child: NowPlayingSwipeableArt(
                  nowPlaying: nowPlaying,
                  size: (width - Spacing.xl * 2).clamp(120.0, 220.0),
                ),
              ),
              secondChild: SizedBox(
                height: 220.0,
                width: width - Spacing.xl * 2,
                child: AmbientLyricsView(
                  track: nowPlaying.track,
                  onClose: onToggleLyrics,
                ),
              ),
              crossFadeState: showLyrics
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 320),
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
                child: AnimatedCrossFade(
                  firstChild: NowPlayingSwipeableArt(
                    nowPlaying: nowPlaying,
                    size: size.toDouble(),
                  ),
                  secondChild: SizedBox(
                    height: box.maxHeight,
                    width: width - Spacing.md * 2,
                    child: AmbientLyricsView(
                      track: nowPlaying.track,
                      onClose: onToggleLyrics,
                    ),
                  ),
                  crossFadeState: showLyrics
                      ? CrossFadeState.showSecond
                      : CrossFadeState.showFirst,
                  duration: const Duration(milliseconds: 320),
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
        NowPlayingTitleBlock(nowPlaying: nowPlaying),
        const SizedBox(height: Spacing.sm),
        if (signal != null) NowPlayingSignalChip(signal: signal!),
        const SizedBox(height: Spacing.md),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.xl),
          child: CacheSeekBar(
            durationMs: nowPlaying.track.durationMs,
            activeColor: const Color(0xFFF1F5F9),
          ),
        ),
        const SizedBox(height: Spacing.xs),
        const NowPlayingVolumeHint(),
        const SizedBox(height: Spacing.sm),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: Spacing.md),
          child: TransportControls(),
        ),
        const SizedBox(height: Spacing.sm),
        NowPlayingBottomActions(
          nowPlaying: nowPlaying,
          showLyrics: showLyrics,
          onToggleLyrics: onToggleLyrics,
        ),
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
                  label: 'BITRATE',
                  value: Fmt.kbps(signal!.source.effectiveBitrateKbps > 0
                      ? signal!.source.effectiveBitrateKbps
                      : signal!.source.bitrateKbps)),
              _TechLine(
                label: 'DEVICE',
                value: signal!.device?.name ?? context.l10n.signalNoDevice,
              ),
              const SizedBox(height: Spacing.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: NowPlayingSignalChip(signal: signal!),
              ),
            ],
            const SizedBox(height: Spacing.lg),
            CacheSeekBar(
              durationMs: track.durationMs,
              activeColor: const Color(0xFFF1F5F9),
            ),
            const SizedBox(height: Spacing.md),
            const TransportControls(compact: true),
            const SizedBox(height: Spacing.md),
            NowPlayingBottomActions(nowPlaying: nowPlaying),
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
                    Marquee(
                        text: nowPlaying.track.title, style: context.t.title),
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
                    if (signal != null) NowPlayingSignalChip(signal: signal!),
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
                      label: 'SOURCE FORMAT', value: signal!.source.badgeLabel),
                  _TechLine(
                      label: 'OUTPUT FORMAT', value: signal!.actual.longLabel),
                  _TechLine(
                      label: 'BITRATE',
                      value: Fmt.kbps(signal!.source.effectiveBitrateKbps > 0
                          ? signal!.source.effectiveBitrateKbps
                          : signal!.source.bitrateKbps)),
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
          CacheSeekBar(
            durationMs: nowPlaying.track.durationMs,
            activeColor: const Color(0xFFF1F5F9),
          ),
          const SizedBox(height: Spacing.xs),
          const TransportControls(compact: true),
          const SizedBox(height: Spacing.xs),
          NowPlayingBottomActions(nowPlaying: nowPlaying),
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
          child: NowPlayingSwipeableArt(
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
                NowPlayingTitleBlock(nowPlaying: nowPlaying, alignStart: true),
                const SizedBox(height: Spacing.xs),
                if (signal != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: NowPlayingSignalChip(signal: signal!),
                  ),
                const SizedBox(height: Spacing.sm),
                CacheSeekBar(
                  durationMs: nowPlaying.track.durationMs,
                  activeColor: const Color(0xFFF1F5F9),
                ),
                const SizedBox(height: Spacing.sm),
                const TransportControls(compact: true),
                const SizedBox(height: Spacing.xs),
                NowPlayingBottomActions(nowPlaying: nowPlaying),
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
class NowPlayingSwipeableArt extends ConsumerWidget {
  const NowPlayingSwipeableArt({super.key, required this.nowPlaying, required this.size});

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
      onLongPress: () =>
          context.push(Routes.album(nowPlaying.track.albumId)),
      child: Center(
        child: Container(
          decoration: BoxDecoration(
            borderRadius: Radii.heroArtR,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.48),
                blurRadius: 36,
                spreadRadius: 2,
                offset: const Offset(0, 16),
              ),
            ],
          ),
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
        ),
      ),
    );
  }
}

class NowPlayingTitleBlock extends ConsumerWidget {
  const NowPlayingTitleBlock({super.key, required this.nowPlaying, this.alignStart = false});

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
          if (!alignStart) const SizedBox(width: 48),
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

/// Translucent frosted-glass "Live Signal Path Pill" directly beneath track title/artist.
/// Compact audiophile badge (e.g. FLAC · 24-bit / 96.0 kHz · Bit-Perfect or 64-Bit DSP · 48.0 kHz).
/// Tapping the pill opens the full Signal Path & Hardware Telemetry Inspector sheet.
class NowPlayingSignalChip extends StatelessWidget {
  const NowPlayingSignalChip({super.key, required this.signal});

  final SignalPath signal;

  @override
  Widget build(BuildContext context) {
    final isDsd = signal.source.isDsd ||
        signal.actual.isDsd ||
        (signal.decoderLabel?.contains('DoP') ?? false);
    final isResampled = signal.tier == OutputTier.resampled ||
        signal.source.sampleRate != signal.actual.sampleRate;
    final isBitPerfect = signal.tier == OutputTier.bitPerfect;
    final isDspNative = !isResampled && signal.dspActive;
    final isAndroidMixed =
        !isResampled && !signal.dspActive && !isBitPerfect && !isDsd;

    final Color statusColor;
    final Color dotColor;
    final IconData statusIcon;
    final String statusLabel;
    final String subText;
    final device = signal.device?.name;

    if (isDsd) {
      statusColor = const Color(0xFF8B5CF6);
      dotColor = const Color(0xFF8B5CF6);
      statusIcon = Icons.waves;
      statusLabel = signal.source.shortLabel;
      final dopDesc = signal.decoderLabel?.contains('DoP') == true ||
              signal.device?.type == DeviceType.usb
          ? 'DoP v1.1 · Direct USB'
          : 'Decimated PCM';
      subText = device == null ? ' · $dopDesc' : ' · $dopDesc → $device';
    } else if (isBitPerfect) {
      statusColor = context.c.tierBitPerfect;
      dotColor = const Color(0xFF10B981);
      statusIcon = Icons.diamond_outlined;
      statusLabel = 'BIT-PERFECT';
      final detail =
          '${Fmt.kHz(signal.source.sampleRate)} / ${signal.source.bitDepth}-bit';
      subText = device == null ? ' · $detail' : ' · $detail → $device';
    } else if (isDspNative) {
      statusColor = context.c.dspActive;
      dotColor = const Color(0xFF06B6D4);
      statusIcon = Icons.graphic_eq;
      statusLabel = '64-BIT DSP';
      final detail = 'Native ${Fmt.kHz(signal.source.sampleRate)}';
      subText = device == null ? ' · $detail' : ' · $detail → $device';
    } else if (isAndroidMixed) {
      statusColor = context.c.tierNativeRate;
      dotColor = const Color(0xFF38BDF8);
      statusIcon = Icons.check_circle_outline;
      statusLabel = 'NATIVE RATE (${Fmt.kHz(signal.source.sampleRate)})';
      subText = device == null
          ? ' · Android Mixed'
          : ' · Android Mixed → $device';
    } else if (isResampled) {
      statusColor = context.c.tierResampled;
      dotColor = const Color(0xFFF59E0B);
      statusIcon = Icons.change_history;
      statusLabel = 'RESAMPLED';
      final detail =
          '${Fmt.kHzBare(signal.source.sampleRate)} → ${Fmt.kHz(signal.actual.sampleRate)}';
      subText = device == null ? ' · $detail' : ' · $detail → $device';
    } else {
      statusColor = const Color(0xFF9E9E9E);
      dotColor = const Color(0xFF9E9E9E);
      statusIcon = Icons.info_outline;
      statusLabel = 'STANDARD';
      subText = device == null ? '' : ' · $device';
    }

    final screenWidth = MediaQuery.sizeOf(context).width;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
      child: Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => showSignalPathSheet(context),
                borderRadius: BorderRadius.circular(24),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  constraints: BoxConstraints(
                    maxWidth: screenWidth - Spacing.md * 2,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(isBitPerfect ? 0.16 : 0.10),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color:
                          statusColor.withOpacity(isBitPerfect ? 0.65 : 0.35),
                      width: isBitPerfect ? 1.2 : 0.9,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        key: const Key('signal_pill_status_dot'),
                        width: 7,
                        height: 7,
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(
                          color: dotColor,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: dotColor.withOpacity(0.65),
                              blurRadius: 4,
                              spreadRadius: 0.5,
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        statusIcon,
                        size: 13,
                        color: statusColor,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        statusLabel,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: statusColor,
                        ),
                      ),
                      if (subText.isNotEmpty)
                        Flexible(
                          child: Text(
                            subText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: statusColor.withOpacity(0.9),
                            ),
                          ),
                        ),
                      const SizedBox(width: 5),
                      Icon(
                        Icons.chevron_right,
                        size: 13,
                        color: statusColor.withOpacity(0.8),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// In bit-perfect mode BitDrop applies no digital gain, so the user needs to
/// know where the volume actually lives.
class NowPlayingVolumeHint extends ConsumerWidget {
  const NowPlayingVolumeHint({super.key});

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
              style:
                  context.t.bodySmall.copyWith(color: context.c.textSecondary),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

class NowPlayingBottomActions extends ConsumerWidget {
  const NowPlayingBottomActions({
    super.key,
    required this.nowPlaying,
    this.showLyrics = false,
    this.onToggleLyrics,
  });

  final NowPlaying nowPlaying;
  final bool showLyrics;
  final VoidCallback? onToggleLyrics;

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
        ActionPill(
          icon: showLyrics ? Icons.album_outlined : Icons.lyrics_outlined,
          label: showLyrics ? 'Artwork' : l.navLyrics,
          active: showLyrics,
          onTap: () {
            if (onToggleLyrics != null) {
              onToggleLyrics!();
            } else {
              showLyricsSheet(context, nowPlaying.track);
            }
          },
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

/// Tints the background from the album's vibrant poster colour, radiating
/// an ambient aura that flows through the music player window.
/// Spotify-style ambient player window background: soft light flowing from the
/// album's poster colour at the top, fading smoothly into solid deep background
/// behind the controls.
class NowPlayingAdaptiveBackground extends StatelessWidget {
  const NowPlayingAdaptiveBackground({
    super.key,
    required this.artwork,
    this.trackTitle,
    required this.enabled,
    required this.child,
  });

  final Artwork artwork;
  final String? trackTitle;
  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    if (!enabled) return ColoredBox(color: c.bg, child: child);

    final dark = Theme.of(context).brightness == Brightness.dark;

    return FutureBuilder<Color>(
      future: PosterColor.resolve(artwork, title: trackTitle),
      initialData: PosterColor.of(artwork, title: trackTitle),
      builder: (context, snapshot) {
        final posterColor =
            snapshot.data ?? PosterColor.of(artwork, title: trackTitle);

        final topColor = Color.lerp(posterColor, c.bg, dark ? 0.38 : 0.20)!;
        final midColor = Color.lerp(posterColor, c.bg, dark ? 0.72 : 0.60)!;

        return AnimatedContainer(
          duration: Motion.emphasized,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                topColor,
                midColor,
                c.bg,
                c.bg,
              ],
              stops: const [0.0, 0.42, 0.78, 1.0],
            ),
          ),
          child: child,
        );
      },
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

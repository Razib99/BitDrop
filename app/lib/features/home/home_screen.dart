import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core_api/commands.dart';
import '../../core_api/enums.dart';
import '../../core_api/models.dart';
import '../../core_api/queries.dart';
import '../../l10n/l10n.dart';
import '../../providers/core_providers.dart';
import '../../providers/player_sheet_provider.dart';
import '../storage/google_drive_service.dart';
import '../../routing/routes.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../../util/poster_color.dart';
import '../../widgets/artwork.dart';
import '../../widgets/cards.dart';
import '../../widgets/common.dart';
import '../../widgets/indicators.dart';
import '../../widgets/rows.dart';

/// Home: what is playing out of, what to resume, and what is worth opening.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(sourcesProvider).valueOrNull ?? const [];
    final signal = ref.watch(signalPathProvider).valueOrNull;
    final sync = ref.watch(syncStatusProvider).valueOrNull ?? SyncStatus.idle;
    final albumsAsync = ref.watch(albumsProvider(const AlbumQuery()));

    final hasContent = (albumsAsync.valueOrNull?.items.isNotEmpty) ?? false;
    if (sources.isEmpty && !hasContent && !albumsAsync.isLoading) {
      return const _NoSourceHome();
    }
    final nowPlaying = ref.watch(nowPlayingProvider).valueOrNull;
    final settings = ref.watch(settingsValueProvider);

    return CustomScrollView(
      slivers: [
        SliverAppBar(
          floating: true,
          title: const Text('BitDrop'),
          actions: [
            IconButton(
              tooltip: context.l10n.navSearch,
              icon: const Icon(Icons.search),
              onPressed: () => context.go(Routes.search),
            ),
            IconButton(
              tooltip: context.l10n.navSettings,
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => context.push(Routes.settings),
            ),
          ],
        ),
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (signal != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      Spacing.md, Spacing.xs, Spacing.md, 0),
                  child: OutputSummaryCard(
                    path: signal,
                    onTap: () => context.push(Routes.output),
                  ),
                ),
              if (sync.isActive || sync.phase == SyncPhase.paused)
                _ScanCard(status: sync),
              if (nowPlaying != null)
                _ContinueListening(nowPlaying: nowPlaying),
            ],
          ),
        ),
        ...albumsAsync.when(
          skipLoadingOnReload: true,
          skipLoadingOnRefresh: true,
          loading: () => [const SliverToBoxAdapter(child: _RowSkeleton())],
          error: (e, _) => [
            SliverToBoxAdapter(
              child: StatusBanner(
                kind: BannerKind.error,
                message: 'Could not read the library. $e',
                actionLabel: context.l10n.actionRetry,
                onAction: () =>
                    ref.invalidate(albumsProvider(const AlbumQuery())),
              ),
            ),
          ],
          data: (paged) {
            final all = paged.items;
            final recent = [...all]..sort((a, b) =>
                (b.addedAt ?? DateTime(2000))
                    .compareTo(a.addedAt ?? DateTime(2000)));
            final mostPlayed = [...all]
              ..sort((a, b) => b.playCount.compareTo(a.playCount));
            final offline = all
                .where((a) =>
                    a.availability == Availability.pinned ||
                    a.availability == Availability.cached)
                .toList();
            final hiRes = all.where((a) => a.format.isHiRes).toList();

            return [
              _AlbumShelf(
                title: 'Recently added',
                albums: recent.take(8).toList(),
                badges: settings.formatBadges,
              ),
              _AlbumShelf(
                title: 'Most played',
                albums: mostPlayed.take(8).toList(),
                badges: settings.formatBadges,
              ),
              if (offline.isNotEmpty)
                _AlbumShelf(
                  title: 'Ready offline',
                  subtitle: 'Plays without a network',
                  albums: offline,
                  badges: settings.formatBadges,
                ),
              if (hiRes.isNotEmpty)
                _AlbumShelf(
                  title: 'Hi-Res picks',
                  subtitle: '24-bit and above',
                  albums: hiRes,
                  badges: settings.formatBadges,
                ),
              const SliverToBoxAdapter(child: SizedBox(height: Spacing.xxl)),
            ];
          },
        ),
      ],
    );
  }
}

class _NoSourceHome extends ConsumerWidget {
  const _NoSourceHome();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        AppBar(
          title: const Text('BitDrop'),
          actions: [
            IconButton(
              tooltip: context.l10n.navSettings,
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => context.push(Routes.settings),
            ),
          ],
        ),
        Expanded(
          child: GoogleDriveService.isPlatformSupported
              ? EmptyState(
                  icon: Icons.cloud_off,
                  title: 'No music source yet',
                  message:
                      'BitDrop streams from your own cloud. Connect Google '
                      'Drive and your library appears in seconds — no servers '
                      'in between.',
                  actionLabel: 'Connect Google Drive',
                  onAction: () => context.push(Routes.onboarding),
                )
              : const EmptyState(
                  icon: Icons.desktop_access_disabled,
                  title: 'No music here yet',
                  message:
                      'Google Drive sign-in has no desktop implementation, so '
                      'the cloud library is only available in the Android and '
                      'iOS builds. Local files still play here.',
                ),
        ),
      ],
    );
  }
}

/// Scan progress, including the rate-limited pause with its countdown.
class _ScanCard extends ConsumerWidget {
  const _ScanCard({required this.status});

  final SyncStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final paused = status.phase == SyncPhase.paused;

    return Container(
      margin: const EdgeInsets.fromLTRB(
          Spacing.md, Spacing.xs, Spacing.md, 0),
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: Radii.cardR,
        border: Border.all(color: c.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              paused
                  ? Icon(
                      Icons.hourglass_top,
                      size: 16,
                      color: c.tierResampled,
                    )
                  : SpinningSyncIcon(
                      size: 16,
                      color: c.accent,
                    ),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: Text(
                  paused
                      ? 'Scanning paused · Drive is limiting requests'
                      : switch (status.phase) {
                          SyncPhase.listing => 'Listing files',
                          SyncPhase.tags => 'Reading tags',
                          _ => 'Scanning',
                        },
                  style: context.t.titleSmall,
                ),
              ),
              Text(
                paused
                    ? 'retry in ${status.retryInSeconds ?? 0}s'
                    : '${Fmt.count(status.processed)} / '
                        '${Fmt.count(status.total)}',
                style: context.t.monoReadout.copyWith(color: c.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(
              height: 4,
              child: LinearProgressIndicator(
                value: status.progress,
                backgroundColor: c.surface3,
                color: paused ? c.tierResampled : c.accent,
              ),
            ),
          ),
          const SizedBox(height: Spacing.xs),
          Row(
            children: [
              Expanded(
                child: Text(
                  paused
                      ? 'Playback is not affected. Scanning resumes automatically.'
                      : 'Your library is ready to browse. Details fill in over '
                          '${status.wifiOnly ? 'Wi-Fi' : 'any network'}.',
                  style: context.t.bodySmall.copyWith(color: c.textSecondary),
                ),
              ),
              TextButton(
                onPressed: () => ref.read(cloudLibraryProvider).cancelScan(),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 32),
                  foregroundColor: c.textSecondary,
                ),
                child: const Text('Stop Sync'),
              ),
            ],
          ),

        ],
      ),
    );
  }
}

class _ContinueListening extends ConsumerWidget {
  const _ContinueListening({required this.nowPlaying});

  final NowPlaying nowPlaying;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = nowPlaying.track.albumTitle;
    final initialColor =
        PosterColor.of(nowPlaying.track.artwork, title: title);

    return FutureBuilder<Color>(
      future: PosterColor.resolve(nowPlaying.track.artwork, title: title),
      initialData: initialColor,
      builder: (context, snapshot) {
        final posterColor = snapshot.data ?? initialColor;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: 'Continue listening'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
              child: _ContinueListeningCard(
                nowPlaying: nowPlaying,
                posterColor: posterColor,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ContinueListeningCard extends ConsumerStatefulWidget {
  const _ContinueListeningCard({
    required this.nowPlaying,
    required this.posterColor,
  });

  final NowPlaying nowPlaying;
  final Color posterColor;

  @override
  ConsumerState<_ContinueListeningCard> createState() =>
      _ContinueListeningCardState();
}

class _ContinueListeningCardState extends ConsumerState<_ContinueListeningCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 7000),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final info = ref.watch(positionProvider).valueOrNull;
    final playback =
        ref.watch(playbackProvider).valueOrNull ?? const IdleState();
    final signal = ref.watch(signalPathProvider).valueOrNull;
    final isPlaying = playback.isPlaying;
    final isBusy = playback.isBusy;

    final durationMs = info?.durationMs ?? widget.nowPlaying.track.durationMs;
    final positionMs = info?.positionMs ?? 0;
    final progress = info?.fraction ??
        (durationMs > 0 ? (positionMs / durationMs).clamp(0.0, 1.0) : 0.0);

    const frostedWhite = Color(0xFFF1F5F9);
    const glyphColor = Color(0xFF0F172A);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value * 2 * math.pi;
        final driftX = math.sin(t) * 0.15;
        final driftY = math.cos(t) * 0.12;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          decoration: BoxDecoration(
            borderRadius: Radii.cardR,
            gradient: LinearGradient(
              begin: Alignment(-1.0 + driftX, -1.0 + driftY),
              end: Alignment(1.0 - driftX, 1.0 - driftY),
              colors: [
                widget.posterColor.withOpacity(0.18),
                c.surface2.withOpacity(0.88),
                c.surface1,
              ],
              stops: const [0.0, 0.45, 1.0],
            ),
            border: Border.all(
              color: widget.posterColor.withOpacity(0.16),
              width: 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: widget.posterColor
                    .withOpacity(0.12 + math.sin(t).abs() * 0.05),
                blurRadius: 22,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragUpdate: (d) {
                if ((d.primaryDelta ?? 0) < -6) {
                  ref.read(playerSheetControllerProvider).expand();
                }
              },
              child: InkWell(
                onTap: () => ref.read(playerSheetControllerProvider).expand(),
                borderRadius: Radii.cardR,
                child: Padding(
                  padding: const EdgeInsets.all(Spacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              AlbumArtwork(
                                artwork: widget.nowPlaying.track.artwork,
                                size: 56,
                                title: widget.nowPlaying.track.albumTitle,
                              ),
                              if (isPlaying || isBusy)
                                Container(
                                  width: 56,
                                  height: 56,
                                  color: Colors.black.withOpacity(0.40),
                                  alignment: Alignment.center,
                                  child: MiniBarsIndicator(
                                    isDancing: isPlaying,
                                    color: widget.posterColor,
                                    barWidth: 2.2,
                                    barSpacing: 1.8,
                                    maxHeight: 14.0,
                                    minHeight: 4.0,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: Spacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.nowPlaying.track.title,
                                style: context.t.titleSmall.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${widget.nowPlaying.track.artist} · ${widget.nowPlaying.contextLabel}',
                                style: context.t.bodySmall.copyWith(
                                  color: c.textSecondary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: Spacing.xs),
                        IconButton(
                          onPressed: () {
                            HapticFeedback.selectionClick();
                            sendCommand(ref, const Previous());
                          },
                          icon: const Icon(Icons.skip_previous_rounded),
                          iconSize: 20,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.all(Spacing.xs),
                          tooltip: context.l10n.actionPrevious,
                        ),
                        IconButton(
                          onPressed: () {
                            HapticFeedback.mediumImpact();
                            sendCommand(
                              ref,
                              isPlaying ? const Pause() : const Resume(),
                            );
                          },
                          icon: isBusy
                              ? Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: frostedWhite,
                                      ),
                                    ),
                                    Icon(
                                      isPlaying
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                      size: 13,
                                      color: glyphColor,
                                    ),
                                  ],
                                )
                              : Icon(
                                  isPlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  color: glyphColor,
                                ),
                          iconSize: 22,
                          style: IconButton.styleFrom(
                            backgroundColor: frostedWhite,
                            foregroundColor: glyphColor,
                            minimumSize: const Size(38, 38),
                            padding: EdgeInsets.zero,
                            elevation: 1,
                            shadowColor: Colors.white.withOpacity(0.10),
                          ),
                          tooltip: isPlaying
                              ? context.l10n.actionPause
                              : context.l10n.actionPlay,
                        ),
                        IconButton(
                          onPressed: () {
                            HapticFeedback.selectionClick();
                            sendCommand(ref, const Next());
                          },
                          icon: const Icon(Icons.skip_next_rounded),
                          iconSize: 20,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.all(Spacing.xs),
                          tooltip: context.l10n.actionNext,
                        ),
                      ],
                    ),
                    const SizedBox(height: Spacing.xs + 3),
                    Row(
                      children: [
                        if (signal != null) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: (signal.tier == OutputTier.bitPerfect
                                      ? c.tierBitPerfect
                                      : c.tierResampled)
                                  .withOpacity(0.16),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: (signal.tier == OutputTier.bitPerfect
                                        ? c.tierBitPerfect
                                        : c.tierResampled)
                                    .withOpacity(0.35),
                                width: 0.8,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 5,
                                  height: 5,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: signal.tier == OutputTier.bitPerfect
                                        ? c.tierBitPerfect
                                        : c.tierResampled,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  signal.tier.label.toUpperCase(),
                                  style: context.t.monoReadout.copyWith(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                    color: signal.tier == OutputTier.bitPerfect
                                        ? c.tierBitPerfect
                                        : c.tierResampled,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 5),
                        ],
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: c.surface3,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: c.outline, width: 0.8),
                          ),
                          child: Text(
                            '${widget.nowPlaying.track.format.codec.name.toUpperCase()} · ${widget.nowPlaying.track.format.bitDepth}/${widget.nowPlaying.track.format.sampleRate ~/ 1000}',
                            style: context.t.monoReadout.copyWith(
                              fontSize: 9,
                              color: widget.posterColor,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          '${widget.nowPlaying.track.format.effectiveBitrateKbps} kbps',
                          style: context.t.monoReadout.copyWith(
                            fontSize: 9,
                            color: c.textSecondary,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${Fmt.duration(positionMs)} / ${Fmt.duration(durationMs)}',
                          style: context.t.monoReadout.copyWith(
                            fontSize: 10,
                            color: c.textSecondary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: SizedBox(
                        height: 3.5,
                        child: Stack(
                          children: [
                            Container(color: c.surface3),
                            if (info != null &&
                                info.bufferAheadMs > 0 &&
                                durationMs > 0)
                              FractionallySizedBox(
                                widthFactor: ((positionMs + info.bufferAheadMs) /
                                        durationMs)
                                    .clamp(0.0, 1.0),
                                child: Container(
                                  color: widget.posterColor.withOpacity(0.20),
                                ),
                              ),
                            FractionallySizedBox(
                              widthFactor: progress.clamp(0.0, 1.0),
                              child: Container(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      widget.posterColor.withOpacity(0.70),
                                      widget.posterColor,
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      },
    );
  }
}

/// Horizontal album row used for every Home shelf.
class _AlbumShelf extends StatelessWidget {
  const _AlbumShelf({
    required this.title,
    required this.albums,
    required this.badges,
    this.subtitle,
  });

  final String title;
  final List<Album> albums;
  final BadgeVisibility badges;
  final String? subtitle;

  static const double _cardWidth = 134;

  @override
  Widget build(BuildContext context) {
    if (albums.isEmpty) return const SliverToBoxAdapter();
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(title: title, subtitle: subtitle),
          SizedBox(
            height: AlbumCard.heightFor(context, _cardWidth),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
              itemCount: albums.length,
              separatorBuilder: (_, __) => const SizedBox(width: Spacing.sm),
              itemBuilder: (context, i) => SizedBox(
                width: _cardWidth,
                child: AlbumCard(
                  album: albums[i],
                  badgeVisibility: badges,
                  onTap: () => context.push(Routes.album(albums[i].id)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RowSkeleton extends StatelessWidget {
  const _RowSkeleton();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: SizedBox(
          height: 190,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            child: Row(
              children: [
                for (var i = 0; i < 3; i++)
                  const Padding(
                    padding: EdgeInsets.only(right: Spacing.sm),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonLoader(
                            width: 134,
                            height: 134,
                            borderRadius: Radii.gridArtR),
                        SizedBox(height: 8),
                        SkeletonLoader(width: 100, height: 12),
                        SizedBox(height: 5),
                        SkeletonLoader(width: 70, height: 10),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
}

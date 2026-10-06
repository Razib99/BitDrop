import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core_api/commands.dart';
import '../../core_api/enums.dart';
import '../../core_api/models.dart';
import '../../core_api/queries.dart';
import '../../l10n/l10n.dart';
import '../../providers/core_providers.dart';
import '../../routing/routes.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../../widgets/artwork.dart';
import '../../widgets/cards.dart';
import '../../widgets/common.dart';
import '../../widgets/rows.dart';

/// Home: what is playing out of, what to resume, and what is worth opening.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(sourcesProvider).valueOrNull ?? const [];
    if (sources.isEmpty) return const _NoSourceHome();

    final signal = ref.watch(signalPathProvider).valueOrNull;
    final sync = ref.watch(syncStatusProvider).valueOrNull ?? SyncStatus.idle;
    final albumsAsync = ref.watch(albumsProvider(const AlbumQuery()));
    final nowPlaying = ref.watch(nowPlayingProvider).valueOrNull;
    final settings = ref.watch(settingsValueProvider);

    return CustomScrollView(
      slivers: [
        SliverAppBar(
          floating: true,
          title: const Text('BitDrop'),
          actions: [
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
          child: EmptyState(
            icon: Icons.cloud_off,
            title: 'No music source yet',
            message:
                'BitDrop streams from your own cloud. Connect Google Drive '
                'and your library appears in seconds — no servers in between.',
            actionLabel: 'Connect Google Drive',
            onAction: () => context.push(Routes.onboarding),
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
              Icon(
                paused ? Icons.hourglass_top : Icons.sync,
                size: 16,
                color: paused ? c.tierResampled : c.accent,
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
          Text(
            paused
                ? 'Playback is not affected. Scanning resumes automatically.'
                : 'Your library is ready to browse. Details fill in over '
                    '${status.wifiOnly ? 'Wi-Fi' : 'any network'}.',
            style: context.t.bodySmall.copyWith(color: c.textSecondary),
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
    final c = context.c;
    final info = ref.watch(positionProvider).valueOrNull;
    final progress = info == null || info.durationMs == 0
        ? 0.0
        : info.positionMs / info.durationMs;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Continue listening'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
          child: Card(
            child: InkWell(
              onTap: () => context.push(Routes.nowPlaying),
              borderRadius: Radii.cardR,
              child: Padding(
                padding: const EdgeInsets.all(Spacing.sm),
                child: Row(
                  children: [
                    AlbumArtwork(
                      artwork: nowPlaying.track.artwork,
                      size: 60,
                      title: nowPlaying.track.albumTitle,
                    ),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            nowPlaying.track.title,
                            style: context.t.titleSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            nowPlaying.contextLabel,
                            style: context.t.bodySmall
                                .copyWith(color: c.textSecondary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: Spacing.xs),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: SizedBox(
                              height: 3,
                              child: LinearProgressIndicator(
                                value: progress.clamp(0.0, 1.0),
                                backgroundColor: c.surface3,
                                color: c.accent,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: Spacing.xs),
                    IconButton.filled(
                      onPressed: () => sendCommand(ref, const Resume()),
                      icon: const Icon(Icons.play_arrow),
                      tooltip: context.l10n.actionPlay,
                      style: IconButton.styleFrom(
                        backgroundColor: c.accent,
                        foregroundColor: c.onAccent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
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

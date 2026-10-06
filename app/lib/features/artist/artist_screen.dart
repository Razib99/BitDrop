import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core_api/commands.dart';
import '../../core_api/models.dart';
import '../../core_api/queries.dart';
import '../../providers/core_providers.dart';
import '../../routing/routes.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/artwork.dart';
import '../../widgets/common.dart';
import '../../widgets/rows.dart';

/// Artist detail: a collage header, albums by year, and the tracks this
/// device has played most (local history only — there is no server).
class ArtistScreen extends ConsumerWidget {
  const ArtistScreen({super.key, required this.artistId});

  final String artistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artistAsync = ref.watch(artistProvider(artistId));
    final albumsAsync =
        ref.watch(albumsProvider(AlbumQuery(artistId: artistId)));
    final artistTracksAsync = ref.watch(tracksProvider(
      TrackQuery(filters: LibraryFilters(artistId: artistId)),
    ));
    final settings = ref.watch(settingsValueProvider);

    return Scaffold(
      body: artistAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline,
          title: 'Could not open this artist',
          message: '$e',
        ),
        data: (artist) {
          if (artist == null) {
            return const EmptyState(
              icon: Icons.person_outline,
              title: 'Artist not found',
            );
          }
          final albums = albumsAsync.valueOrNull?.items ?? const <Album>[];
          final byYear = [...albums]
            ..sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0));
          final popular =
              artistTracksAsync.valueOrNull?.items ?? const <Track>[];

          return CustomScrollView(
            slivers: [
              _Header(artist: artist, albums: albums),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: Spacing.md, vertical: Spacing.xs),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: popular.isEmpty
                              ? null
                              : () => sendCommand(
                                    ref,
                                    PlayContext(
                                      contextId: artist.id,
                                      trackIds:
                                          popular.map((t) => t.id).toList(),
                                      shuffle: true,
                                      contextLabel: 'Artist · ${artist.name}',
                                    ),
                                  ),
                          icon: const Icon(Icons.shuffle),
                          label: const Text('Shuffle artist'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (byYear.isNotEmpty) ...[
                const SliverToBoxAdapter(
                  child: SectionHeader(title: 'Albums'),
                ),
                SliverList.builder(
                  itemCount: byYear.length,
                  itemBuilder: (context, i) => AlbumRow(
                    album: byYear[i],
                    badgeVisibility: settings.formatBadges,
                    onTap: () => context.push(Routes.album(byYear[i].id)),
                  ),
                ),
              ],
              if (popular.isNotEmpty) ...[
                const SliverToBoxAdapter(
                  child: SectionHeader(
                    title: 'Played most',
                    subtitle: 'From this device only',
                  ),
                ),
                SliverList.builder(
                  itemCount: popular.length.clamp(0, 5),
                  itemBuilder: (context, i) => TrackRow(
                    track: popular[i],
                    badgeVisibility: settings.formatBadges,
                    onTap: () => sendCommand(
                      ref,
                      PlayContext(
                        contextId: artist.id,
                        trackIds: popular.map((t) => t.id).toList(),
                        startIndex: i,
                        contextLabel: 'Artist · ${artist.name}',
                      ),
                    ),
                    onPlayNext: () =>
                        sendCommand(ref, PlayNext([popular[i].id])),
                    onAddToQueue: () =>
                        sendCommand(ref, Enqueue([popular[i].id])),
                  ),
                ),
              ],
              const SliverToBoxAdapter(child: SizedBox(height: Spacing.xxl)),
            ],
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.artist, required this.albums});

  final Artist artist;
  final List<Album> albums;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SliverAppBar(
      pinned: true,
      expandedHeight: 240,
      backgroundColor: c.bg,
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          fit: StackFit.expand,
          children: [
            // Collage of the artist's album art, faded behind the name.
            Row(
              children: [
                for (final a in albums.take(3))
                  Expanded(
                    child: AlbumArtwork(
                      artwork: a.artwork,
                      size: 200,
                      borderRadius: BorderRadius.zero,
                    ),
                  ),
                if (albums.isEmpty)
                  Expanded(
                    child: AlbumArtwork(
                      artwork: artist.artwork,
                      size: 200,
                      borderRadius: BorderRadius.zero,
                    ),
                  ),
              ],
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    c.bg.withOpacity(0.35),
                    c.bg.withOpacity(0.75),
                    c.bg,
                  ],
                ),
              ),
            ),
            Positioned(
              left: Spacing.md,
              right: Spacing.md,
              bottom: Spacing.md,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    artist.name,
                    style: context.t.display,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${artist.albumCount} album'
                    '${artist.albumCount == 1 ? '' : 's'} · '
                    '${artist.trackCount} tracks'
                    '${artist.genres.isEmpty ? '' : ' · ${artist.genres.join(', ')}'}',
                    style: context.t.bodySmall.copyWith(color: c.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

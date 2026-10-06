import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core_api/commands.dart';
import '../../core_api/enums.dart';
import '../../core_api/models.dart';
import '../../core_api/settings.dart';
import '../../core_api/queries.dart';
import '../../l10n/l10n.dart';
import '../../providers/core_providers.dart';
import '../../routing/routes.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/common.dart';
import '../../widgets/rows.dart';
import '../folders/folder_browser.dart';
import 'filter_sheet.dart';
import 'selection_bar.dart';

/// Library: six tabs over the same index, with sort, view and filter.
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(libraryTabProvider);
    final filters = ref.watch(libraryFiltersProvider);
    final grid = ref.watch(libraryGridViewProvider);
    final selection = ref.watch(selectionProvider);
    final l = context.l10n;

    return Column(
      children: [
        if (selection.isEmpty)
          _Toolbar(tab: tab, grid: grid, filters: filters)
        else
          const SelectionBar(),
        SegmentedTabs<LibraryTab>(
          values: LibraryTab.values,
          labels: (t) => switch (t) {
            LibraryTab.albums => 'Albums',
            LibraryTab.artists => 'Artists',
            LibraryTab.tracks => 'Tracks',
            LibraryTab.folders => 'Folders',
            LibraryTab.genres => 'Genres',
            LibraryTab.playlists => l.navLibrary == '' ? '' : 'Playlists',
          },
          selected: tab,
          onChanged: (t) {
            ref.read(libraryTabProvider.notifier).state = t;
            ref.read(selectionProvider.notifier).state = const {};
          },
        ),
        const SizedBox(height: Spacing.xs),
        if (filters.isActive) _ActiveFilterSummary(filters: filters),
        Expanded(
          child: switch (tab) {
            LibraryTab.albums => const _AlbumsTab(),
            LibraryTab.artists => const _ArtistsTab(),
            LibraryTab.tracks => const _TracksTab(),
            LibraryTab.folders => const FolderBrowser(),
            LibraryTab.genres => const _GenresTab(),
            LibraryTab.playlists => const _PlaylistsTab(),
          },
        ),
      ],
    );
  }
}

class _Toolbar extends ConsumerWidget {
  const _Toolbar({
    required this.tab,
    required this.grid,
    required this.filters,
  });

  final LibraryTab tab;
  final bool grid;
  final LibraryFilters filters;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showsGridToggle = tab == LibraryTab.albums;
    final showsSort =
        tab == LibraryTab.albums || tab == LibraryTab.tracks;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          Spacing.md, Spacing.xs, Spacing.xs, 0),
      child: Row(
        children: [
          Text(context.l10n.navLibrary, style: context.t.headline),
          const Spacer(),
          if (showsSort)
            IconButton(
              tooltip: 'Sort',
              icon: const Icon(Icons.sort),
              onPressed: () => showSortSheet(context, ref),
            ),
          if (showsGridToggle)
            IconButton(
              tooltip: grid ? 'Show as list' : 'Show as grid',
              icon: Icon(grid ? Icons.view_list : Icons.grid_view),
              onPressed: () =>
                  ref.read(libraryGridViewProvider.notifier).state = !grid,
            ),
          Stack(
            clipBehavior: Clip.none,
            children: [
              IconButton(
                tooltip: 'Filter',
                icon: const Icon(Icons.tune),
                onPressed: () => showFilterSheet(context),
              ),
              if (filters.isActive)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: context.c.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
          IconButton(
            tooltip: context.l10n.navSettings,
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push(Routes.settings),
          ),
        ],
      ),
    );
  }
}

class _ActiveFilterSummary extends ConsumerWidget {
  const _ActiveFilterSummary({required this.filters});

  final LibraryFilters filters;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parts = <String>[
      ...filters.codecs.map((c) => c.label),
      if (filters.quality != QualityFilter.any)
        switch (filters.quality) {
          QualityFilter.hiRes => 'Hi-Res',
          QualityFilter.cdQuality => 'CD',
          QualityFilter.lossy => 'Lossy',
          QualityFilter.any => '',
        },
      if (filters.availability != AvailabilityFilter.any)
        switch (filters.availability) {
          AvailabilityFilter.offline => 'Pinned',
          AvailabilityFilter.cached => 'On device',
          AvailabilityFilter.cloudOnly => 'Cloud only',
          AvailabilityFilter.any => '',
        },
      if (filters.genre != null) filters.genre!,
      if (!filters.showUnsupported) 'Supported only',
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          Spacing.md, 0, Spacing.md, Spacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Filtered: ${parts.join(' · ')}',
              style: context.t.monoLabel
                  .copyWith(color: context.c.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () => ref.read(libraryFiltersProvider.notifier).state =
                const LibraryFilters(),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 28),
              padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
            ),
            child: Text(context.l10n.actionClear, style: context.t.label),
          ),
        ],
      ),
    );
  }
}

class _AlbumsTab extends ConsumerWidget {
  const _AlbumsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = AlbumQuery(
      sort: ref.watch(albumSortProvider),
      descending: ref.watch(albumSortDescProvider),
      filters: ref.watch(libraryFiltersProvider),
    );
    final async = ref.watch(albumsProvider(query));
    final grid = ref.watch(libraryGridViewProvider);
    final settings = ref.watch(settingsValueProvider);
    final selection = ref.watch(selectionProvider);

    return async.when(
      loading: () => const _GridSkeleton(),
      error: (e, _) => _ErrorState(
        error: e,
        onRetry: () => ref.invalidate(albumsProvider(query)),
      ),
      data: (paged) {
        if (paged.items.isEmpty) return const _NoMatches();
        if (!grid) {
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: Spacing.xxl),
            itemCount: paged.items.length,
            itemBuilder: (context, i) => AlbumRow(
              album: paged.items[i],
              badgeVisibility: settings.formatBadges,
              onTap: () => context.push(Routes.album(paged.items[i].id)),
              onLongPress: () => _toggle(ref, paged.items[i].id),
            ),
          );
        }

        final width = MediaQuery.sizeOf(context).width;
        final columns = switch (width) {
          < 400 => settings.gridDensity == GridDensity.compact ? 3 : 2,
          < 840 => 3,
          _ => 5,
        };
        final margin = Spacing.screenMargin(width);
        final cardWidth =
            (width - margin * 2 - Spacing.sm * (columns - 1)) / columns;

        return GridView.builder(
          padding: EdgeInsets.fromLTRB(
              margin, Spacing.xs, margin, Spacing.xxl),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: Spacing.md,
            crossAxisSpacing: Spacing.sm,
            mainAxisExtent: AlbumCard.heightFor(context, cardWidth),
          ),
          itemCount: paged.items.length,
          itemBuilder: (context, i) {
            final album = paged.items[i];
            return AlbumCard(
              album: album,
              badgeVisibility: settings.formatBadges,
              selectionMode: selection.isNotEmpty,
              selected: selection.contains(album.id),
              onTap: selection.isEmpty
                  ? () => context.push(Routes.album(album.id))
                  : () => _toggle(ref, album.id),
              onLongPress: () => _toggle(ref, album.id),
            );
          },
        );
      },
    );
  }

  void _toggle(WidgetRef ref, String id) {
    final current = {...ref.read(selectionProvider)};
    current.contains(id) ? current.remove(id) : current.add(id);
    ref.read(selectionProvider.notifier).state = current;
  }
}

class _ArtistsTab extends ConsumerWidget {
  const _ArtistsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(artistsProvider(const ArtistQuery()));
    return async.when(
      loading: () => const _ListSkeleton(),
      error: (e, _) => _ErrorState(
        error: e,
        onRetry: () => ref.invalidate(artistsProvider(const ArtistQuery())),
      ),
      data: (paged) => ListView.builder(
        padding: const EdgeInsets.only(bottom: Spacing.xxl),
        itemCount: paged.items.length,
        itemBuilder: (context, i) => ArtistTile(
          artist: paged.items[i],
          onTap: () => context.push(Routes.artist(paged.items[i].id)),
        ),
      ),
    );
  }
}

/// Tracks tab, with an alphabet scrubber for very large libraries.
class _TracksTab extends ConsumerStatefulWidget {
  const _TracksTab();

  @override
  ConsumerState<_TracksTab> createState() => _TracksTabState();
}

class _TracksTabState extends ConsumerState<_TracksTab> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = TrackQuery(
      sort: ref.watch(trackSortProvider),
      filters: ref.watch(libraryFiltersProvider),
    );
    final async = ref.watch(tracksProvider(query));
    final settings = ref.watch(settingsValueProvider);
    final selection = ref.watch(selectionProvider);

    return async.when(
      loading: () => const _ListSkeleton(),
      error: (e, _) => _ErrorState(
        error: e,
        onRetry: () => ref.invalidate(tracksProvider(query)),
      ),
      data: (paged) {
        if (paged.items.isEmpty) return const _NoMatches();
        return Stack(
          children: [
            ListView.builder(
              controller: _controller,
              padding: const EdgeInsets.only(
                  right: Spacing.lg, bottom: Spacing.xxl),
              itemCount: paged.items.length,
              itemExtent: 64,
              itemBuilder: (context, i) {
                final t = paged.items[i];
                return TrackRow(
                  track: t,
                  badgeVisibility: settings.formatBadges,
                  selectionMode: selection.isNotEmpty,
                  selected: selection.contains(t.id),
                  onTap: selection.isEmpty
                      ? () => sendCommand(
                            ref,
                            PlayContext(
                              contextId: 'tracks',
                              trackIds:
                                  paged.items.map((x) => x.id).toList(),
                              startIndex: i,
                              contextLabel: 'All tracks',
                            ),
                          )
                      : () => _toggle(t.id),
                  onLongPress: () => _toggle(t.id),
                  onPlayNext: () => sendCommand(ref, PlayNext([t.id])),
                  onAddToQueue: () => sendCommand(ref, Enqueue([t.id])),
                );
              },
            ),
            _AlphabetScrubber(
              letters: _letters(paged.items),
              onPick: (index) => _controller.jumpTo(
                (index * 64).toDouble().clamp(
                      0,
                      _controller.position.maxScrollExtent,
                    ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _toggle(String id) {
    final current = {...ref.read(selectionProvider)};
    current.contains(id) ? current.remove(id) : current.add(id);
    ref.read(selectionProvider.notifier).state = current;
  }

  /// First row index for each initial letter present in the list.
  Map<String, int> _letters(List<Track> tracks) {
    final out = <String, int>{};
    for (var i = 0; i < tracks.length; i++) {
      final ch = tracks[i].title.isEmpty
          ? '#'
          : tracks[i].title[0].toUpperCase();
      final key = RegExp(r'[A-Z]').hasMatch(ch) ? ch : '#';
      out.putIfAbsent(key, () => i);
    }
    return out;
  }
}

class _AlphabetScrubber extends StatelessWidget {
  const _AlphabetScrubber({required this.letters, required this.onPick});

  final Map<String, int> letters;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    if (letters.length < 4) return const SizedBox.shrink();
    final keys = letters.keys.toList()..sort();

    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      width: Spacing.lg,
      child: Semantics(
        label: 'Jump to letter',
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final k in keys)
              Expanded(
                child: InkWell(
                  onTap: () => onPick(letters[k]!),
                  child: Center(
                    child: Text(
                      k,
                      style: context.t.monoLabel
                          .copyWith(color: context.c.textSecondary),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _GenresTab extends ConsumerWidget {
  const _GenresTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(genresProvider);
    return async.when(
      loading: () => const _ListSkeleton(),
      error: (e, _) =>
          _ErrorState(error: e, onRetry: () => ref.invalidate(genresProvider)),
      data: (genres) => ListView.builder(
        padding: const EdgeInsets.only(bottom: Spacing.xxl),
        itemCount: genres.length,
        itemBuilder: (context, i) => ListTile(
          leading: const Icon(Icons.local_offer_outlined),
          title: Text(genres[i]),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            // Filtering by genre and switching to Albums is the shortest path
            // to "show me this genre".
            ref.read(libraryFiltersProvider.notifier).state =
                ref.read(libraryFiltersProvider).copyWith(genre: genres[i]);
            ref.read(libraryTabProvider.notifier).state = LibraryTab.albums;
          },
        ),
      ),
    );
  }
}

class _PlaylistsTab extends ConsumerWidget {
  const _PlaylistsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(playlistsProvider);
    return async.when(
      loading: () => const _ListSkeleton(),
      error: (e, _) => _ErrorState(
          error: e, onRetry: () => ref.invalidate(playlistsProvider)),
      data: (playlists) {
        if (playlists.isEmpty) {
          return const EmptyState(
            icon: Icons.queue_music,
            title: 'No playlists yet',
            message: 'Save a queue as a playlist, or add tracks from any list.',
          );
        }
        final smart = playlists.where((p) => p.isSmart).toList();
        final mine = playlists.where((p) => !p.isSmart).toList();
        return ListView(
          padding: const EdgeInsets.only(bottom: Spacing.xxl),
          children: [
            if (mine.isNotEmpty) ...[
              const SectionHeader(title: 'Your playlists'),
              for (final p in mine)
                PlaylistRow(
                  playlist: p,
                  onTap: () => context.push(Routes.playlist(p.id)),
                ),
            ],
            if (smart.isNotEmpty) ...[
              const SectionHeader(
                title: 'Automatic',
                subtitle: 'Built from your library, kept up to date',
              ),
              for (final p in smart)
                PlaylistRow(
                  playlist: p,
                  onTap: () => context.push(Routes.playlist(p.id)),
                ),
            ],
          ],
        );
      },
    );
  }
}

class _NoMatches extends ConsumerWidget {
  const _NoMatches();

  @override
  Widget build(BuildContext context, WidgetRef ref) => EmptyState(
        icon: Icons.filter_alt_off_outlined,
        title: 'Nothing matches these filters',
        message: 'Try widening the format or quality filter.',
        actionLabel: context.l10n.actionClear,
        onAction: () => ref.read(libraryFiltersProvider.notifier).state =
            const LibraryFilters(),
      );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => EmptyState(
        icon: Icons.error_outline,
        title: 'Could not read the library',
        message: '$error',
        actionLabel: context.l10n.actionRetry,
        onAction: onRetry,
      );
}

/// Skeleton rows while the first scan pass is still filling in tags.
class _ListSkeleton extends StatelessWidget {
  const _ListSkeleton();

  @override
  Widget build(BuildContext context) => ListView.builder(
        itemCount: 8,
        itemBuilder: (context, i) => const Padding(
          padding: EdgeInsets.symmetric(
              horizontal: Spacing.md, vertical: Spacing.xs),
          child: Row(
            children: [
              SkeletonLoader(
                  width: 48, height: 48, borderRadius: Radii.gridArtR),
              SizedBox(width: Spacing.sm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SkeletonLoader(width: 170, height: 14),
                  SizedBox(height: 6),
                  SkeletonLoader(width: 110, height: 11),
                ],
              ),
            ],
          ),
        ),
      );
}

class _GridSkeleton extends StatelessWidget {
  const _GridSkeleton();

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final margin = Spacing.screenMargin(width);
    final columns = width < 400 ? 2 : (width < 840 ? 3 : 5);
    final cardWidth =
        (width - margin * 2 - Spacing.sm * (columns - 1)) / columns;

    return GridView.builder(
      padding: EdgeInsets.all(margin),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: Spacing.md,
        crossAxisSpacing: Spacing.sm,
        mainAxisExtent: AlbumCard.heightFor(context, cardWidth),
      ),
      itemCount: 9,
      itemBuilder: (context, i) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonLoader(
            width: cardWidth,
            height: cardWidth,
            borderRadius: Radii.gridArtR,
          ),
          const SizedBox(height: 8),
          const SkeletonLoader(width: 90, height: 12),
          const SizedBox(height: 5),
          const SkeletonLoader(width: 60, height: 10),
        ],
      ),
    );
  }
}

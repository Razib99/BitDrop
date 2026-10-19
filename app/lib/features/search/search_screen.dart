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

import '../../theme/tokens.dart';
import '../../widgets/common.dart';
import '../../widgets/rows.dart';

/// Instant search, grouped, with format-aware queries.
///
/// Typing `24/192`, `flac` or `hi-res` filters by format — the index knows the
/// technical fields, so the search box does too.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  late final TextEditingController _controller =
      TextEditingController(text: ref.read(searchQueryProvider));
  final _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String>(searchQueryProvider, (previous, next) {
      if (_controller.text != next) {
        _controller.text = next;
        _controller.selection = TextSelection.collapsed(offset: next.length);
      }
    });

    final query = ref.watch(searchQueryProvider);
    final filters = ref.watch(searchFiltersProvider);
    final results = ref.watch(searchResultsProvider);
    final offline = ref.watch(currentScenarioProvider).offline;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              Spacing.md, Spacing.xs, Spacing.md, Spacing.xs),
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            autofocus: false,
            textInputAction: TextInputAction.search,
            onChanged: (v) => ref.read(searchQueryProvider.notifier).state = v,
            onSubmitted: (v) {
              ref.read(searchQueryProvider.notifier).state = v;
              _focus.unfocus();
              if (v.trim().isNotEmpty) {
                recordRecentSearch(ref, v);
              }
            },
            decoration: InputDecoration(
              hintText: 'Tracks, albums, artists, folders',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: context.l10n.actionClear,
                      onPressed: () {
                        _controller.clear();
                        ref.read(searchQueryProvider.notifier).state = '';
                      },
                    ),
            ),
          ),
        ),
        FilterChipRow(
          children: [
            BitChip(
              label: 'Hi-Res',
              selected: filters.quality == QualityFilter.hiRes,
              onTap: () => _setQuality(QualityFilter.hiRes),
            ),
            BitChip(
              label: 'CD',
              selected: filters.quality == QualityFilter.cdQuality,
              onTap: () => _setQuality(QualityFilter.cdQuality),
            ),
            for (final codec in [Codec.flac, Codec.alac, Codec.wav])
              BitChip(
                label: codec.label,
                mono: true,
                selected: filters.codecs.contains(codec),
                onTap: () {
                  final next = {...filters.codecs};
                  next.contains(codec) ? next.remove(codec) : next.add(codec);
                  ref.read(searchFiltersProvider.notifier).state =
                      filters.copyWith(codecs: next);
                },
              ),
            BitChip(
              label: 'Offline only',
              icon: Icons.push_pin,
              selected: filters.offlineOnly,
              onTap: () => ref.read(searchFiltersProvider.notifier).state =
                  filters.copyWith(offlineOnly: !filters.offlineOnly),
            ),
          ],
        ),
        if (offline)
          const StatusBanner(
            kind: BannerKind.info,
            message: 'Offline — searching only music that is on this device.',
          ),
        const SizedBox(height: Spacing.xs),
        Expanded(
          child: query.trim().isEmpty
              ? const _RecentAndTips()
              : results.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => EmptyState(
                    icon: Icons.error_outline,
                    title: 'Search failed',
                    message: '$e',
                  ),
                  data: (r) => r.isEmpty
                      ? EmptyState(
                          icon: Icons.search_off,
                          title: 'No results for "$query"',
                          message: 'Check the spelling, or search by format.',
                          hints: const ['24/192', 'ALAC', 'hi-res', 'flac'],
                        )
                      : _Results(results: r, query: query),
                ),
        ),
      ],
    );
  }

  void _setQuality(QualityFilter q) {
    final filters = ref.read(searchFiltersProvider);
    ref.read(searchFiltersProvider.notifier).state = filters.copyWith(
      quality: filters.quality == q ? QualityFilter.any : q,
    );
  }
}

class _RecentAndTips extends ConsumerWidget {
  const _RecentAndTips();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recents = ref.watch(recentSearchesProvider).valueOrNull ?? const [];
    return ListView(
      children: [
        if (recents.isNotEmpty) ...[
          SectionHeader(
            title: 'Recent searches',
            actionLabel: 'Clear',
            onAction: () => clearRecentSearches(ref),
          ),
          for (final r in recents)
            ListTile(
              dense: true,
              leading: const Icon(Icons.history, size: 20),
              title: Text(r),
              trailing: IconButton(
                icon: const Icon(Icons.close, size: 16),
                tooltip: 'Remove',
                onPressed: () => removeRecentSearch(ref, r),
              ),
              onTap: () {
                ref.read(searchQueryProvider.notifier).state = r;
                recordRecentSearch(ref, r);
              },
            ),
        ],
        const SectionHeader(
          title: 'Search by format',
          subtitle: 'The index knows bit depth and sample rate',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
          child: Wrap(
            spacing: Spacing.xs,
            runSpacing: Spacing.xs,
            children: [
              for (final hint in [
                '24/192',
                '24/96',
                '16/44.1',
                'flac',
                'alac',
                'wav',
                'hi-res'
              ])
                BitChip(
                  label: hint,
                  mono: true,
                  onTap: () =>
                      ref.read(searchQueryProvider.notifier).state = hint,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Results extends ConsumerWidget {
  const _Results({required this.results, required this.query});

  final SearchResults results;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsValueProvider);

    return ListView(
      padding: const EdgeInsets.only(bottom: Spacing.xxl),
      children: [
        if (results.topResult != null) ...[
          const SectionHeader(title: 'Top result'),
          _topResultTile(context, ref, settings.formatBadges),
        ],
        if (results.tracks.isNotEmpty) ...[
          const SectionHeader(title: 'Tracks'),
          for (var i = 0; i < results.tracks.length; i++)
            TrackRow(
              track: results.tracks[i],
              badgeVisibility: settings.formatBadges,
              onTap: () {
                if (query.trim().isNotEmpty) recordRecentSearch(ref, query);
                sendCommand(
                  ref,
                  PlayContext(
                    contextId: 'search',
                    trackIds: results.tracks.map((t) => t.id).toList(),
                    startIndex: i,
                    contextLabel: 'Search · $query',
                  ),
                );
              },
              onPlayNext: () =>
                  sendCommand(ref, PlayNext([results.tracks[i].id])),
              onAddToQueue: () =>
                  sendCommand(ref, Enqueue([results.tracks[i].id])),
              onToggleFavorite: () => sendCommand(
                ref,
                SetFavorite(
                  trackId: results.tracks[i].id,
                  favorite: !results.tracks[i].favorite,
                ),
              ),
              onDownload: () => sendCommand(
                ref,
                results.tracks[i].availability == Availability.pinned ||
                        results.tracks[i].availability == Availability.cached
                    ? Unpin(id: results.tracks[i].id, kind: 'track')
                    : Pin(id: results.tracks[i].id, kind: 'track'),
              ),
            ),
        ],
        if (results.albums.isNotEmpty) ...[
          const SectionHeader(title: 'Albums'),
          for (final a in results.albums)
            AlbumRow(
              album: a,
              badgeVisibility: settings.formatBadges,
              onTap: () {
                if (query.trim().isNotEmpty) recordRecentSearch(ref, query);
                context.push(Routes.album(a.id));
              },
            ),
        ],
        if (results.artists.isNotEmpty) ...[
          const SectionHeader(title: 'Artists'),
          for (final a in results.artists)
            ArtistTile(
              artist: a,
              onTap: () {
                if (query.trim().isNotEmpty) recordRecentSearch(ref, query);
                context.push(Routes.artist(a.id));
              },
            ),
        ],
        if (results.folders.isNotEmpty) ...[
          const SectionHeader(title: 'Folders'),
          for (final f in results.folders) FolderRow(entry: f),
        ],
      ],
    );
  }

  Widget _topResultTile(
    BuildContext context,
    WidgetRef ref,
    BadgeVisibility badges,
  ) {
    final top = results.topResult;
    return switch (top) {
      final Album a => AlbumRow(
          album: a,
          badgeVisibility: badges,
          onTap: () {
            if (query.trim().isNotEmpty) recordRecentSearch(ref, query);
            context.push(Routes.album(a.id));
          },
        ),
      final Artist a => ArtistTile(
          artist: a,
          onTap: () {
            if (query.trim().isNotEmpty) recordRecentSearch(ref, query);
            context.push(Routes.artist(a.id));
          },
        ),
      final Track t => TrackRow(
          track: t,
          badgeVisibility: badges,
          onTap: () {
            if (query.trim().isNotEmpty) recordRecentSearch(ref, query);
            sendCommand(
              ref,
              PlayContext(
                contextId: 'search',
                trackIds: [t.id],
                contextLabel: 'Search · $query',
              ),
            );
          },
        ),
      _ => const SizedBox.shrink(),
    };
  }
}

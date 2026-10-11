import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core_api/enums.dart';
import '../../core_api/queries.dart';
import '../../l10n/l10n.dart';
import '../../providers/core_providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/common.dart';

Future<void> showFilterSheet(BuildContext context) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const LibraryFilterSheet(),
    );

/// Everything that changes what the library shows, in one sheet.
///
/// Layout, sort and filters used to be three separate toolbar icons, two of
/// which appeared and vanished depending on the tab — so the toolbar changed
/// shape as you moved around and the controls were still three taps apart.
/// They are one question ("what am I looking at?") and belong in one place;
/// the sections that do not apply to the current tab are simply absent.
Future<void> showViewSheet(BuildContext context, LibraryTab tab) =>
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ViewSheet(tab: tab),
    );

class _ViewSheet extends ConsumerWidget {
  const _ViewSheet({required this.tab});

  final LibraryTab tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grid = ref.watch(libraryGridViewProvider);
    final sort = ref.watch(albumSortProvider);
    final desc = ref.watch(albumSortDescProvider);
    final filters = ref.watch(libraryFiltersProvider);
    final notifier = ref.read(libraryFiltersProvider.notifier);

    final showsLayout = tab == LibraryTab.albums;
    final showsSort = tab == LibraryTab.albums || tab == LibraryTab.tracks;

    return BottomSheetScaffold(
      title: 'View',
      subtitle: filters.isActive
          ? '${filters.activeCount} filter${filters.activeCount == 1 ? '' : 's'} active'
          : 'Showing everything',
      actions: [
        if (filters.isActive)
          TextButton(
            onPressed: () => notifier.state = const LibraryFilters(),
            child: Text(context.l10n.actionClear),
          ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showsLayout) ...[
            const SectionHeader(title: 'Layout'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
              child: Wrap(
                spacing: Spacing.xs,
                children: [
                  BitChip(
                    label: 'List',
                    selected: !grid,
                    onTap: () => ref
                        .read(libraryGridViewProvider.notifier)
                        .state = false,
                  ),
                  BitChip(
                    label: 'Grid',
                    selected: grid,
                    onTap: () =>
                        ref.read(libraryGridViewProvider.notifier).state = true,
                  ),
                ],
              ),
            ),
          ],
          if (showsSort) ...[
            const SectionHeader(title: 'Sort'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
              child: Wrap(
                spacing: Spacing.xs,
                runSpacing: Spacing.xs,
                children: [
                  for (final s in AlbumSort.values)
                    BitChip(
                      label: switch (s) {
                        AlbumSort.title => 'Title',
                        AlbumSort.artist => 'Artist',
                        AlbumSort.year => 'Year',
                        AlbumSort.recentlyAdded => 'Recently added',
                        AlbumSort.sampleRate => 'Sample rate',
                        AlbumSort.bitDepth => 'Bit depth',
                        AlbumSort.size => 'Size',
                        AlbumSort.duration => 'Duration',
                      },
                      selected: sort == s,
                      onTap: () =>
                          ref.read(albumSortProvider.notifier).state = s,
                    ),
                ],
              ),
            ),
            SwitchListTile(
              value: desc,
              onChanged: (v) =>
                  ref.read(albumSortDescProvider.notifier).state = v,
              title: const Text('Descending'),
              dense: true,
            ),
          ],
          const _FilterControls(),
        ],
      ),
    );
  }
}

/// Format, quality and availability filters.
///
/// "Show unsupported files" defaults to on: an APE file the engine cannot play
/// is still part of the user's library, and hiding it silently would be a lie
/// about what is in their Drive.
class LibraryFilterSheet extends ConsumerWidget {
  const LibraryFilterSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(libraryFiltersProvider);
    final notifier = ref.read(libraryFiltersProvider.notifier);

    return BottomSheetScaffold(
      title: 'Filter',
      subtitle: filters.isActive
          ? '${filters.activeCount} active'
          : 'Showing everything',
      actions: [
        if (filters.isActive)
          TextButton(
            onPressed: () => notifier.state = const LibraryFilters(),
            child: Text(context.l10n.actionClear),
          ),
      ],
      child: const _FilterControls(),
    );
  }
}

/// The format, quality and availability controls on their own, so the View
/// sheet can show them under its other sections.
class _FilterControls extends ConsumerWidget {
  const _FilterControls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(libraryFiltersProvider);
    final genres = ref.watch(genresProvider).valueOrNull ?? const [];
    final notifier = ref.read(libraryFiltersProvider.notifier);

    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'Format'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            child: Wrap(
              spacing: Spacing.xs,
              runSpacing: Spacing.xs,
              children: [
                for (final codec in [
                  Codec.flac,
                  Codec.alac,
                  Codec.wav,
                  Codec.aiff,
                  Codec.mp3,
                  Codec.aac,
                ])
                  BitChip(
                    label: codec.label,
                    mono: true,
                    selected: filters.codecs.contains(codec),
                    onTap: () {
                      final next = {...filters.codecs};
                      next.contains(codec)
                          ? next.remove(codec)
                          : next.add(codec);
                      notifier.state = filters.copyWith(codecs: next);
                    },
                  ),
              ],
            ),
          ),
          const SectionHeader(title: 'Quality'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            child: Wrap(
              spacing: Spacing.xs,
              runSpacing: Spacing.xs,
              children: [
                for (final q in QualityFilter.values)
                  BitChip(
                    label: switch (q) {
                      QualityFilter.any => 'Any',
                      QualityFilter.hiRes => 'Hi-Res (24-bit or >48 kHz)',
                      QualityFilter.cdQuality => 'CD (16/44.1)',
                      QualityFilter.lossy => 'Lossy',
                    },
                    selected: filters.quality == q,
                    onTap: () => notifier.state = filters.copyWith(quality: q),
                  ),
              ],
            ),
          ),
          const SectionHeader(title: 'Availability'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            child: Wrap(
              spacing: Spacing.xs,
              runSpacing: Spacing.xs,
              children: [
                for (final a in AvailabilityFilter.values)
                  BitChip(
                    label: switch (a) {
                      AvailabilityFilter.any => 'Any',
                      AvailabilityFilter.offline => 'Pinned offline',
                      AvailabilityFilter.cached => 'On device',
                      AvailabilityFilter.cloudOnly => 'Cloud only',
                    },
                    icon: switch (a) {
                      AvailabilityFilter.offline => Icons.push_pin,
                      AvailabilityFilter.cached => Icons.download_done,
                      AvailabilityFilter.cloudOnly => Icons.cloud_outlined,
                      _ => null,
                    },
                    selected: filters.availability == a,
                    onTap: () =>
                        notifier.state = filters.copyWith(availability: a),
                  ),
              ],
            ),
          ),
          if (genres.isNotEmpty) ...[
            const SectionHeader(title: 'Genre'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
              child: Wrap(
                spacing: Spacing.xs,
                runSpacing: Spacing.xs,
                children: [
                  BitChip(
                    label: 'Any',
                    selected: filters.genre == null,
                    onTap: () =>
                        notifier.state = filters.copyWith(clearGenre: true),
                  ),
                  for (final g in genres)
                    BitChip(
                      label: g,
                      selected: filters.genre == g,
                      onTap: () => notifier.state = filters.copyWith(genre: g),
                    ),
                ],
              ),
            ),
          ],
          SwitchListTile(
            value: filters.showUnsupported,
            onChanged: (v) =>
                notifier.state = filters.copyWith(showUnsupported: v),
            title: const Text('Show unsupported files'),
            subtitle: const Text(
              'APE, WavPack, DSF and Opus appear greyed out. BitDrop cannot '
              'play them yet, but they are still in your Drive.',
            ),
          ),
          const SizedBox(height: Spacing.md),
        ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core_api/commands.dart';
import '../../core_api/models.dart';
import '../../providers/core_providers.dart';
import '../../src/rust/api/cloud_library.dart' as rust_cache;
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../../widgets/common.dart';
import '../../widgets/rows.dart';

/// Local & Cloud hierarchical folder browser with breadcrumb navigation.
///
/// Folders come first, then audio files. Non-audio files are not listed at
/// all — the scanner never indexes them.
class FolderBrowser extends ConsumerStatefulWidget {
  const FolderBrowser({super.key, this.rootId});

  final String? rootId;

  @override
  ConsumerState<FolderBrowser> createState() => _FolderBrowserState();
}

class _FolderBrowserState extends ConsumerState<FolderBrowser> {
  late String? _folderId = widget.rootId;
  String _sourceFilter = 'all'; // 'all', 'local', 'cloud'

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(folderProvider(_folderId));
    final settings = ref.watch(settingsValueProvider);

    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(
        icon: Icons.folder_off_outlined,
        title: 'Could not open that folder',
        message: '$e',
      ),
      data: (listing) {
        final isRoot = _folderId == null;

        // Source detection at root level
        final hasDrive = isRoot &&
            listing.entries.any((e) => e.name.toLowerCase().contains('drive'));
        final hasLocal = isRoot &&
            listing.entries.any((e) => !e.name.toLowerCase().contains('drive'));
        final showFilterChips = isRoot && hasDrive && hasLocal;

        // Apply source filtering if at root
        final filteredEntries = isRoot
            ? listing.entries.where((e) {
                if (_sourceFilter == 'cloud') {
                  return e.name.toLowerCase().contains('drive');
                } else if (_sourceFilter == 'local') {
                  return !e.name.toLowerCase().contains('drive');
                }
                return true;
              }).toList()
            : listing.entries;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Breadcrumb(
              listing: listing,
              onNavigate: (id) => setState(() => _folderId = id),
            ),
            if (showFilterChips)
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.md, vertical: Spacing.xs),
                child: Row(
                  children: [
                    FilterChip(
                      label: const Text('All'),
                      selected: _sourceFilter == 'all',
                      onSelected: (_) => setState(() => _sourceFilter = 'all'),
                    ),
                    const SizedBox(width: Spacing.xs),
                    FilterChip(
                      avatar: const Icon(Icons.phone_android, size: 16),
                      label: const Text('This Device'),
                      selected: _sourceFilter == 'local',
                      onSelected: (_) =>
                          setState(() => _sourceFilter = 'local'),
                    ),
                    const SizedBox(width: Spacing.xs),
                    FilterChip(
                      avatar: const Icon(Icons.cloud_outlined, size: 16),
                      label: const Text('Google Drive'),
                      selected: _sourceFilter == 'cloud',
                      onSelected: (_) =>
                          setState(() => _sourceFilter = 'cloud'),
                    ),
                  ],
                ),
              ),
            if (!isRoot)
              _FolderHeader(
                listing: listing,
                folderId: _folderId!,
                onPlay: () => _playFolder(listing, null, shuffle: false),
                onShuffle: () => _playFolder(listing, null, shuffle: true),
                onEnqueue: () => _enqueueFolder(listing, _folderId!),
                onPin: () =>
                    sendCommand(ref, Pin(id: _folderId!, kind: 'folder')),
              ),
            Expanded(
              child: filteredEntries.isEmpty && !isRoot
                  ? const EmptyState(
                      icon: Icons.folder_open,
                      title: 'This folder is empty',
                      message: 'No audio files here.',
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: Spacing.xxl),
                      itemCount:
                          filteredEntries.length + (isRoot ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (isRoot && i == 0) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: Spacing.sm, vertical: 2),
                            child: ListTile(
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                              leading: Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: context.c.accent.withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(Icons.favorite,
                                    color: context.c.accent, size: 22),
                              ),
                              title: const Text('Favourites',
                                  style:
                                      TextStyle(fontWeight: FontWeight.w600)),
                              subtitle: const Text(
                                  'Your favourited tracks across all folders'),
                              trailing:
                                  const Icon(Icons.chevron_right, size: 20),
                              onTap: () => ref
                                  .read(libraryTabProvider.notifier)
                                  .state = LibraryTab.favorites,
                            ),
                          );
                        }
                        final entryIndex = isRoot ? i - 1 : i;
                        final e = filteredEntries[entryIndex];
                        return FolderRow(
                          entry: e,
                          badgeVisibility: settings.formatBadges,
                          onTap: e.isDirectory
                              ? () => setState(() => _folderId = e.id)
                              : () => _playFile(listing, entryIndex),
                          onPlay: e.isDirectory
                              ? () => _playFolder(listing, e, shuffle: false)
                              : null,
                          onShuffle: e.isDirectory
                              ? () => _playFolder(listing, e, shuffle: true)
                              : null,
                          onAddToQueue: e.isDirectory
                              ? () => _enqueueFolder(listing, e.id)
                              : null,
                          onPin: e.isDirectory
                              ? () => sendCommand(
                                  ref, Pin(id: e.id, kind: 'folder'))
                              : null,
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  void _playFile(FolderListing listing, int index) {
    final files = listing.entries
        .where((e) => !e.isDirectory && e.track != null)
        .toList();
    final target = listing.entries[index].track;
    if (target == null) return;
    sendCommand(
      ref,
      PlayContext(
        contextId: listing.folderId ?? 'root',
        trackIds: files.map((f) => f.track!.id).toList(),
        startIndex: files.indexWhere((f) => f.track!.id == target.id),
        contextLabel:
            'Folder · ${listing.breadcrumb.isEmpty ? 'Folders' : listing.breadcrumb.last.name}',
      ),
    );
  }

  /// Recursive play: the core resolves the folder's tracks.
  void _playFolder(FolderListing listing, FolderEntry? folder,
      {bool shuffle = false}) {
    final targetId = folder?.id ?? listing.folderId ?? 'root';
    final targetName = folder?.name ??
        (listing.breadcrumb.isNotEmpty
            ? listing.breadcrumb.last.name
            : 'Folder');
    sendCommand(
      ref,
      PlayContext(
        contextId: targetId,
        trackIds: const [],
        shuffle: shuffle,
        contextLabel: 'Folder · $targetName',
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            '${shuffle ? "Shuffling" : "Playing"} "$targetName" and everything inside.'),
      ),
    );
  }

  Future<void> _enqueueFolder(FolderListing listing, String folderId) async {
    List<String> trackIds = [];
    try {
      final rows = await rust_cache.cloudLibraryGetTracksInFolder(
        folderPath: folderId,
        recursive: true,
      );
      trackIds = rows.map((r) => r.fileId).toList();
    } catch (_) {
      trackIds = listing.entries
          .where((e) => !e.isDirectory && e.track != null)
          .map((e) => e.track!.id)
          .toList();
    }
    if (trackIds.isNotEmpty) {
      sendCommand(ref, Enqueue(trackIds));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Added ${trackIds.length} track${trackIds.length == 1 ? '' : 's'} to queue.'),
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No tracks found to queue.')),
        );
      }
    }
  }
}

class _FolderHeader extends StatelessWidget {
  const _FolderHeader({
    required this.listing,
    required this.folderId,
    required this.onPlay,
    required this.onShuffle,
    required this.onEnqueue,
    required this.onPin,
  });

  final FolderListing listing;
  final String folderId;
  final VoidCallback onPlay;
  final VoidCallback onShuffle;
  final VoidCallback onEnqueue;
  final VoidCallback onPin;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final folderName = listing.breadcrumb.isNotEmpty
        ? listing.breadcrumb.last.name
        : folderId;

    final directFiles =
        listing.entries.where((e) => !e.isDirectory).toList();
    final directFolders =
        listing.entries.where((e) => e.isDirectory).toList();
    final totalBytes =
        listing.entries.fold<int>(0, (sum, e) => sum + e.sizeBytes);

    final statsList = <String>[];
    if (directFiles.isNotEmpty) {
      statsList
          .add('${directFiles.length} track${directFiles.length == 1 ? '' : 's'}');
    }
    if (directFolders.isNotEmpty) {
      statsList.add(
          '${directFolders.length} folder${directFolders.length == 1 ? '' : 's'}');
    }
    if (totalBytes > 0) {
      statsList.add(Fmt.bytes(totalBytes));
    }
    final statsString =
        statsList.isEmpty ? 'Empty folder' : statsList.join(' · ');

    return Container(
      margin: const EdgeInsets.fromLTRB(
          Spacing.md, Spacing.xs, Spacing.md, Spacing.sm),
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.outline.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: c.accent.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.folder_outlined, color: c.accent, size: 24),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      folderName,
                      style: context.t.title.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      statsString,
                      style:
                          context.t.bodySmall.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.push_pin_outlined, size: 20),
                tooltip: 'Pin folder for offline',
                color: c.textSecondary,
                onPressed: onPin,
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onPlay,
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('Play All'),
                ),
              ),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onShuffle,
                  icon: const Icon(Icons.shuffle, size: 18),
                  label: const Text('Shuffle'),
                ),
              ),
              const SizedBox(width: Spacing.xs),
              Tooltip(
                message: 'Add to queue',
                child: IconButton.outlined(
                  onPressed: onEnqueue,
                  icon: const Icon(Icons.queue_music, size: 18),
                  color: c.textPrimary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.listing, required this.onNavigate});

  final FolderListing listing;
  final ValueChanged<String?> onNavigate;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SizedBox(
      height: 42,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
        child: Row(
          children: [
            _Crumb(
              label: 'Folders',
              icon: Icons.folder_copy_outlined,
              onTap: () => onNavigate(null),
              isLast: listing.breadcrumb.isEmpty,
            ),
            for (final crumb in listing.breadcrumb) ...[
              Icon(Icons.chevron_right, size: 16, color: c.textTertiary),
              _Crumb(
                label: crumb.name,
                onTap: () => onNavigate(crumb.id),
                isLast: crumb == listing.breadcrumb.last,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Crumb extends StatelessWidget {
  const _Crumb({
    required this.label,
    required this.onTap,
    required this.isLast,
    this.icon,
  });

  final String label;
  final VoidCallback onTap;
  final bool isLast;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: isLast ? null : onTap,
        borderRadius: Radii.badgeR,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: Spacing.xxs, vertical: Spacing.xs),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 14,
                  color: isLast ? context.c.textPrimary : context.c.accent,
                ),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: context.t.label.copyWith(
                  fontWeight: isLast ? FontWeight.w600 : FontWeight.normal,
                  color: isLast ? context.c.textPrimary : context.c.accent,
                ),
              ),
            ],
          ),
        ),
      );
}

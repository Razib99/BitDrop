import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core_api/commands.dart';
import '../../core_api/models.dart';
import '../../providers/core_providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/common.dart';
import '../../widgets/rows.dart';

/// Drive folder browser with a breadcrumb trail.
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
      data: (listing) => Column(
        children: [
          _Breadcrumb(
            listing: listing,
            onNavigate: (id) => setState(() => _folderId = id),
          ),
          Expanded(
            child: listing.entries.isEmpty
                ? const EmptyState(
                    icon: Icons.folder_open,
                    title: 'This folder is empty',
                    message: 'No audio files here.',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: Spacing.xxl),
                    itemCount: listing.entries.length,
                    itemBuilder: (context, i) {
                      final e = listing.entries[i];
                      return FolderRow(
                        entry: e,
                        badgeVisibility: settings.formatBadges,
                        onTap: e.isDirectory
                            ? () => setState(() => _folderId = e.id)
                            : () => _playFile(listing, i),
                        onPlay: e.isDirectory
                            ? () => _playFolder(listing, e)
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
      ),
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
        contextLabel: 'Folder · ${listing.breadcrumb.isEmpty ? 'Drive' : listing.breadcrumb.last.name}',
      ),
    );
  }

  /// Recursive play: the core resolves the folder's tracks.
  void _playFolder(FolderListing listing, FolderEntry folder) {
    sendCommand(
      ref,
      PlayContext(
        contextId: folder.id,
        trackIds: const [],
        contextLabel: 'Folder · ${folder.name}',
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Playing "${folder.name}" and everything inside.')),
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
      height: 40,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
        child: Row(
          children: [
            _Crumb(
              label: 'Drive',
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
  });

  final String label;
  final VoidCallback onTap;
  final bool isLast;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: isLast ? null : onTap,
        borderRadius: Radii.badgeR,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: Spacing.xxs, vertical: Spacing.xs),
          child: Text(
            label,
            style: context.t.label.copyWith(
              color: isLast ? context.c.textPrimary : context.c.accent,
            ),
          ),
        ),
      );
}

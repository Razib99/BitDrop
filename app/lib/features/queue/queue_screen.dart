import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core_api/commands.dart';
import '../../core_api/enums.dart';
import '../../core_api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/core_providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../../widgets/artwork.dart';
import '../../widgets/common.dart';
import '../../widgets/indicators.dart';

/// The queue, with gapless honesty.
///
/// Between consecutive rows BitDrop states what will happen at the boundary:
/// "Preloaded for gapless", "Will stream", or a short-gap marker naming the
/// sample-rate change that causes it.
class QueueScreen extends ConsumerWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(queueProvider).valueOrNull ?? QueueState.empty;
    final l = context.l10n;

    return Scaffold(
      appBar: AppBar(
        title: Text(l.navQueue),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (v) => _handle(context, ref, v),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'save', child: Text(l.actionSaveAsPlaylist)),
              PopupMenuItem(
                  value: 'shuffle', child: Text(l.actionShuffleRemaining)),
              PopupMenuItem(value: 'clear', child: Text(l.actionClear)),
            ],
          ),
        ],
      ),
      body: queue.items.isEmpty
          ? const EmptyState(
              icon: Icons.queue_music,
              title: 'The queue is empty',
              message: 'Play an album or a playlist and it will show up here.',
            )
          : CustomScrollView(
              slivers: [
                if (queue.current != null)
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SectionHeader(title: 'Now playing'),
                        _QueueRow(
                          item: queue.current!,
                          isCurrent: true,
                          index: queue.currentIndex,
                        ),
                        if (queue.upNext.isNotEmpty)
                          SectionHeader(
                            title: 'Up next',
                            subtitle: queue.contextLabel.isEmpty
                                ? null
                                : 'From ${queue.contextLabel}',
                          ),
                      ],
                    ),
                  ),
                SliverReorderableList(
                  itemCount: queue.upNext.length,
                  onReorder: (oldIndex, newIndex) {
                    final base = queue.currentIndex + 1;
                    sendCommand(
                      ref,
                      Reorder(
                        oldIndex: base + oldIndex,
                        newIndex: base +
                            (newIndex > oldIndex ? newIndex - 1 : newIndex),
                      ),
                    );
                  },
                  itemBuilder: (context, i) {
                    final item = queue.upNext[i];
                    return _DismissibleQueueRow(
                      key: ValueKey(item.id),
                      item: item,
                      index: i,
                      absoluteIndex: queue.currentIndex + 1 + i,
                    );
                  },
                ),
                if (queue.history.isNotEmpty)
                  SliverToBoxAdapter(child: _History(items: queue.history)),
                const SliverToBoxAdapter(child: SizedBox(height: Spacing.xxl)),
              ],
            ),
    );
  }

  void _handle(BuildContext context, WidgetRef ref, String value) {
    switch (value) {
      case 'save':
        _promptPlaylistName(context, ref);
      case 'shuffle':
        sendCommand(ref, const ShuffleRemaining());
      case 'clear':
        sendCommand(ref, const ClearQueue());
    }
  }

  Future<void> _promptPlaylistName(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: 'New playlist');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save queue as playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Playlist name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(context.l10n.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: Text(context.l10n.actionSave),
          ),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      sendCommand(ref, SaveQueueAsPlaylist(name.trim()));
    }
  }
}

class _DismissibleQueueRow extends ConsumerWidget {
  const _DismissibleQueueRow({
    super.key,
    required this.item,
    required this.index,
    required this.absoluteIndex,
  });

  final QueueItem item;
  final int index;
  final int absoluteIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    return Dismissible(
      key: ValueKey('dismiss-${item.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: c.error.withOpacity(0.18),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
        child: Icon(Icons.delete_outline, color: c.error),
      ),
      onDismissed: (_) {
        sendCommand(ref, RemoveFromQueue(item.id));
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('Removed "${item.track.title}"'),
              action: SnackBarAction(
                label: context.l10n.actionUndo,
                // Re-queueing at the same position restores the order.
                onPressed: () => sendCommand(ref, PlayNext([item.track.id])),
              ),
            ),
          );
      },
      child: _QueueRow(item: item, index: absoluteIndex, reorderIndex: index),
    );
  }
}

class _QueueRow extends ConsumerWidget {
  const _QueueRow({
    required this.item,
    required this.index,
    this.isCurrent = false,
    this.reorderIndex,
  });

  final QueueItem item;
  final int index;
  final bool isCurrent;
  final int? reorderIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final track = item.track;
    final blocked = track.availability == Availability.unsupported ||
        track.availability == Availability.missing;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Boundary marker: this is where a gap would land, and why.
        if (item.gapReason != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
                Spacing.md, Spacing.xxs, Spacing.md, Spacing.xxs),
            child: Row(
              children: [
                Icon(Icons.linear_scale, size: 13, color: c.tierResampled),
                const SizedBox(width: Spacing.xxs),
                Text(
                  'Short gap · ${item.gapReason}',
                  style: context.t.monoLabel.copyWith(color: c.tierResampled),
                ),
              ],
            ),
          ),
        Material(
          color: isCurrent ? c.surface2 : Colors.transparent,
          child: InkWell(
            onTap: blocked
                ? null
                : () {
                    final queue =
                        ref.read(queueProvider).valueOrNull ?? QueueState.empty;
                    final ids = queue.items.map((i) => i.track.id).toList();
                    sendCommand(
                      ref,
                      PlayContext(
                        contextId: 'queue',
                        trackIds: ids,
                        startIndex: index,
                        contextLabel: queue.contextLabel,
                      ),
                    );
                  },
            child: Container(
              constraints: const BoxConstraints(minHeight: 64),
              padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.md, vertical: Spacing.xs),
              child: Row(
                children: [
                  if (reorderIndex != null)
                    ReorderableDragStartListener(
                      index: reorderIndex!,
                      child: Padding(
                        padding: const EdgeInsets.only(right: Spacing.xs),
                        child: Icon(Icons.drag_handle,
                            size: 20, color: c.textTertiary),
                      ),
                    ),
                  AlbumArtwork(
                    artwork: track.artwork,
                    size: Sizes.trackArt,
                    title: track.albumTitle,
                    dimmed: blocked,
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            if (isCurrent)
                              Padding(
                                padding: const EdgeInsets.only(right: 5),
                                child: Icon(Icons.equalizer,
                                    size: 15, color: c.accent),
                              ),
                            Flexible(
                              child: Text(
                                track.title,
                                style: context.t.body.copyWith(
                                  color: blocked
                                      ? c.textTertiary
                                      : (isCurrent ? c.accent : c.textPrimary),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          track.artist,
                          style: context.t.bodySmall
                              .copyWith(color: c.textSecondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        _Readiness(item: item),
                      ],
                    ),
                  ),
                  const SizedBox(width: Spacing.xs),
                  FormatBadge(format: track.format, compact: true),
                  const SizedBox(width: Spacing.xs),
                  Text(
                    Fmt.duration(track.durationMs),
                    style:
                        context.t.monoReadout.copyWith(color: c.textSecondary),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// What the engine will have ready when this row's turn comes.
class _Readiness extends StatelessWidget {
  const _Readiness({required this.item});

  final QueueItem item;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final track = item.track;

    final (IconData icon, String label, Color color) =
        switch (track.availability) {
      Availability.unsupported => (
          Icons.block,
          track.unsupportedReason ?? 'Will be skipped',
          c.textTertiary
        ),
      Availability.missing => (
          Icons.link_off,
          'Removed from Drive — will be skipped',
          c.error
        ),
      Availability.pinned => (Icons.push_pin, 'Ready offline', c.success),
      Availability.cached => (Icons.download_done, 'Ready offline', c.success),
      _ when item.preloadedForGapless => (
          Icons.bolt,
          'Preloaded for gapless',
          c.success
        ),
      Availability.partiallyCached => (
          Icons.downloading,
          'Start cached · ${track.cachedPercent}%',
          c.textSecondary
        ),
      _ => (Icons.cloud_outlined, 'Will stream', c.textSecondary),
    };

    return Row(
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            style: context.t.monoLabel.copyWith(color: color),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _History extends StatefulWidget {
  const _History({required this.items});

  final List<QueueItem> items;

  @override
  State<_History> createState() => _HistoryState();
}

class _HistoryState extends State<_History> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md, vertical: Spacing.sm),
            child: Row(
              children: [
                Icon(_open ? Icons.expand_less : Icons.expand_more,
                    size: 20, color: c.textSecondary),
                const SizedBox(width: Spacing.xs),
                Text('History', style: context.t.titleSmall),
                const SizedBox(width: Spacing.xs),
                Text('${widget.items.length}',
                    style:
                        context.t.monoLabel.copyWith(color: c.textSecondary)),
              ],
            ),
          ),
        ),
        if (_open)
          for (var i = 0; i < widget.items.length; i++)
            Opacity(
              opacity: 0.7,
              child: _QueueRow(item: widget.items[i], index: -1),
            ),
      ],
    );
  }
}

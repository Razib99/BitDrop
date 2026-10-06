import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core_api/commands.dart';
import '../../core_mock/catalog.dart';
import '../../l10n/l10n.dart';
import '../../providers/core_providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

/// Multi-select action bar, shown in place of the toolbar after a long-press.
class SelectionBar extends ConsumerWidget {
  const SelectionBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(selectionProvider);
    final l = context.l10n;

    return Container(
      color: context.c.surface2,
      padding: const EdgeInsets.symmetric(
          horizontal: Spacing.xs, vertical: Spacing.xxs),
      child: Row(
        children: [
          IconButton(
            tooltip: l.actionCancel,
            icon: const Icon(Icons.close),
            onPressed: () =>
                ref.read(selectionProvider.notifier).state = const {},
          ),
          Text('${selection.length} selected', style: context.t.titleSmall),
          const Spacer(),
          _Action(
            icon: Icons.play_arrow,
            tooltip: l.actionPlay,
            onTap: () => _play(ref, selection),
          ),
          _Action(
            icon: Icons.playlist_play,
            tooltip: l.actionPlayNext,
            onTap: () => _dispatch(ref, selection, playNext: true),
          ),
          _Action(
            icon: Icons.queue_music,
            tooltip: l.actionAddToQueue,
            onTap: () => _dispatch(ref, selection, playNext: false),
          ),
          _Action(
            icon: Icons.push_pin_outlined,
            tooltip: l.actionPinOffline,
            onTap: () {
              for (final id in selection) {
                sendCommand(
                  ref,
                  Pin(id: id, kind: id.startsWith('al-') ? 'album' : 'track'),
                );
              }
              ref.read(selectionProvider.notifier).state = const {};
            },
          ),
        ],
      ),
    );
  }

  /// Selection ids may be albums or tracks; albums expand to their tracks.
  List<String> _trackIds(Set<String> selection) {
    final ids = <String>[];
    for (final id in selection) {
      if (id.startsWith('al-')) {
        ids.addAll(
          (MockCatalog.tracksByAlbum[id] ?? const []).map((t) => t.id),
        );
      } else {
        ids.add(id);
      }
    }
    return ids;
  }

  void _play(WidgetRef ref, Set<String> selection) {
    final ids = _trackIds(selection);
    if (ids.isEmpty) return;
    sendCommand(
      ref,
      PlayContext(
        contextId: 'selection',
        trackIds: ids,
        contextLabel: '${selection.length} selected',
      ),
    );
    ref.read(selectionProvider.notifier).state = const {};
  }

  void _dispatch(WidgetRef ref, Set<String> selection,
      {required bool playNext}) {
    final ids = _trackIds(selection);
    if (ids.isEmpty) return;
    sendCommand(ref, playNext ? PlayNext(ids) : Enqueue(ids));
    ref.read(selectionProvider.notifier).state = const {};
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) =>
      IconButton(icon: Icon(icon), tooltip: tooltip, onPressed: onTap);
}

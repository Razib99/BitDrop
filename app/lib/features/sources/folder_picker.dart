import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/core_providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/common.dart';
import '../storage/google_drive_service.dart';

Future<void> showDriveFolderPicker(BuildContext context) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const DriveFolderPicker(),
    );

/// Browses the real Drive tree and picks which folders BitDrop indexes.
///
/// Choosing folders is not a nicety: walking an entire multi-terabyte Drive
/// takes a very long time and indexes a great deal that is not music. Only
/// folders are listed, since the point is to choose where to look.
class DriveFolderPicker extends ConsumerStatefulWidget {
  const DriveFolderPicker({super.key});

  @override
  ConsumerState<DriveFolderPicker> createState() => _DriveFolderPickerState();
}

class _DriveFolderPickerState extends ConsumerState<DriveFolderPicker> {
  /// Breadcrumb of the folders walked into. Empty means "My Drive".
  final List<DriveFolder> _trail = [];
  late Set<DriveFolder> _selected;

  List<DriveFolder> _children = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selected = {...ref.read(cloudLibraryProvider).currentFolders};
    _load();
  }

  String get _currentId => _trail.isEmpty ? 'root' : _trail.last.id;
  String get _currentPath =>
      _trail.isEmpty ? 'My Drive' : _trail.last.path;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final folders = await ref
          .read(driveServiceProvider)
          .listFolders(_currentId, parentPath: _currentPath);
      if (!mounted) return;
      setState(() {
        _children = folders;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _open(DriveFolder folder) {
    setState(() => _trail.add(folder));
    _load();
  }

  void _up([int? toIndex]) {
    setState(() {
      if (toIndex == null) {
        _trail.clear();
      } else {
        _trail.removeRange(toIndex + 1, _trail.length);
      }
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;

    return BottomSheetScaffold(
      title: 'Choose music folders',
      subtitle: _selected.isEmpty
          ? 'Nothing selected yet'
          : '${_selected.length} selected',
      actions: [
        TextButton(
          onPressed: _selected.isEmpty
              ? null
              : () async {
                  final library = ref.read(cloudLibraryProvider);
                  await library.setFolders(_selected.toList());
                  if (context.mounted) Navigator.of(context).pop();
                  // Rebuilding the index from scratch, because the previous
                  // contents may have come from folders no longer chosen.
                  unawaited(library.scan());
                },
          child: Text(context.l10n.actionDone),
        ),
      ],
      scrollable: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Breadcrumb(trail: _trail, onNavigate: _up),
          if (_selected.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
                children: [
                  for (final f in _selected)
                    Padding(
                      padding: const EdgeInsets.only(right: Spacing.xs),
                      child: BitChip(
                        label: f.name,
                        icon: Icons.close,
                        selected: true,
                        onTap: () => setState(() => _selected.remove(f)),
                      ),
                    ),
                ],
              ),
            ),
          Divider(height: 1, color: c.outline),
          Flexible(
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.all(Spacing.xxl),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : _error != null
                    ? EmptyState(
                        icon: Icons.error_outline,
                        title: 'Could not list folders',
                        message: _error,
                        actionLabel: context.l10n.actionRetry,
                        onAction: _load,
                      )
                    : _children.isEmpty
                        ? const EmptyState(
                            icon: Icons.folder_open,
                            title: 'No sub-folders here',
                            message:
                                'You can still select this folder from the '
                                'level above.',
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            itemCount: _children.length,
                            itemBuilder: (context, i) {
                              final f = _children[i];
                              final picked = _selected.contains(f);
                              return ListTile(
                                leading: Icon(
                                  picked
                                      ? Icons.folder
                                      : Icons.folder_outlined,
                                  color: picked ? c.accent : c.textSecondary,
                                ),
                                title: Text(f.name),
                                subtitle: picked
                                    ? const Text('Will be indexed, including '
                                        'sub-folders')
                                    : null,
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Checkbox(
                                      value: picked,
                                      onChanged: (v) => setState(() {
                                        v == true
                                            ? _selected.add(f)
                                            : _selected.remove(f);
                                      }),
                                    ),
                                    IconButton(
                                      tooltip: 'Open ${f.name}',
                                      icon: const Icon(Icons.chevron_right),
                                      onPressed: () => _open(f),
                                    ),
                                  ],
                                ),
                                onTap: () => _open(f),
                              );
                            },
                          ),
          ),
          Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 16, color: c.textSecondary),
                const SizedBox(width: Spacing.xs),
                Expanded(
                  child: Text(
                    'Selecting a folder includes everything inside it. Fewer '
                    'folders means a faster scan and less of your daily Drive '
                    'request budget.',
                    style:
                        context.t.bodySmall.copyWith(color: c.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.trail, required this.onNavigate});

  final List<DriveFolder> trail;
  final void Function([int?]) onNavigate;

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
            InkWell(
              onTap: trail.isEmpty ? null : () => onNavigate(),
              borderRadius: Radii.badgeR,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.xxs, vertical: Spacing.xs),
                child: Text(
                  'My Drive',
                  style: context.t.label.copyWith(
                    color: trail.isEmpty ? c.textPrimary : c.accent,
                  ),
                ),
              ),
            ),
            for (var i = 0; i < trail.length; i++) ...[
              Icon(Icons.chevron_right, size: 16, color: c.textTertiary),
              InkWell(
                onTap: i == trail.length - 1 ? null : () => onNavigate(i),
                borderRadius: Radii.badgeR,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: Spacing.xxs, vertical: Spacing.xs),
                  child: Text(
                    trail[i].name,
                    style: context.t.label.copyWith(
                      color: i == trail.length - 1
                          ? c.textPrimary
                          : c.accent,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

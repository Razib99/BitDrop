import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core_api/commands.dart';
import '../../core_api/models.dart';
import '../../l10n/l10n.dart';
import '../../providers/core_providers.dart';
import '../../routing/routes.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/cards.dart';
import '../../widgets/common.dart';

/// Connected cloud accounts.
///
/// Only Google Drive is wired up; the others are marked "Coming later" rather
/// than hidden, so the roadmap is visible without being a promise.
class SourcesScreen extends ConsumerStatefulWidget {
  const SourcesScreen({super.key});

  @override
  ConsumerState<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends ConsumerState<SourcesScreen> {
  bool _advanced = false;

  @override
  Widget build(BuildContext context) {
    final sources = ref.watch(sourcesProvider).valueOrNull ?? const [];
    final l = context.l10n;

    return ListView(
      padding: const EdgeInsets.only(bottom: Spacing.xxl),
      children: [
        Padding(
          padding:
              const EdgeInsets.fromLTRB(Spacing.md, Spacing.xs, Spacing.xs, 0),
          child: Row(
            children: [
              Text(l.navSources, style: context.t.headline),
              const Spacer(),
              IconButton(
                tooltip: l.navSettings,
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => context.push(Routes.settings),
              ),
            ],
          ),
        ),
        if (sources.isEmpty)
          SizedBox(
            height: 420,
            child: EmptyState(
              icon: Icons.cloud_off,
              title: 'No sources connected',
              message: 'BitDrop plays from your own cloud storage. Nothing is '
                  'uploaded, and there is no BitDrop server in between.',
              actionLabel: 'Connect Google Drive',
              onAction: () => context.push(Routes.onboarding),
            ),
          )
        else
          for (final s in sources)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  Spacing.md, Spacing.xs, Spacing.md, 0),
              child: SourceCard(
                account: s,
                showAdvanced: _advanced,
                onToggleAdvanced: () => setState(() => _advanced = !_advanced),
                onRescan: () => sendCommand(ref, Rescan(sourceId: s.id)),
                onEditFolders: () => _showFolderPicker(context),
                onReconnect: s.status == SourceStatus.needsReconnect
                    ? () => sendCommand(ref, ReconnectSource(s.id))
                    : null,
                onRemove: () => _confirmRemove(context, s),
              ),
            ),
        const SectionHeader(title: 'Add a source'),
        const _ProviderTile(
          icon: Icons.add_to_drive,
          name: 'Google Drive',
          detail: 'Connected',
          available: true,
        ),
        const _ProviderTile(
          icon: Icons.cloud_outlined,
          name: 'S3-compatible',
          detail: 'Coming later',
          available: false,
        ),
        const _ProviderTile(
          icon: Icons.dns_outlined,
          name: 'WebDAV',
          detail: 'Coming later',
          available: false,
        ),
        const _ProviderTile(
          icon: Icons.library_music_outlined,
          name: 'OpenSubsonic / Navidrome',
          detail: 'Coming later',
          available: false,
        ),
        const SizedBox(height: Spacing.md),
        const _PrivacyNote(),
      ],
    );
  }

  Future<void> _confirmRemove(BuildContext context, SourceAccount s) async {
    final ok = await ConfirmDialog.show(
      context,
      title: 'Remove ${s.provider}?',
      message: 'Your library index and any cached music for this account are '
          'deleted from this device. Nothing in your Drive changes.',
      confirmLabel: context.l10n.actionRemove,
      destructive: true,
    );
    if (ok) sendCommand(ref, RemoveSource(s.id));
  }

  void _showFolderPicker(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const FolderPickerSheet(),
    );
  }
}

class _ProviderTile extends StatelessWidget {
  const _ProviderTile({
    required this.icon,
    required this.name,
    required this.detail,
    required this.available,
  });

  final IconData icon;
  final String name;
  final String detail;
  final bool available;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Opacity(
      opacity: available ? 1 : 0.55,
      child: ListTile(
        leading: Icon(icon, color: available ? c.accent : c.textTertiary),
        title: Text(name),
        subtitle: Text(detail),
        trailing: available
            ? const Icon(Icons.check_circle_outline)
            : Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: c.surface3,
                  borderRadius: Radii.badgeR,
                ),
                child: Text('Soon',
                    style:
                        context.t.monoLabel.copyWith(color: c.textSecondary)),
              ),
        enabled: available,
      ),
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: Spacing.md),
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: Radii.cardR,
        border: Border.all(color: c.outline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline, size: 18, color: c.success),
          const SizedBox(width: Spacing.xs),
          Expanded(
            child: Text(
              'BitDrop has no servers. Your music and your account stay '
              'between this phone and your cloud.',
              style: context.t.bodySmall.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Drive folder tree with checkboxes, used by onboarding and "Edit folders".
class FolderPickerSheet extends ConsumerStatefulWidget {
  const FolderPickerSheet({super.key, this.onDone});

  final VoidCallback? onDone;

  @override
  ConsumerState<FolderPickerSheet> createState() => _FolderPickerSheetState();
}

class _FolderPickerSheetState extends ConsumerState<FolderPickerSheet> {
  final _selected = <String>{'fo-hires', 'fo-lossless'};
  bool _entireDrive = false;

  static const _candidates = [
    (id: 'fo-hires', name: 'Music › Hi-Res', tracks: 184, size: '15.7 GB'),
    (id: 'fo-lossless', name: 'Music › Lossless', tracks: 96, size: '4.2 GB'),
    (id: 'fo-jazz', name: 'Music › Jazz', tracks: 48, size: '2.1 GB'),
    (id: 'fo-lossy', name: 'Music › Lossy', tracks: 220, size: '1.4 GB'),
    (id: 'fo-archive', name: 'Music › Archive', tracks: 61, size: '3.8 GB'),
    (id: 'fo-comp', name: 'Music › Compilations', tracks: 34, size: '1.9 GB'),
  ];

  @override
  Widget build(BuildContext context) {
    return BottomSheetScaffold(
      title: 'Choose music folders',
      subtitle: 'Only these folders are indexed',
      actions: [
        TextButton(
          onPressed: () {
            sendCommand(ref, const Rescan());
            Navigator.of(context).pop();
            widget.onDone?.call();
          },
          child: Text(context.l10n.actionDone),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final f in _candidates)
            CheckboxListTile(
              value: _entireDrive || _selected.contains(f.id),
              onChanged: _entireDrive
                  ? null
                  : (v) => setState(() {
                        v == true
                            ? _selected.add(f.id)
                            : _selected.remove(f.id);
                      }),
              title: Text(f.name),
              subtitle: Text('${f.tracks} tracks · ${f.size}'),
              secondary: const Icon(Icons.folder_outlined),
            ),
          Divider(color: context.c.outline),
          SwitchListTile(
            value: _entireDrive,
            onChanged: (v) => setState(() => _entireDrive = v),
            title: const Text('Scan entire Drive'),
            subtitle: const Text(
              'Slower, and uses more of your daily Drive request budget. '
              'Most libraries do not need this.',
            ),
            secondary: Icon(Icons.warning_amber_rounded,
                color: context.c.tierResampled),
          ),
          const SizedBox(height: Spacing.md),
        ],
      ),
    );
  }
}

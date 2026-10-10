import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core_api/commands.dart';
import '../../core_api/models.dart';
import '../../l10n/l10n.dart';
import '../../core_api/enums.dart';
import '../../providers/core_providers.dart';
import '../storage/google_drive_service.dart';
import 'folder_picker.dart';
import '../../util/format.dart';
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
    final scan = ref.watch(cloudScanStatusProvider).valueOrNull ?? SyncStatus.idle;
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
        if (sources.isEmpty) _ConnectDriveCard(scan: scan),
        if (sources.isNotEmpty)
          for (final s in sources)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  Spacing.md, Spacing.xs, Spacing.md, 0),
              child: SourceCard(
                account: s,
                showAdvanced: _advanced,
                onToggleAdvanced: () => setState(() => _advanced = !_advanced),
                // A real connection drives the real library; the mock core
                // still backs the other scenarios in the switcher.
                onRescan: s.id == 'drive'
                    ? () {
                        final library = ref.read(cloudLibraryProvider);
                        if (library.currentFolders.isEmpty) {
                          unawaited(showDriveFolderPicker(context));
                        } else {
                          unawaited(library.scan());
                        }
                      }
                    : () => sendCommand(ref, Rescan(sourceId: s.id)),
                onEditFolders: () => _showFolderPicker(context),
                onReconnect: s.status == SourceStatus.needsReconnect
                    ? () async {
                        if (s.id == 'drive') {
                          final r =
                              await ref.read(driveServiceProvider).signIn();
                          if (r == DriveConnectResult.connected) {
                            await ref.read(cloudLibraryProvider).scan();
                          }
                        } else {
                          sendCommand(ref, ReconnectSource(s.id));
                        }
                      }
                    : null,
                onRemove: () => _confirmRemove(context, s),
              ),
            ),
        const SectionHeader(title: 'Add a source'),
        _ProviderTile(
          icon: Icons.add_to_drive,
          name: 'Google Drive',
          detail: !GoogleDriveService.isPlatformSupported
              ? 'Needs the Android or iOS build'
              : (sources.isEmpty
                  ? 'Not connected'
                  : 'Connected · ${sources.first.accountLabel}'),
          // Greyed on desktop for the same reason as the card above: it is
          // not something the user can act on here.
          available: GoogleDriveService.isPlatformSupported,
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
    if (!ok) return;
    if (s.id == 'drive') {
      await ref.read(driveServiceProvider).signOut();
      await ref.read(cloudLibraryProvider).clear();
    } else {
      sendCommand(ref, RemoveSource(s.id));
    }
  }

  void _showFolderPicker(BuildContext context) =>
      unawaited(showDriveFolderPicker(context));
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


/// The live Google Drive connection: who is signed in, what the scan is doing,
/// and the actions that move it along.
class _ConnectDriveCard extends ConsumerWidget {
  const _ConnectDriveCard({required this.scan});

  final SyncStatus scan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final drive = ref.watch(driveServiceProvider);

    // Linux and Windows ship no Google Sign-In plugin, so offering a button
    // that cannot work would be worse than saying so plainly.
    final supported = GoogleDriveService.isPlatformSupported;
    final accent = supported ? c.accent : c.tierResampled;

    return Container(
      margin: const EdgeInsets.fromLTRB(
          Spacing.md, Spacing.xs, Spacing.md, Spacing.xs),
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: Radii.cardR,
        border: Border.all(color: accent.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: c.surface3,
                  borderRadius: Radii.chipR,
                ),
                child: Icon(
                  supported ? Icons.add_to_drive : Icons.desktop_access_disabled,
                  size: 20,
                  color: supported ? c.textSecondary : accent,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Google Drive', style: context.t.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      supported
                          ? 'Not connected'
                          : 'Not available on this platform',
                      style: context.t.bodySmall
                          .copyWith(color: supported ? c.textSecondary : accent),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (scan.phase != SyncPhase.idle) ...[
            const SizedBox(height: Spacing.sm),
            Row(
              children: [
                Expanded(
                  child: Text(
                    switch (scan.phase) {
                      SyncPhase.listing =>
                        'Finding music · ${Fmt.count(scan.processed)} files',
                      SyncPhase.tags =>
                        'Reading tags · ${Fmt.count(scan.processed)} of '
                            '${Fmt.count(scan.total)}',
                      SyncPhase.paused =>
                        scan.detail ?? 'Paused',
                      SyncPhase.error => scan.detail ?? 'Scan failed',
                      SyncPhase.idle => '',
                    },
                    style: context.t.bodySmall,
                  ),
                ),
                if (scan.total > 0)
                  Text(Fmt.percent(scan.progress),
                      style: context.t.monoReadout
                          .copyWith(color: c.textSecondary)),
              ],
            ),
            const SizedBox(height: Spacing.xxs),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: SizedBox(
                height: 4,
                child: LinearProgressIndicator(
                  // Listing has no known total until it finishes, so it shows
                  // as indeterminate rather than inventing a denominator.
                  value: scan.phase == SyncPhase.listing && scan.total == 0
                      ? null
                      : scan.progress,
                  backgroundColor: c.surface3,
                  color: scan.phase == SyncPhase.error
                      ? c.error
                      : (scan.phase == SyncPhase.paused
                          ? c.tierResampled
                          : c.accent),
                ),
              ),
            ),
          ],
          const SizedBox(height: Spacing.sm),
          if (!supported) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              'Google Sign-In has no desktop implementation, so BitDrop '
              'cannot reach your Drive from here. Run the Android or iOS '
              'build to connect your cloud library.',
              style: context.t.bodySmall.copyWith(color: c.textSecondary),
            ),
            const SizedBox(height: Spacing.xs),
            Row(
              children: [
                Icon(Icons.check_circle_outline, size: 14, color: c.success),
                const SizedBox(width: Spacing.xxs),
                Expanded(
                  child: Text(
                    'Everything else works here: local files, playback, the '
                    'equaliser and the signal path.',
                    style: context.t.bodySmall
                        .copyWith(color: c.textSecondary),
                  ),
                ),
              ],
            ),
          ] else
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () async {
                final result = await drive.signIn();
                if (result == DriveConnectResult.connected) {
                  // Straight to the picker: scanning an entire Drive is slow
                  // and indexes a lot that is not music.
                  if (context.mounted) await showDriveFolderPicker(context);
                  return;
                }
                final message = result.message;
                if (message != null && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(message),
                      duration: const Duration(seconds: 6),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.login, size: 16),
              label: const Text('Connect Google Drive'),
            ),
          ),
        ],
      ),
    );
  }
}

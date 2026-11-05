import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core_api/commands.dart';
import '../../core_api/models.dart';
import '../../l10n/l10n.dart';
import '../../core_api/enums.dart';
import '../../core_live/live_core.dart';
import '../../providers/core_providers.dart';
import '../storage/google_drive_service.dart';
import 'folder_picker.dart';
import '../../util/format.dart';
import '../../routing/routes.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/cards.dart';
import '../../widgets/common.dart';
import '../../widgets/indicators.dart';

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

  @override
  Widget build(BuildContext context) {
    final sources = ref.watch(sourcesProvider).valueOrNull ?? const [];
    final scan = ref.watch(cloudScanStatusProvider).valueOrNull ?? SyncStatus.idle;
    final l = context.l10n;
    final c = context.c;

    return Stack(
      children: [
        // Whisper-soft, deep ambient atmospheric cloud aura glow at the top
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 260,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, -0.7),
                  radius: 1.1,
                  colors: [
                    c.accent.withOpacity(0.06),
                    const Color(0xFF06B6D4).withOpacity(0.025),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.45, 1.0],
                ),
              ),
            ),
          ),
        ),

        ListView(
          padding: const EdgeInsets.only(bottom: Spacing.xxl),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  Spacing.md, Spacing.xs, Spacing.xs, Spacing.xs),
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(l.navSources, style: context.t.headline),
                          const SizedBox(width: Spacing.xs),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: c.accent.withOpacity(0.12),
                              borderRadius: Radii.badgeR,
                              border: Border.all(
                                  color: c.accent.withOpacity(0.25)),
                            ),
                            child: Text(
                              'DIRECT STREAM',
                              style: context.t.monoLabel.copyWith(
                                color: c.accent,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Direct-to-DAC lossless cloud vaults',
                        style: context.t.bodySmall
                            .copyWith(color: c.textSecondary),
                      ),
                    ],
                  ),
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
                    onCancelSync: s.id == 'drive'
                        ? () {
                            ref.read(cloudLibraryProvider).cancelScan();
                          }
                        : null,
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
            if (sources.isNotEmpty) ...[
              const SizedBox(height: Spacing.sm),
              const _CacheCard(),
            ],
            if (sources.isEmpty) ...[
              const SectionHeader(title: 'Add a source'),
              _ProviderTile(
                icon: Icons.add_to_drive,
                name: 'Google Drive',
                detail: !GoogleDriveService.isPlatformSupported
                    ? 'Needs the Android or iOS build'
                    : 'Not connected',
                available: GoogleDriveService.isPlatformSupported,
              ),
            ],
            const _ComingLater(),
            const SizedBox(height: Spacing.md),
            const _PrivacyNote(),
          ],
        ),
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
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: Radii.cardR,
        border: Border.all(color: c.success.withOpacity(0.25)),
        boxShadow: [
          BoxShadow(
            color: c.success.withOpacity(0.04),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: c.success.withOpacity(0.12),
              borderRadius: Radii.badgeR,
              border: Border.all(color: c.success.withOpacity(0.3)),
            ),
            child: Icon(Icons.shield_outlined, size: 18, color: c.success),
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Zero-Knowledge Direct Architecture',
                  style: context.t.label.copyWith(
                    color: c.textPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'BitDrop operates with zero middleman servers. Your cloud '
                  'credentials and music files stay strictly between this phone '
                  'and your storage, streaming directly into the DAC.',
                  style: context.t.bodySmall.copyWith(
                    color: c.textSecondary,
                    height: 1.35,
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
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: Radii.cardR,
        border: Border.all(color: accent.withOpacity(0.35)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
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
                  color: c.surface2,
                  borderRadius: Radii.chipR,
                  border: Border.all(color: c.outline.withOpacity(0.4)),
                ),
                child: Icon(
                  supported ? Icons.add_to_drive : Icons.desktop_access_disabled,
                  size: 22,
                  color: supported ? c.accent : accent,
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
                if (scan.phase == SyncPhase.listing ||
                    scan.phase == SyncPhase.tags) ...[
                  SpinningSyncIcon(size: 14, color: c.accent),
                  const SizedBox(width: Spacing.xs),
                ] else if (scan.phase == SyncPhase.paused) ...[
                  Icon(Icons.hourglass_top, size: 14, color: c.tierResampled),
                  const SizedBox(width: Spacing.xs),
                ],
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

/// What the streamed audio cache is costing, and a way to get it back.
///
/// Reports the reclaimable figure only. Cover art and the library index are
/// deliberately not counted and not cleared: they are a few megabytes, and
/// throwing them away would blank the library until the next full rescan —
/// a much worse trade than the space is worth.
class _CacheCard extends ConsumerStatefulWidget {
  const _CacheCard();

  @override
  ConsumerState<_CacheCard> createState() => _CacheCardState();
}

class _CacheCardState extends ConsumerState<_CacheCard> {
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    // Chunks are written while playing and dropped by Android when it wants
    // the space, so the figure is only trustworthy if it is re-measured on
    // arrival rather than read from whatever was last seen.
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  void _refresh() {
    final core = ref.read(coreProvider);
    if (core is LiveBitDropCore) unawaited(core.refreshStorage());
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final storage = ref.watch(storageProvider).valueOrNull;
    final bytes = storage?.cacheBytes ?? 0;
    final artwork = storage?.artworkBytes ?? 0;
    final totalBytes = bytes + artwork;
    final core = ref.read(coreProvider);
    final tracks = core is LiveBitDropCore ? core.cachedTrackCount : 0;

    final audioRatio = totalBytes > 0 ? (bytes / totalBytes) : 0.0;
    final artRatio = totalBytes > 0 ? (artwork / totalBytes) : 0.0;

    return Padding(
      padding:
          const EdgeInsets.fromLTRB(Spacing.md, Spacing.xs, Spacing.md, 0),
      child: Container(
        decoration: BoxDecoration(
          color: c.surface1,
          borderRadius: Radii.cardR,
          border: Border.all(color: c.outline.withOpacity(0.45)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.2),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        padding: const EdgeInsets.all(Spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: Icon + Title + Total size pill
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: c.surface2,
                    borderRadius: Radii.badgeR,
                    border: Border.all(color: c.outline.withOpacity(0.4)),
                  ),
                  child: Icon(
                    Icons.sd_storage_outlined,
                    size: 18,
                    color: c.accent,
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Local Storage & Cache',
                        style: context.t.titleSmall.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        'Streaming audio chunks & artwork cache',
                        style: context.t.bodySmall.copyWith(
                          color: c.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: c.surface2,
                    borderRadius: Radii.badgeR,
                    border: Border.all(color: c.outline.withOpacity(0.4)),
                  ),
                  child: Text(
                    Fmt.bytes(totalBytes),
                    style: context.t.monoReadout.copyWith(
                      color: c.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: Spacing.sm),

            // Segmented Gauge Bar
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 8,
                child: totalBytes == 0
                    ? Container(color: c.surface3)
                    : Row(
                        children: [
                          if (bytes > 0)
                            Expanded(
                              flex: (audioRatio * 100).round().clamp(1, 100),
                              child: Container(
                                color: c.accent,
                              ),
                            ),
                          if (bytes > 0 && artwork > 0)
                            const SizedBox(width: 2),
                          if (artwork > 0)
                            Expanded(
                              flex: (artRatio * 100).round().clamp(1, 100),
                              child: Container(
                                color: c.tierNativeRate,
                              ),
                            ),
                        ],
                      ),
              ),
            ),

            const SizedBox(height: Spacing.sm),

            // Dual Stat Tiles: Streamed Audio & Cover Art
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(Spacing.xs),
                    decoration: BoxDecoration(
                      color: c.surface2.withOpacity(0.55),
                      borderRadius: Radii.chipR,
                      border: Border.all(color: c.outline.withOpacity(0.35)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: c.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: Spacing.xs),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                tracks > 0
                                    ? 'Audio ($tracks trk)'
                                    : 'Audio Cache',
                                style: context.t.monoLabel.copyWith(
                                  color: c.textTertiary,
                                  fontSize: 9.5,
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                Fmt.bytes(bytes),
                                style: context.t.monoReadout.copyWith(
                                  color: c.textPrimary,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 11,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: Spacing.xs),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(Spacing.xs),
                    decoration: BoxDecoration(
                      color: c.surface2.withOpacity(0.55),
                      borderRadius: Radii.chipR,
                      border: Border.all(color: c.outline.withOpacity(0.35)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: c.tierNativeRate,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: Spacing.xs),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Cover Art',
                                style: context.t.monoLabel.copyWith(
                                  color: c.textTertiary,
                                  fontSize: 9.5,
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                artwork == 0
                                    ? '0 B'
                                    : '${Fmt.bytes(artwork)} (Kept)',
                                style: context.t.monoReadout.copyWith(
                                  color: c.textPrimary,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 11,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: Spacing.sm),

            // Clear Reclaim Action Row
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Reclaim streamed chunk space safely',
                    style: context.t.bodySmall.copyWith(
                      color: c.textTertiary,
                      fontSize: 11,
                    ),
                  ),
                ),
                OutlinedButton(
                  onPressed:
                      (bytes > 0 && !_clearing) ? _confirmClear : null,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.error,
                    side: BorderSide(
                      color: bytes > 0
                          ? c.error.withOpacity(0.4)
                          : c.outline.withOpacity(0.3),
                    ),
                    shape: const RoundedRectangleBorder(borderRadius: Radii.badgeR),
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(
                        horizontal: Spacing.sm, vertical: 4),
                  ),
                  child: Text(
                    _clearing ? 'Clearing…' : 'Clear Audio Cache',
                    style: context.t.label.copyWith(
                      color: bytes > 0 ? c.error : c.textTertiary,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmClear() async {
    final bytes = ref.read(storageProvider).valueOrNull?.cacheBytes ?? 0;
    final ok = await ConfirmDialog.show(
      context,
      title: 'Clear cached audio?',
      // Says what is lost as well as what is gained: nothing here is
      // irreplaceable, and the user should be able to see that.
      message: 'Frees ${Fmt.bytes(bytes)}. Your music stays in Drive and will '
          'stream again when you play it. Cover art and the library index '
          'are kept, so nothing needs rescanning.',
      confirmLabel: 'Clear',
    );
    if (!ok || !mounted) return;

    setState(() => _clearing = true);
    sendCommand(ref, const ClearCache());
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (mounted) setState(() => _clearing = false);
  }
}

/// The providers that are not here yet, as one quiet line.
class _ComingLater extends StatelessWidget {
  const _ComingLater();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, 0),
      child: Text(
        'S3-compatible, WebDAV and OpenSubsonic are coming later.',
        style: context.t.bodySmall.copyWith(color: context.c.textTertiary),
      ),
    );
  }
}

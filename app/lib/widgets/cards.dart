import 'package:flutter/material.dart';

import '../core_api/enums.dart';
import '../core_api/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../util/format.dart';
import 'indicators.dart';

/// Output device card: name, connection, tier, capabilities, hardware volume.
class DeviceCard extends StatelessWidget {
  const DeviceCard({
    super.key,
    required this.device,
    required this.tier,
    this.onRunSafetyCheck,
    this.onTap,
    this.profile,
    this.expanded = true,
    this.note,
  });

  final OutputDevice device;
  final OutputTier tier;
  final VoidCallback? onRunSafetyCheck;
  final VoidCallback? onTap;
  final DeviceProfile? profile;
  final bool expanded;

  /// Extra core-supplied line, e.g. the Bluetooth codec caveat.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: Radii.cardR,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.sm),
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
                      switch (device.type) {
                        DeviceType.usb => Icons.usb,
                        DeviceType.bluetooth => Icons.bluetooth,
                        DeviceType.phoneSpeaker => Icons.smartphone,
                        DeviceType.wiredAnalog => Icons.headphones,
                        DeviceType.unknown => Icons.devices_other,
                      },
                      size: 20,
                      color: c.textSecondary,
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(device.name,
                            style: context.t.titleSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 2),
                        Text(
                          device.connectionLabel ?? device.typeLabel,
                          style: context.t.bodySmall
                              .copyWith(color: c.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  TierChip(tier: tier, dense: true),
                ],
              ),
              if (note != null) ...[
                const SizedBox(height: Spacing.xs),
                Text(note!,
                    style:
                        context.t.bodySmall.copyWith(color: c.textSecondary)),
              ],
              if (expanded) ...[
                const SizedBox(height: Spacing.sm),
                _CapRow(
                  label: 'Sample rates',
                  chips: device.supportedRates.map(Fmt.kHzBare).toList(),
                  unit: 'kHz',
                ),
                const SizedBox(height: Spacing.xs),
                _CapRow(
                  label: 'Bit depths',
                  chips: device.bitDepths.map((d) => '$d').toList(),
                  unit: 'bit',
                ),
                const SizedBox(height: Spacing.xs),
                Row(
                  children: [
                    Text('Hardware volume',
                        style: context.t.bodySmall
                            .copyWith(color: c.textSecondary)),
                    const Spacer(),
                    Row(
                      children: [
                        Icon(
                          switch (device.hardwareVolume) {
                            HardwareVolume.yes => Icons.check_circle_outline,
                            HardwareVolume.no => Icons.cancel_outlined,
                            HardwareVolume.unknown => Icons.help_outline,
                          },
                          size: 14,
                          color: switch (device.hardwareVolume) {
                            HardwareVolume.yes => c.success,
                            HardwareVolume.no => c.tierResampled,
                            HardwareVolume.unknown => c.textSecondary,
                          },
                        ),
                        const SizedBox(width: 4),
                        Text(
                          switch (device.hardwareVolume) {
                            HardwareVolume.yes => 'Yes',
                            HardwareVolume.no => 'No',
                            HardwareVolume.unknown => 'Unknown',
                          },
                          style: context.t.monoReadout,
                        ),
                      ],
                    ),
                  ],
                ),
                if (profile != null) ...[
                  const SizedBox(height: Spacing.xs),
                  Divider(height: Spacing.md, color: c.outline),
                  Text('Saved profile',
                      style:
                          context.t.monoLabel.copyWith(color: c.textSecondary)),
                  const SizedBox(height: Spacing.xxs),
                  Text(
                    [
                      if (profile!.eqPresetName != null)
                        'EQ: ${profile!.eqPresetName}',
                      'ReplayGain: ${profile!.replayGain.name}',
                      if (profile!.preferredVolumeDb != null)
                        'Volume: ${Fmt.db(profile!.preferredVolumeDb!)}',
                      if (profile!.safetyAttenuationDb != null)
                        'Safety: ${Fmt.db(profile!.safetyAttenuationDb!)}',
                    ].join(' · '),
                    style: context.t.bodySmall,
                  ),
                ],
                if (onRunSafetyCheck != null) ...[
                  const SizedBox(height: Spacing.sm),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: onRunSafetyCheck,
                      icon: const Icon(Icons.hearing, size: 16),
                      label: const Text('Run safety check'),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CapRow extends StatelessWidget {
  const _CapRow({
    required this.label,
    required this.chips,
    required this.unit,
  });

  final String label;
  final List<String> chips;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label ($unit)',
            style: context.t.monoLabel.copyWith(color: c.textSecondary)),
        const SizedBox(height: Spacing.xxs),
        Wrap(
          spacing: Spacing.xxs,
          runSpacing: Spacing.xxs,
          children: [
            for (final v in chips)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: c.surface2,
                  borderRadius: Radii.badgeR,
                  border: Border.all(color: c.outline),
                ),
                child: Text(v, style: context.t.monoLabel),
              ),
          ],
        ),
      ],
    );
  }
}

/// Source account card: provider, account, status, activity, actions.
class SourceCard extends StatelessWidget {
  const SourceCard({
    super.key,
    required this.account,
    this.onRescan,
    this.onCancelSync,
    this.onEditFolders,
    this.onReconnect,
    this.onRemove,
  });

  final SourceAccount account;
  final VoidCallback? onRescan;
  final VoidCallback? onCancelSync;
  final VoidCallback? onEditFolders;
  final VoidCallback? onReconnect;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final needsAction = account.status == SourceStatus.needsReconnect;

    final isLocal = account.id == 'local' ||
        account.provider.toLowerCase().contains('device');
    final (Color statusColor, IconData statusIcon, String statusText) =
        switch (account.status) {
      SourceStatus.upToDate => (
          c.success,
          isLocal ? Icons.check_circle_outline : Icons.cloud_done_outlined,
          'Up to date'
        ),
      SourceStatus.syncing => (c.accent, Icons.sync, 'Syncing'),
      SourceStatus.needsReconnect => (
          c.tierResampled,
          Icons.key_off_outlined,
          'Needs reconnection'
        ),
      SourceStatus.rateLimited => (
          c.tierResampled,
          Icons.hourglass_top,
          'Paused · Rate limited'
        ),
      SourceStatus.offline => (c.textSecondary, Icons.cloud_off, 'Offline'),
      SourceStatus.error => (c.error, Icons.error_outline, 'Error'),
    };

    return Container(
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: Radii.cardR,
        border: Border.all(
          color: needsAction
              ? c.tierResampled.withOpacity(0.6)
              : c.accent.withOpacity(0.22),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: Emblem + Account info + Status Badge + Menu
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
                padding: const EdgeInsets.all(9),
                child: isLocal
                    ? Icon(Icons.phone_android, size: 22, color: c.accent)
                    : account.id == 'drive' ||
                            account.provider.toLowerCase().contains('drive')
                        ? Image.asset('assets/google_drive.png',
                            fit: BoxFit.contain)
                        : Icon(Icons.cloud_queue, size: 22, color: c.accent),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account.provider,
                      style: context.t.title.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      account.accountLabel,
                      style: context.t.bodySmall.copyWith(
                        color: c.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Spacing.xs),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: statusColor.withOpacity(0.35)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (account.status == SourceStatus.syncing)
                      SpinningSyncIcon(size: 13, color: statusColor)
                    else
                      Icon(statusIcon, size: 13, color: statusColor),
                    const SizedBox(width: 4),
                    Text(
                      statusText,
                      style: context.t.label.copyWith(
                        color: statusColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (onRemove != null)
                PopupMenuButton<void>(
                  tooltip: 'Options',
                  icon: Icon(Icons.more_vert, size: 18, color: c.textSecondary),
                  padding: EdgeInsets.zero,
                  elevation: 12,
                  shadowColor: Colors.black.withOpacity(0.6),
                  color: c.surface2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: c.outline.withOpacity(0.5)),
                  ),
                  offset: const Offset(0, 38),
                  itemBuilder: (_) => [
                    PopupMenuItem<void>(
                      onTap: onRemove,
                      height: 44,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: c.error.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(Icons.delete_outline,
                                size: 16, color: c.error),
                          ),
                          const SizedBox(width: Spacing.sm),
                          Text(
                            'Disconnect source',
                            style: context.t.label.copyWith(
                              color: c.error,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
          ),

          // Activity progress bar if syncing or retrying
          if (account.activityLabel != null) ...[
            const SizedBox(height: Spacing.sm),
            Row(
              children: [
                Expanded(
                  child: Text(
                    account.retryInSeconds != null
                        ? '${account.activityLabel} · retrying in ${account.retryInSeconds}s'
                        : account.activityLabel!,
                    style: context.t.bodySmall,
                  ),
                ),
                if (account.activityProgress != null)
                  Text(
                    Fmt.percent(account.activityProgress!),
                    style: context.t.monoReadout
                        .copyWith(color: c.textSecondary),
                  ),
              ],
            ),
            const SizedBox(height: Spacing.xxs),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                height: 5,
                child: LinearProgressIndicator(
                  value: account.activityProgress,
                  backgroundColor: c.surface3,
                  color: account.status == SourceStatus.rateLimited
                      ? c.tierResampled
                      : c.accent,
                ),
              ),
            ),
          ],

          const SizedBox(height: Spacing.sm),

          // Audiophile Metrics HUD
          Row(
            children: [
              Expanded(
                child: _SourceMetricTile(
                  label: 'Tracks',
                  value: Fmt.count(account.trackCount),
                  sublabel: 'Lossless & Hi-Res',
                ),
              ),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: _SourceMetricTile(
                  label: 'Folders',
                  value: '${account.folderCount}',
                  sublabel: 'Music Vault',
                ),
              ),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: _SourceMetricTile(
                  label: 'Last Sync',
                  value: account.lastSync != null
                      ? Fmt.relativeTime(account.lastSync)
                      : 'Never',
                  sublabel: account.changesSinceLastSync ?? 'Direct Stream',
                ),
              ),
            ],
          ),

          const SizedBox(height: Spacing.sm),

          // Actions
          Row(
            children: [
              if (needsAction && onReconnect != null)
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onReconnect,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Reconnect'),
                    style: FilledButton.styleFrom(
                      shape: const RoundedRectangleBorder(borderRadius: Radii.chipR),
                      minimumSize: const Size(0, 38),
                    ),
                  ),
                ),
              if (onRescan != null && account.status != SourceStatus.syncing)
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: onRescan,
                    icon: const Icon(Icons.sync, size: 15),
                    label: const Text('Rescan'),
                    style: FilledButton.styleFrom(
                      backgroundColor: c.surface3,
                      foregroundColor: c.textPrimary,
                      side: BorderSide(color: c.outline.withOpacity(0.5)),
                      shape: const RoundedRectangleBorder(borderRadius: Radii.chipR),
                      minimumSize: const Size(0, 38),
                    ),
                  ),
                ),
              if (onCancelSync != null &&
                  account.status == SourceStatus.syncing)
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: onCancelSync,
                    icon: const Icon(Icons.cancel_outlined, size: 15),
                    label: const Text('Stop Sync'),
                    style: FilledButton.styleFrom(
                      backgroundColor: c.error.withOpacity(0.12),
                      foregroundColor: c.error,
                      side: BorderSide(color: c.error.withOpacity(0.35)),
                      shape: const RoundedRectangleBorder(borderRadius: Radii.chipR),
                      minimumSize: const Size(0, 38),
                    ),
                  ),
                ),
              if (onEditFolders != null) ...[
                const SizedBox(width: Spacing.xs),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onEditFolders,
                    icon: const Icon(Icons.folder_outlined, size: 15),
                    label: const Text('Edit folders'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.textSecondary,
                      side: BorderSide(color: c.outline.withOpacity(0.6)),
                      shape: const RoundedRectangleBorder(borderRadius: Radii.chipR),
                      minimumSize: const Size(0, 38),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _SourceMetricTile extends StatelessWidget {
  const _SourceMetricTile({
    required this.label,
    required this.value,
    required this.sublabel,
  });

  final String label;
  final String value;
  final String sublabel;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.xs,
        vertical: Spacing.xs,
      ),
      decoration: BoxDecoration(
        color: c.surface2.withOpacity(0.55),
        borderRadius: Radii.chipR,
        border: Border.all(color: c.outline.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            label.toUpperCase(),
            style: context.t.monoLabel.copyWith(
              color: c.textTertiary,
              fontSize: 9,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: context.t.titleSmall.copyWith(
              color: c.textPrimary,
              fontWeight: FontWeight.w700,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 1),
          Text(
            sublabel,
            style: context.t.monoLabel.copyWith(
              color: c.textSecondary,
              fontSize: 9,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// Compact current-output card for Home.
class OutputSummaryCard extends StatelessWidget {
  const OutputSummaryCard({
    super.key,
    required this.path,
    required this.onTap,
  });

  final SignalPath path;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final device = path.device;
    final detail = path.tier == OutputTier.resampled
        ? 'Resampled to ${Fmt.kHz(path.actual.sampleRate)}'
        : path.actual.longLabel;

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: Radii.cardR,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.sm),
          child: Row(
            children: [
              Icon(
                switch (device?.type) {
                  DeviceType.usb => Icons.usb,
                  DeviceType.bluetooth => Icons.bluetooth,
                  DeviceType.phoneSpeaker => Icons.smartphone,
                  DeviceType.wiredAnalog => Icons.headphones,
                  _ => Icons.devices_other,
                },
                size: 20,
                color: c.textSecondary,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device?.name ?? 'No output device',
                      style: context.t.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${device?.typeLabel ?? '—'} · $detail',
                      style:
                          context.t.bodySmall.copyWith(color: c.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Spacing.xs),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  TierChip(tier: path.tier, dense: true),
                  if (path.dspActive) ...[
                    const SizedBox(height: 4),
                    const DspBadge(dense: true),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

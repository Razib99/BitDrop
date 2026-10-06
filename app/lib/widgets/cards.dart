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
                      style: context.t.monoLabel
                          .copyWith(color: c.textSecondary)),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
    this.onEditFolders,
    this.onReconnect,
    this.onRemove,
    this.showAdvanced = false,
    this.onToggleAdvanced,
  });

  final SourceAccount account;
  final VoidCallback? onRescan;
  final VoidCallback? onEditFolders;
  final VoidCallback? onReconnect;
  final VoidCallback? onRemove;
  final bool showAdvanced;
  final VoidCallback? onToggleAdvanced;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final needsAction = account.status == SourceStatus.needsReconnect;

    final (Color statusColor, IconData statusIcon, String statusText) =
        switch (account.status) {
      SourceStatus.upToDate => (
          c.success,
          Icons.cloud_done_outlined,
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
          'Paused · Drive is limiting requests'
        ),
      SourceStatus.offline => (c.textSecondary, Icons.cloud_off, 'Offline'),
      SourceStatus.error => (c.error, Icons.error_outline, 'Error'),
    };

    return Card(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: Radii.cardR,
          border: needsAction
              ? Border.all(color: c.tierResampled.withOpacity(0.6))
              : null,
        ),
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
                  child: Icon(Icons.add_to_drive,
                      size: 20, color: c.textSecondary),
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(account.provider, style: context.t.titleSmall),
                      const SizedBox(height: 2),
                      Text(
                        account.accountLabel,
                        style: context.t.bodySmall
                            .copyWith(color: c.textSecondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(statusIcon, size: 14, color: statusColor),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        statusText,
                        style: context.t.label.copyWith(color: statusColor),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              'Synced ${Fmt.relativeTime(account.lastSync)} · '
              '${Fmt.count(account.trackCount)} tracks · '
              '${account.folderCount} folder'
              '${account.folderCount == 1 ? '' : 's'}',
              style: context.t.monoLabel.copyWith(color: c.textSecondary),
            ),
            if (account.activityLabel != null) ...[
              const SizedBox(height: Spacing.xs),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      account.retryInSeconds != null
                          ? '${account.activityLabel} · retrying in '
                              '${account.retryInSeconds}s'
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
                borderRadius: BorderRadius.circular(2),
                child: SizedBox(
                  height: 4,
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
            if (showAdvanced && account.changesSinceLastSync != null) ...[
              const SizedBox(height: Spacing.xs),
              Text(
                'Changes since last sync: ${account.changesSinceLastSync}',
                style: context.t.monoLabel.copyWith(color: c.textSecondary),
              ),
            ],
            const SizedBox(height: Spacing.xs),
            Wrap(
              spacing: Spacing.xs,
              runSpacing: Spacing.xxs,
              children: [
                if (needsAction && onReconnect != null)
                  FilledButton.icon(
                    onPressed: onReconnect,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Reconnect'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 36),
                      padding:
                          const EdgeInsets.symmetric(horizontal: Spacing.sm),
                    ),
                  ),
                if (onRescan != null)
                  _SmallButton(
                      label: 'Rescan', icon: Icons.sync, onTap: onRescan!),
                if (onEditFolders != null)
                  _SmallButton(
                      label: 'Edit folders',
                      icon: Icons.folder_outlined,
                      onTap: onEditFolders!),
                if (onToggleAdvanced != null)
                  _SmallButton(
                    label: showAdvanced ? 'Less' : 'Advanced',
                    icon: showAdvanced ? Icons.expand_less : Icons.expand_more,
                    onTap: onToggleAdvanced!,
                  ),
                if (onRemove != null)
                  _SmallButton(
                      label: 'Remove',
                      icon: Icons.delete_outline,
                      onTap: onRemove!,
                      destructive: true),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.destructive = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 15),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
          foregroundColor: destructive ? context.c.error : null,
          textStyle: context.t.label,
        ),
      );
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
                      style: context.t.bodySmall
                          .copyWith(color: c.textSecondary),
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

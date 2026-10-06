import 'package:flutter/material.dart';

import '../core_api/enums.dart';
import '../core_api/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../util/format.dart';
import 'indicators.dart';

/// One stage in the chain: status colour, icon, label and a mono detail line.
class SignalNode extends StatelessWidget {
  const SignalNode({
    super.key,
    required this.icon,
    required this.label,
    required this.detail,
    required this.color,
    this.secondary,
    this.isLast = false,
    this.onTap,
    this.trailing,
    this.highlighted = false,
  });

  final IconData icon;
  final String label;
  final String detail;
  final Color color;
  final String? secondary;
  final bool isLast;
  final VoidCallback? onTap;
  final Widget? trailing;

  /// Marks the stage responsible for the current verdict.
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      label: '$label: $detail${secondary == null ? '' : ', $secondary'}',
      button: onTap != null,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Rail: node marker plus the connector down to the next stage.
              SizedBox(
                width: 36,
                child: Column(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: color.withOpacity(highlighted ? 0.22 : 0.12),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: color.withOpacity(highlighted ? 0.9 : 0.45),
                          width: highlighted ? 2 : 1,
                        ),
                      ),
                      child: Icon(icon, size: 15, color: color),
                    ),
                    if (!isLast)
                      Expanded(
                        child: Container(
                          width: 2,
                          margin: const EdgeInsets.symmetric(vertical: 2),
                          color: c.outline,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(bottom: isLast ? 0 : Spacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              label.toUpperCase(),
                              style: context.t.monoLabel
                                  .copyWith(color: c.textSecondary),
                            ),
                          ),
                          if (trailing != null) trailing!,
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        style: context.t.monoReadout
                            .copyWith(color: c.textPrimary),
                      ),
                      if (secondary != null) ...[
                        const SizedBox(height: 1),
                        Text(
                          secondary!,
                          style: context.t.bodySmall
                              .copyWith(color: c.textSecondary),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The full source → decoder → DSP → volume → output → device chain.
///
/// Every string here comes from [SignalPath]. The widget decides layout, never
/// meaning: it cannot upgrade a tier or invent a format.
class SignalPathDiagram extends StatelessWidget {
  const SignalPathDiagram({
    super.key,
    required this.path,
    this.onTurnOffEq,
    this.onRunSafetyCheck,
    this.onOpenDiagnostics,
    this.showActions = true,
  });

  final SignalPath path;
  final VoidCallback? onTurnOffEq;
  final VoidCallback? onRunSafetyCheck;
  final VoidCallback? onOpenDiagnostics;
  final bool showActions;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final tierColor = TierChip.colorFor(context, path.tier);
    final device = path.device;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _VerdictBanner(path: path, color: tierColor),
        const SizedBox(height: Spacing.md),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SignalNode(
                icon: Icons.cloud_outlined,
                label: 'Source',
                detail: path.sourceLabel,
                secondary: path.throughputMbps == null
                    ? '${path.cachedPercent}% cached · offline'
                    : '${path.cachedPercent}% cached · streaming '
                        '${Fmt.mbps(path.throughputMbps!)}',
                color: c.textSecondary,
              ),
              SignalNode(
                icon: Icons.memory,
                label: 'Decoder',
                detail: path.decoderLabel ??
                    '${path.source.codec.label} ${path.source.longLabel}',
                secondary: path.source.bitrateKbps == null
                    ? null
                    : '${Fmt.kbps(path.source.bitrateKbps)} source bitrate',
                color: c.textSecondary,
              ),
              SignalNode(
                icon: path.dspActive ? Icons.graphic_eq : Icons.block,
                label: 'DSP',
                detail: path.dspActive
                    ? path.dspChain.join(' · ')
                    : 'Off — bypassed',
                secondary: path.dspActive
                    ? 'Processing changes the samples, so bit-perfect is not '
                        'possible while this is on.'
                    : 'True bypass: samples pass through untouched.',
                color: path.dspActive ? c.dspActive : c.textSecondary,
                highlighted: path.dspActive,
                trailing: path.dspActive ? const DspBadge(dense: true) : null,
              ),
              SignalNode(
                icon: Icons.volume_up_outlined,
                label: 'Volume',
                detail: switch (path.volume) {
                  VolumeMode.dacHardware => 'DAC hardware',
                  VolumeMode.softwareDithered => 'Software, 24-bit dithered',
                  VolumeMode.system => 'System',
                },
                secondary: switch (path.volume) {
                  VolumeMode.dacHardware =>
                    'BitDrop applies no digital gain. Use the volume keys.',
                  VolumeMode.softwareDithered =>
                    'Digital gain is applied before output.',
                  VolumeMode.system => 'Android controls the level.',
                },
                color: path.volume == VolumeMode.dacHardware
                    ? c.tierBitPerfect
                    : c.textSecondary,
              ),
              SignalNode(
                icon: Icons.output,
                label: 'Output',
                detail: switch (path.tier) {
                  OutputTier.bitPerfect => 'Bit-perfect USB',
                  OutputTier.nativeRate => 'Native rate',
                  OutputTier.resampled =>
                    'Android mixer → ${Fmt.kHz(path.actual.sampleRate)}',
                  OutputTier.unknown => 'Unknown',
                },
                secondary: path.formatsMatch
                    ? 'Requested format matched exactly.'
                    : 'Requested ${path.requested.shortLabel}, '
                        'got ${path.actual.shortLabel}.',
                color: tierColor,
                highlighted: !path.formatsMatch,
              ),
              SignalNode(
                icon: switch (device?.type) {
                  DeviceType.usb => Icons.usb,
                  DeviceType.bluetooth => Icons.bluetooth,
                  DeviceType.phoneSpeaker => Icons.smartphone,
                  DeviceType.wiredAnalog => Icons.headphones,
                  _ => Icons.devices_other,
                },
                label: 'Device',
                detail: device == null
                    ? 'No device'
                    : '${device.name}'
                        '${device.connectionLabel == null ? '' : ' · ${device.connectionLabel}'}',
                secondary: device == null
                    ? null
                    : 'Supports ${device.supportedRates.map(Fmt.kHzBare).join(', ')} kHz · '
                        '${device.bitDepths.join('/')}-bit · '
                        'Hardware volume: ${switch (device.hardwareVolume) {
                        HardwareVolume.yes => 'Yes',
                        HardwareVolume.no => 'No',
                        HardwareVolume.unknown => 'Unknown',
                      }}',
                color: c.textSecondary,
                isLast: true,
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.md),
        _RequestedVsActual(path: path),
        if (showActions) ...[
          const SizedBox(height: Spacing.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            child: Wrap(
              spacing: Spacing.xs,
              runSpacing: Spacing.xs,
              children: [
                if (path.dspActive && onTurnOffEq != null)
                  OutlinedButton.icon(
                    onPressed: onTurnOffEq,
                    icon: const Icon(Icons.block, size: 16),
                    label: const Text('Turn off EQ for bit-perfect'),
                  ),
                if (onRunSafetyCheck != null)
                  OutlinedButton.icon(
                    onPressed: onRunSafetyCheck,
                    icon: const Icon(Icons.hearing, size: 16),
                    label: const Text('Run safety check'),
                  ),
                if (onOpenDiagnostics != null)
                  OutlinedButton.icon(
                    onPressed: onOpenDiagnostics,
                    icon: const Icon(Icons.monitor_heart_outlined, size: 16),
                    label: const Text('Open diagnostics'),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _VerdictBanner extends StatelessWidget {
  const _VerdictBanner({required this.path, required this.color});

  final SignalPath path;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final detail = path.tier == OutputTier.resampled
        ? '${Fmt.kHzBare(path.source.sampleRate)} → '
            '${Fmt.kHz(path.actual.sampleRate)}'
        : path.actual.shortLabel;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: Spacing.md),
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: Radii.cardR,
        border: Border.all(color: color.withOpacity(0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(TierChip.iconFor(path.tier), size: 18, color: color),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: Text(
                  path.tier.label,
                  style: context.t.titleSmall.copyWith(color: color),
                ),
              ),
              Text(detail, style: context.t.monoReadout.copyWith(color: color)),
              if (path.dspActive) ...[
                const SizedBox(width: Spacing.xs),
                const DspBadge(dense: true),
              ],
            ],
          ),
          const SizedBox(height: Spacing.xs),
          // Plain-language reason, written by the core.
          Text(
            path.explanation,
            style: context.t.bodySmall.copyWith(color: c.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Expandable expert view: what we asked for next to what we got.
class _RequestedVsActual extends StatefulWidget {
  const _RequestedVsActual({required this.path});

  final SignalPath path;

  @override
  State<_RequestedVsActual> createState() => _RequestedVsActualState();
}

class _RequestedVsActualState extends State<_RequestedVsActual> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final p = widget.path;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: Radii.chipR,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
              child: Row(
                children: [
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      size: 20, color: c.textSecondary),
                  const SizedBox(width: Spacing.xs),
                  Text('Requested vs. actual', style: context.t.titleSmall),
                  const SizedBox(width: Spacing.xs),
                  if (!p.formatsMatch)
                    Icon(Icons.priority_high, size: 15, color: c.tierResampled),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: Motion.standard,
            crossFadeState:
                _open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Spacing.sm),
              decoration: BoxDecoration(
                color: c.surface2,
                borderRadius: Radii.chipR,
                border: Border.all(color: c.outline),
              ),
              child: Table(
                columnWidths: const {
                  0: FlexColumnWidth(1.3),
                  1: FlexColumnWidth(1),
                  2: FlexColumnWidth(1),
                },
                children: [
                  _row(context, '', 'Requested', 'Actual', header: true),
                  _row(context, 'Codec', p.requested.codec.label,
                      p.actual.codec.label),
                  _row(context, 'Bit depth', '${p.requested.bitDepth}-bit',
                      '${p.actual.bitDepth}-bit',
                      mismatch: p.requested.bitDepth != p.actual.bitDepth),
                  _row(context, 'Sample rate', Fmt.kHz(p.requested.sampleRate),
                      Fmt.kHz(p.actual.sampleRate),
                      mismatch:
                          p.requested.sampleRate != p.actual.sampleRate),
                  _row(context, 'Channels', '${p.requested.channels}',
                      '${p.actual.channels}'),
                  _row(context, 'Volume', '—',
                      switch (p.volume) {
                        VolumeMode.dacHardware => 'DAC',
                        VolumeMode.softwareDithered => 'Software',
                        VolumeMode.system => 'System',
                      }),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  TableRow _row(
    BuildContext context,
    String label,
    String requested,
    String actual, {
    bool header = false,
    bool mismatch = false,
  }) {
    final c = context.c;
    final style = header
        ? context.t.monoLabel.copyWith(color: c.textSecondary)
        : context.t.monoReadout;
    return TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Text(
            header ? label : label,
            style: context.t.bodySmall.copyWith(color: c.textSecondary),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Text(requested, style: style),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Text(
                actual,
                style: mismatch ? style.copyWith(color: c.tierResampled) : style,
              ),
              if (mismatch)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(Icons.swap_vert, size: 13, color: c.tierResampled),
                )
              else if (!header)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(Icons.check, size: 13, color: c.success),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

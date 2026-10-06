import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core_api/enums.dart';
import '../../providers/core_providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../../widgets/indicators.dart';
import '../../widgets/meters.dart';

/// Live engine telemetry for power users.
///
/// Every number here is measured, not inferred — this is the screen that
/// backs up the claims the rest of the app makes.
class DiagnosticsScreen extends ConsumerWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(diagnosticsProvider).valueOrNull;
    final signal = ref.watch(signalPathProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics')),
      body: d == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                  Spacing.md, Spacing.xs, Spacing.md, Spacing.xxl),
              children: [
                _Card(
                  title: 'Output',
                  trailing: TierChip(tier: d.tier, dense: true),
                  rows: [
                    ('Requested', d.requested.badgeLabel),
                    ('Actual', d.actual.badgeLabel),
                    ('Device', d.deviceName),
                    (
                      'Volume',
                      switch (signal?.volume) {
                        VolumeMode.dacHardware => 'DAC hardware',
                        VolumeMode.softwareDithered => 'Software, dithered',
                        VolumeMode.system => 'System',
                        null => '—',
                      }
                    ),
                  ],
                  warning: signal != null && !signal.formatsMatch
                      ? 'The negotiated format differs from the request.'
                      : null,
                ),
                _Card(
                  title: 'Buffer',
                  rows: [
                    (
                      'Decodable ahead',
                      '${d.bufferAheadSeconds.toStringAsFixed(1)} s'
                    ),
                    (
                      'PCM ring fill',
                      '${d.pcmFillPercent.toStringAsFixed(0)}%'
                    ),
                    ('Underruns', '${d.underrunCount}'),
                  ],
                  sparkline: d.bufferHistory,
                  warning: d.underrunCount > 0
                      ? '${d.underrunCount} underrun'
                          '${d.underrunCount == 1 ? '' : 's'} this session. '
                          'Audio was interrupted.'
                      : null,
                ),
                _Card(
                  title: 'Network',
                  rows: [
                    ('Throughput', Fmt.mbps(d.speedMbps)),
                    ('Time to first byte', '${d.timeToFirstByteMs} ms'),
                    ('Active range requests', '${d.activeRangeRequests}'),
                    (
                      'Requests / min',
                      '${d.requestsPerMinute} of ${Fmt.count(d.requestBudgetPerMinute)}'
                    ),
                    ('Downloaded', Fmt.bytes(d.bytesDownloaded)),
                  ],
                  sparkline: d.throughputHistory,
                  warning: d.lastError,
                ),
                _Card(
                  title: 'Cache',
                  rows: [
                    ('Hit rate', Fmt.percent(d.cacheHitRate)),
                    ('On disk', Fmt.bytes(d.cacheSizeBytes)),
                    ('Current file', '${d.currentFileCachedPercent}%'),
                  ],
                ),
                _Card(
                  title: 'Decoder',
                  rows: [
                    ('Format', d.requested.badgeLabel),
                    (
                      'Decode load',
                      '${d.decodeLoadPercent.toStringAsFixed(1)}%'
                    ),
                    ('Source bitrate', Fmt.kbps(d.requested.bitrateKbps)),
                  ],
                ),
                const SizedBox(height: Spacing.sm),
                Text(
                  'Values update once a second. Exporting a report from '
                  'Settings strips file names, folder names and tags.',
                  style: context.t.bodySmall
                      .copyWith(color: context.c.textSecondary),
                ),
              ],
            ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.title,
    required this.rows,
    this.trailing,
    this.sparkline,
    this.warning,
  });

  final String title;
  final List<(String, String)> rows;
  final Widget? trailing;
  final List<double>? sparkline;
  final String? warning;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      margin: const EdgeInsets.only(bottom: Spacing.sm),
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: Radii.cardR,
        border: Border.all(color: c.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: context.t.monoLabel.copyWith(color: c.accent),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: Spacing.xs),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style:
                          context.t.bodySmall.copyWith(color: c.textSecondary),
                    ),
                  ),
                  Text(value, style: context.t.monoReadout),
                ],
              ),
            ),
          if (sparkline != null && sparkline!.length > 1) ...[
            const SizedBox(height: Spacing.xs),
            Sparkline(values: sparkline!),
          ],
          if (warning != null) ...[
            const SizedBox(height: Spacing.xs),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 14, color: c.tierResampled),
                const SizedBox(width: Spacing.xxs),
                Expanded(
                  child: Text(
                    warning!,
                    style: context.t.bodySmall.copyWith(color: c.tierResampled),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

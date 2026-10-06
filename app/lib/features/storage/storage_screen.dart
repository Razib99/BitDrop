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
import '../../widgets/common.dart';
import '../../widgets/meters.dart';

/// Offline & Storage: what is on the device, what is downloading, and the
/// rules for when BitDrop is allowed to use data.
class StorageScreen extends ConsumerWidget {
  const StorageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storage = ref.watch(storageProvider).valueOrNull;
    final c = context.c;
    final l = context.l10n;

    if (storage == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Offline & storage')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Offline & storage')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Spacing.xxl),
        children: [
          if (storage.nearlyFull)
            StatusBanner(
              kind: BannerKind.warning,
              message: 'Only ${Fmt.bytes(storage.freeBytes)} free. Pinning is '
                  'paused until there is room.',
              actionLabel: 'Clear cache',
              onAction: () => _confirmClear(context, ref, storage),
            ),
          Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: StorageBar(
              totalBytes: storage.totalBytes,
              segments: [
                (label: 'Pinned', bytes: storage.pinnedBytes, color: c.success),
                (label: 'Cache', bytes: storage.cacheBytes, color: c.accent),
                (
                  label: 'Artwork',
                  bytes: storage.artworkBytes,
                  color: c.tierNativeRate
                ),
                (
                  label: 'Database',
                  bytes: storage.databaseBytes,
                  color: c.tierResampled
                ),
              ],
            ),
          ),
          const SectionHeader(
            title: 'Cache',
            subtitle: 'Compressed audio kept on disk so playback survives a '
                'bad network. Evicted oldest-first.',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('Cache limit', style: context.t.body),
                    const Spacer(),
                    Text(
                      Fmt.bytes(storage.cacheLimitBytes),
                      style: context.t.monoReadout,
                    ),
                  ],
                ),
                Semantics(
                  slider: true,
                  label: 'Cache limit',
                  value: Fmt.bytes(storage.cacheLimitBytes),
                  excludeSemantics: true,
                  child: Slider(
                    value: (storage.cacheLimitBytes / 1000000000)
                        .clamp(1, 64)
                        .toDouble(),
                    min: 1,
                    max: 64,
                    divisions: 63,
                    label:
                        '${(storage.cacheLimitBytes / 1000000000).round()} GB',
                    onChanged: (v) => sendCommand(
                      ref,
                      SetCacheLimit((v * 1000000000).round()),
                    ),
                  ),
                ),
                Text(
                  'Using ${Fmt.bytes(storage.cacheBytes)} of '
                  '${Fmt.bytes(storage.cacheLimitBytes)}',
                  style: context.t.bodySmall.copyWith(color: c.textSecondary),
                ),
                const SizedBox(height: Spacing.xs),
                OutlinedButton.icon(
                  onPressed: () => _confirmClear(context, ref, storage),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('Clear cache'),
                ),
              ],
            ),
          ),
          if (storage.downloads.isNotEmpty) ...[
            const SectionHeader(title: 'Download queue'),
            for (final d in storage.downloads) _DownloadRow(job: d),
          ],
          SectionHeader(
            title: 'Pinned for offline',
            subtitle: '${storage.pinned.length} items · '
                '${Fmt.bytes(storage.pinnedBytes)} · never evicted',
          ),
          for (final p in storage.pinned)
            ListTile(
              leading: Icon(
                switch (p.kind) {
                  'Album' => Icons.album_outlined,
                  'Playlist' => Icons.queue_music,
                  _ => Icons.folder_outlined,
                },
                color: c.success,
              ),
              title: Text(p.title),
              subtitle: Text(p.subtitle),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(Fmt.bytes(p.sizeBytes),
                      style: context.t.monoReadout
                          .copyWith(color: c.textSecondary)),
                  IconButton(
                    tooltip: l.actionUnpin,
                    icon: const Icon(Icons.push_pin, size: 18),
                    color: c.success,
                    onPressed: () => sendCommand(
                      ref,
                      Unpin(id: p.id, kind: p.kind.toLowerCase()),
                    ),
                  ),
                ],
              ),
            ),
          const SectionHeader(title: 'Data rules'),
          SwitchListTile(
            value: storage.wifiOnlyDownloads,
            onChanged: (v) =>
                sendCommand(ref, SetSetting(key: 'scanWifiOnly', value: v)),
            secondary: const Icon(Icons.wifi),
            title: const Text('Download only on Wi-Fi'),
            subtitle: const Text(
              'Pinning waits for Wi-Fi. Streaming is controlled separately.',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.signal_cellular_alt),
            title: const Text('Pin over mobile data'),
            subtitle: const Text('What to do when you pin while on data'),
            trailing: DropdownButton<MobileDataPolicy>(
              value: storage.mobilePinPolicy,
              underline: const SizedBox.shrink(),
              onChanged: (v) {
                if (v != null) {
                  sendCommand(
                      ref, SetSetting(key: 'mobileDataPolicy', value: v));
                }
              },
              items: const [
                DropdownMenuItem(
                    value: MobileDataPolicy.ask, child: Text('Ask')),
                DropdownMenuItem(
                    value: MobileDataPolicy.stream, child: Text('Allow')),
                DropdownMenuItem(
                    value: MobileDataPolicy.cachedOnly, child: Text('Never')),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClear(
    BuildContext context,
    WidgetRef ref,
    StorageState storage,
  ) async {
    final ok = await ConfirmDialog.show(
      context,
      title: 'Clear cache?',
      message: 'Frees ${Fmt.bytes(storage.cacheBytes)}. Pinned music stays '
          'on your device. Anything else will stream again next time.',
      confirmLabel: 'Clear cache',
    );
    if (ok) sendCommand(ref, const ClearCache());
  }
}

class _DownloadRow extends ConsumerWidget {
  const _DownloadRow({required this.job});

  final DownloadJob job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: Spacing.md, vertical: Spacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(job.title, style: context.t.body),
                const SizedBox(height: Spacing.xxs),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: SizedBox(
                    height: 4,
                    child: LinearProgressIndicator(
                      value: job.progress,
                      backgroundColor: c.surface3,
                      color: job.paused ? c.textTertiary : c.accent,
                    ),
                  ),
                ),
                const SizedBox(height: Spacing.xxs),
                Text(
                  job.paused
                      ? 'Paused · ${Fmt.percent(job.progress)} of '
                          '${Fmt.bytes(job.sizeBytes)}'
                      : '${Fmt.percent(job.progress)} of '
                          '${Fmt.bytes(job.sizeBytes)}',
                  style: context.t.monoLabel.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: job.paused ? 'Resume' : 'Pause',
            icon: Icon(job.paused ? Icons.play_arrow : Icons.pause),
            onPressed: () => sendCommand(
              ref,
              PauseDownload(jobId: job.id, paused: !job.paused),
            ),
          ),
        ],
      ),
    );
  }
}

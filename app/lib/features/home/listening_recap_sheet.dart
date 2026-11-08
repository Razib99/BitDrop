import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core_api/models.dart';
import '../../providers/core_providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

/// Shows the Audiophile Listening Recap bottom sheet.
Future<void> showListeningRecapSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const ListeningRecapSheet(),
  );
}

class ListeningRecapSheet extends ConsumerWidget {
  const ListeningRecapSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final recapAsync = ref.watch(listeningRecapProvider);
    final height = MediaQuery.sizeOf(context).height;

    return Container(
      constraints: BoxConstraints(maxHeight: height * 0.88),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: c.outline, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: Spacing.sm),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: c.outline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.md,
                Spacing.sm,
                Spacing.md,
                Spacing.xs,
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(Spacing.xs),
                    decoration: BoxDecoration(
                      color: c.accent.withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.insights, size: 20, color: c.accent),
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Audiophile Listening Recap',
                            style: context.t.title),
                        Text(
                          'On-device SQLite playback telemetry',
                          style: context.t.bodySmall
                              .copyWith(color: c.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: recapAsync.when(
                loading: () => const Center(
                  child: Padding(
                    padding: EdgeInsets.all(Spacing.xl),
                    child: CircularProgressIndicator(),
                  ),
                ),
                error: (err, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(Spacing.xl),
                    child: Text(
                      'Failed to compute listening recap: $err',
                      style: TextStyle(color: c.error),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                data: (recap) {
                  if (recap == null || recap.totalPlays == 0) {
                    return _EmptyRecapView(onExport: () => _export(context, ref));
                  }
                  return _RecapContentView(
                    recap: recap,
                    onExport: () => _export(context, ref),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    try {
      final json = await ref.read(coreProvider).exportBackup();
      await Clipboard.setData(ClipboardData(text: json));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Backup copied to clipboard! (bitdrop_backup.json)',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to export backup: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }
}

class _EmptyRecapView extends StatelessWidget {
  const _EmptyRecapView({required this.onExport});

  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Spacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: Spacing.lg),
          Icon(Icons.headphones_outlined, size: 54, color: c.textSecondary),
          const SizedBox(height: Spacing.md),
          Text('No listening history yet', style: context.t.title),
          const SizedBox(height: Spacing.xs),
          Text(
            'BitDrop logs playback history directly to local SQLite whenever you listen to a track for 30 seconds or more. Play your favorite tunes to see your listening metrics!',
            textAlign: TextAlign.center,
            style: context.t.body.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: Spacing.xl),
          OutlinedButton.icon(
            onPressed: onExport,
            icon: const Icon(Icons.file_download_outlined),
            label: const Text('Export bitdrop_backup.json'),
          ),
          const SizedBox(height: Spacing.lg),
        ],
      ),
    );
  }
}

class _RecapContentView extends StatelessWidget {
  const _RecapContentView({required this.recap, required this.onExport});

  final ListeningRecap recap;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final hours = recap.totalMinutesListened ~/ 60;
    final mins = recap.totalMinutesListened % 60;
    final timeStr = hours > 0 ? '$hours h $mins m' : '$mins min';

    return ListView(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      children: [
        // 4 Key Metric Cards
        Row(
          children: [
            Expanded(
              child: _MetricCard(
                icon: Icons.timer_outlined,
                iconColor: c.accent,
                label: 'TOTAL LISTENING',
                value: timeStr,
                subtext: '${recap.totalPlays} qualified plays',
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: _MetricCard(
                icon: Icons.diamond_outlined,
                iconColor: c.tierBitPerfect,
                label: 'LOSSLESS %',
                value: '${recap.losslessPercentage.toStringAsFixed(1)}%',
                subtext: '${recap.hiResPercentage.toStringAsFixed(1)}% Hi-Res',
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.sm),
        Row(
          children: [
            Expanded(
              child: _MetricCard(
                icon: Icons.category_outlined,
                iconColor: c.tierNativeRate,
                label: 'TOP GENRE',
                value: (recap.topGenre != null && recap.topGenre!.isNotEmpty)
                    ? recap.topGenre!
                    : 'Eclectic',
                subtext: 'Most played category',
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: _MetricCard(
                icon: Icons.graphic_eq,
                iconColor: c.dspActive,
                label: 'HI-RES SHARE',
                value: '${recap.hiResPercentage.toStringAsFixed(1)}%',
                subtext: 'Above 48kHz / 24-bit',
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.lg),

        // Top Tracks
        if (recap.topTracks.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
            child: Row(
              children: [
                const Icon(Icons.music_note, size: 16),
                const SizedBox(width: Spacing.xs),
                Text('TOP TRACKS', style: context.t.monoLabel),
              ],
            ),
          ),
          const SizedBox(height: Spacing.xs),
          Container(
            decoration: BoxDecoration(
              color: c.surface2,
              borderRadius: Radii.cardR,
              border: Border.all(color: c.outline),
            ),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: recap.topTracks.length,
              separatorBuilder: (_, __) =>
                  Divider(height: 1, indent: 48, color: c.outline),
              itemBuilder: (context, i) {
                final track = recap.topTracks[i];
                return ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 12,
                    backgroundColor: i == 0
                        ? c.accent
                        : (i == 1 ? c.tierBitPerfect : c.surface1),
                    child: Text(
                      '${i + 1}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: (i == 0 || i == 1) ? Colors.black : c.textSecondary,
                      ),
                    ),
                  ),
                  title: Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.body.copyWith(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.bodySmall.copyWith(color: c.textSecondary),
                  ),
                  trailing: Text(
                    '${track.playCount} plays · ${track.totalMinutes}m',
                    style: context.t.monoLabel.copyWith(color: c.textSecondary),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: Spacing.lg),
        ],

        // Top Artists
        if (recap.topArtists.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
            child: Row(
              children: [
                const Icon(Icons.person, size: 16),
                const SizedBox(width: Spacing.xs),
                Text('TOP ARTISTS', style: context.t.monoLabel),
              ],
            ),
          ),
          const SizedBox(height: Spacing.xs),
          Container(
            decoration: BoxDecoration(
              color: c.surface2,
              borderRadius: Radii.cardR,
              border: Border.all(color: c.outline),
            ),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: recap.topArtists.length,
              separatorBuilder: (_, __) =>
                  Divider(height: 1, indent: 48, color: c.outline),
              itemBuilder: (context, i) {
                final artist = recap.topArtists[i];
                return ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 12,
                    backgroundColor: i == 0
                        ? c.accent
                        : (i == 1 ? c.tierBitPerfect : c.surface1),
                    child: Text(
                      '${i + 1}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: (i == 0 || i == 1) ? Colors.black : c.textSecondary,
                      ),
                    ),
                  ),
                  title: Text(
                    artist.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.body.copyWith(fontWeight: FontWeight.w600),
                  ),
                  trailing: Text(
                    '${artist.playCount} plays · ${artist.totalMinutes}m',
                    style: context.t.monoLabel.copyWith(color: c.textSecondary),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: Spacing.xl),
        ],

        // 1-Tap Export Button
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: Spacing.md),
              shape: const RoundedRectangleBorder(borderRadius: Radii.cardR),
            ),
            onPressed: onExport,
            icon: const Icon(Icons.file_download_outlined),
            label: const Text('1-Tap Export bitdrop_backup.json'),
          ),
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          'Exports preferences, EQ presets, device mappings, and listening telemetry into a single portable JSON file.',
          textAlign: TextAlign.center,
          style: context.t.bodySmall.copyWith(color: c.textSecondary),
        ),
        const SizedBox(height: Spacing.lg),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    required this.subtext,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;
  final String subtext;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: Radii.cardR,
        border: Border.all(color: c.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: iconColor),
              const SizedBox(width: Spacing.xxs),
              Expanded(
                child: Text(
                  label,
                  style: context.t.monoLabel.copyWith(
                    fontSize: 10,
                    color: c.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            value,
            style: context.t.title.copyWith(fontSize: 19),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            subtext,
            style: context.t.bodySmall.copyWith(
              fontSize: 11,
              color: c.textSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core_api/enums.dart';
import '../../core_api/models.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../../widgets/common.dart';
import '../../widgets/indicators.dart';

Future<void> showTrackInfoSheet(BuildContext context, Track track) =>
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => TrackInfoSheet(track: track),
    );

/// Everything the engine knows about this file.
///
/// "Copy details" produces a share-safe block: format and timings only, never
/// the Drive path, because that leaks folder names.
class TrackInfoSheet extends StatelessWidget {
  const TrackInfoSheet({super.key, required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return BottomSheetScaffold(
      title: track.title,
      subtitle: '${track.artist} · ${track.albumTitle}',
      actions: [
        IconButton(
          tooltip: 'Copy details',
          icon: const Icon(Icons.copy_all_outlined),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: _shareSafeText()));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Copied. File names and folders are left out.'),
              ),
            );
          },
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: Spacing.xs,
              runSpacing: Spacing.xs,
              children: [
                FormatBadge(format: track.format),
                AvailabilityGlyph(
                  availability: track.availability,
                  cachedPercent: track.cachedPercent,
                  showCloudOnly: true,
                ),
              ],
            ),
            const SizedBox(height: Spacing.md),
            _InfoRow('Codec', track.format.codec.label),
            _InfoRow('Bit depth', '${track.format.bitDepth}-bit'),
            _InfoRow('Sample rate', Fmt.kHz(track.format.sampleRate)),
            _InfoRow('Channels', '${track.format.channels}'),
            _InfoRow('Bitrate', Fmt.kbps(track.format.bitrateKbps)),
            _InfoRow('Duration', Fmt.duration(track.durationMs)),
            _InfoRow('File size', Fmt.bytes(track.sizeBytes)),
            if (track.replayGainDb != null)
              _InfoRow('ReplayGain (track)', Fmt.db(track.replayGainDb!)),
            _InfoRow(
              'Availability',
              AvailabilityGlyph.describe(
                  context, track.availability, track.cachedPercent),
            ),
            if (track.year != null) _InfoRow('Year', '${track.year}'),
            if (track.genre != null) _InfoRow('Genre', track.genre!),
            const SizedBox(height: Spacing.sm),
            Text('Source', style: context.t.monoLabel.copyWith(color: c.accent)),
            const SizedBox(height: Spacing.xxs),
            Text(
              track.folderPath,
              style: context.t.bodySmall.copyWith(color: c.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  String _shareSafeText() => [
        track.title,
        '${track.artist} — ${track.albumTitle}',
        '${track.format.codec.label} ${track.format.longLabel}',
        '${Fmt.kbps(track.format.bitrateKbps)} · '
            '${Fmt.duration(track.durationMs)} · ${Fmt.bytes(track.sizeBytes)}',
      ].join('\n');
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            SizedBox(
              width: 140,
              child: Text(
                label,
                style: context.t.bodySmall
                    .copyWith(color: context.c.textSecondary),
              ),
            ),
            Expanded(child: Text(value, style: context.t.monoReadout)),
          ],
        ),
      );
}

Future<void> showLyricsSheet(BuildContext context, Track track) =>
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => BottomSheetScaffold(
        title: 'Lyrics',
        subtitle: '${track.title} · embedded in the file',
        child: Padding(
          padding: const EdgeInsets.all(Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Embedded only — BitDrop has no servers to look lyrics up from.
              Text(
                _placeholderLyrics,
                style: context.t.body.copyWith(height: 1.8),
              ),
              const SizedBox(height: Spacing.md),
              Text(
                'Lyrics come from the file itself. BitDrop never looks them '
                'up online.',
                style: context.t.bodySmall
                    .copyWith(color: context.c.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );

const _placeholderLyrics = '''
Low water in the harbour,
lights across the bay.

Counting out the hours
until the ferry turns away.

Salt on the breakwater,
glass on the stone.

Everything that carried us
is carrying us home.''';

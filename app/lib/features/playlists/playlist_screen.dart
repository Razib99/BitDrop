import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core_api/commands.dart';
import '../../core_api/enums.dart';
import '../../core_api/models.dart';
import '../../core_api/queries.dart';
import '../../l10n/l10n.dart';
import '../../providers/core_providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../../widgets/artwork.dart';
import '../../widgets/common.dart';
import '../../widgets/indicators.dart';
import '../../widgets/rows.dart';

/// Playlist detail. Mirrors the album screen so the two feel the same.
class PlaylistScreen extends ConsumerWidget {
  const PlaylistScreen({super.key, required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistsProvider).valueOrNull ?? const [];
    final playlist = playlists
        .cast<Playlist?>()
        .firstWhere((p) => p!.id == playlistId, orElse: () => null);
    final tracksAsync =
        ref.watch(tracksProvider(TrackQuery(playlistId: playlistId)));
    final settings = ref.watch(settingsValueProvider);
    final l = context.l10n;

    if (playlist == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(
          icon: Icons.queue_music,
          title: 'Playlist not found',
        ),
      );
    }

    final tracks = tracksAsync.valueOrNull?.items ?? const <Track>[];
    final playable = tracks.where((t) => t.isPlayable).map((t) => t.id).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(playlist.name),
        actions: [
          IconButton(
            tooltip: playlist.availability == Availability.pinned
                ? l.actionUnpin
                : l.actionPinOffline,
            icon: Icon(
              playlist.availability == Availability.pinned
                  ? Icons.push_pin
                  : Icons.push_pin_outlined,
            ),
            onPressed: () => sendCommand(
              ref,
              playlist.availability == Availability.pinned
                  ? Unpin(id: playlist.id, kind: 'playlist')
                  : Pin(id: playlist.id, kind: 'playlist'),
            ),
          ),
        ],
      ),
      body: tracks.isEmpty && tracksAsync.isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: Spacing.xxl),
              children: [
                Padding(
                  padding: const EdgeInsets.all(Spacing.md),
                  child: Row(
                    children: [
                      AlbumArtwork(
                        artwork: playlist.artwork,
                        size: 96,
                        title: playlist.name,
                      ),
                      const SizedBox(width: Spacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                if (playlist.isSmart)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 5),
                                    child: Icon(Icons.auto_awesome,
                                        size: 14,
                                        color: context.c.textSecondary),
                                  ),
                                Flexible(
                                  child: Text(playlist.name,
                                      style: context.t.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis),
                                ),
                              ],
                            ),
                            if (playlist.description != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                playlist.description!,
                                style: context.t.bodySmall
                                    .copyWith(color: context.c.textSecondary),
                              ),
                            ],
                            const SizedBox(height: Spacing.xs),
                            Text(
                              '${playlist.trackCount} tracks · '
                              '${Fmt.longDuration(playlist.durationMs)} · '
                              '${Fmt.bytes(playlist.sizeBytes)}',
                              style: context.t.monoReadout
                                  .copyWith(color: context.c.textSecondary),
                            ),
                            const SizedBox(height: Spacing.xs),
                            Row(
                              children: [
                                AvailabilityGlyph(
                                  availability: playlist.availability,
                                  showCloudOnly: true,
                                ),
                                const SizedBox(width: Spacing.xxs),
                                Text(
                                  AvailabilityGlyph.describe(
                                      context, playlist.availability),
                                  style: context.t.bodySmall
                                      .copyWith(color: context.c.textSecondary),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: Spacing.md),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: playable.isEmpty
                              ? null
                              : () => sendCommand(
                                    ref,
                                    PlayContext(
                                      contextId: playlist.id,
                                      trackIds: playable,
                                      contextLabel:
                                          'Playlist · ${playlist.name}',
                                    ),
                                  ),
                          icon: const Icon(Icons.play_arrow),
                          label: Text(l.actionPlay),
                        ),
                      ),
                      const SizedBox(width: Spacing.xs),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: playable.isEmpty
                              ? null
                              : () => sendCommand(
                                    ref,
                                    PlayContext(
                                      contextId: playlist.id,
                                      trackIds: playable,
                                      shuffle: true,
                                      contextLabel:
                                          'Playlist · ${playlist.name}',
                                    ),
                                  ),
                          icon: const Icon(Icons.shuffle),
                          label: Text(l.actionShuffle),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Spacing.xs),
                for (var i = 0; i < tracks.length; i++)
                  TrackRow(
                    track: tracks[i],
                    badgeVisibility: settings.formatBadges,
                    onTap: () => sendCommand(
                      ref,
                      PlayContext(
                        contextId: playlist.id,
                        trackIds: playable,
                        startIndex: i,
                        contextLabel: 'Playlist · ${playlist.name}',
                      ),
                    ),
                    onPlayNext: () =>
                        sendCommand(ref, PlayNext([tracks[i].id])),
                    onAddToQueue: () =>
                        sendCommand(ref, Enqueue([tracks[i].id])),
                  ),
              ],
            ),
    );
  }
}

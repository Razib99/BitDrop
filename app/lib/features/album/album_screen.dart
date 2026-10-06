import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core_api/commands.dart';
import '../../core_api/enums.dart';
import '../../core_api/models.dart';
import '../../core_api/queries.dart';
import '../../l10n/l10n.dart';
import '../../providers/core_providers.dart';
import '../../routing/routes.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../util/format.dart';
import '../../widgets/artwork.dart';
import '../../widgets/common.dart';
import '../../widgets/rows.dart';

/// Album detail: artwork header, a technical summary, and the track list
/// grouped by disc.
class AlbumScreen extends ConsumerWidget {
  const AlbumScreen({super.key, required this.albumId});

  final String albumId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albumAsync = ref.watch(albumProvider(albumId));
    final tracksAsync =
        ref.watch(tracksProvider(TrackQuery(albumId: albumId)));

    return Scaffold(
      body: albumAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline,
          title: 'Could not open this album',
          message: '$e',
        ),
        data: (album) {
          if (album == null) {
            return const EmptyState(
              icon: Icons.album_outlined,
              title: 'Album not found',
              message: 'It may have been removed from your Drive.',
            );
          }
          final tracks = tracksAsync.valueOrNull?.items ?? const <Track>[];
          return CustomScrollView(
            slivers: [
              _Header(album: album),
              SliverToBoxAdapter(child: _Summary(album: album)),
              SliverToBoxAdapter(
                  child: _Actions(album: album, tracks: tracks)),
              if (album.mixedFormats && album.formatVarianceNote != null)
                SliverToBoxAdapter(
                  child: StatusBanner(
                    kind: BannerKind.info,
                    icon: Icons.linear_scale,
                    message: album.formatVarianceNote!,
                  ),
                ),
              if (tracksAsync.isLoading)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(Spacing.xl),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                )
              else
                ..._trackSlivers(context, ref, album, tracks),
              SliverToBoxAdapter(child: _Footer(album: album)),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _trackSlivers(
    BuildContext context,
    WidgetRef ref,
    Album album,
    List<Track> tracks,
  ) {
    final settings = ref.watch(settingsValueProvider);
    final nowPlayingId = ref.watch(nowPlayingProvider).valueOrNull?.track.id;
    final ids = tracks.map((t) => t.id).toList();

    final discs = <int, List<Track>>{};
    for (final t in tracks) {
      discs.putIfAbsent(t.discNumber, () => []).add(t);
    }

    final slivers = <Widget>[];
    final multiDisc = discs.length > 1;
    for (final entry in discs.entries) {
      if (multiDisc) {
        slivers.add(SliverToBoxAdapter(
          child: SectionHeader(title: 'Disc ${entry.key}'),
        ));
      }
      slivers.add(
        SliverList.builder(
          itemCount: entry.value.length,
          itemBuilder: (context, i) {
            final t = entry.value[i];
            // Per-track badges only when the track differs from the album.
            final differs = t.format != album.format;
            return TrackRow(
              track: t,
              showTrackNumber: true,
              showAlbumLine: false,
              forceShowFormat: differs,
              badgeVisibility: settings.formatBadges,
              isPlaying: t.id == nowPlayingId,
              onTap: () => sendCommand(
                ref,
                PlayContext(
                  contextId: album.id,
                  trackIds: ids,
                  startIndex: ids.indexOf(t.id),
                  contextLabel: 'Album · ${album.title}',
                ),
              ),
              onPlayNext: () => sendCommand(ref, PlayNext([t.id])),
              onAddToQueue: () => sendCommand(ref, Enqueue([t.id])),
            );
          },
        ),
      );
    }
    return slivers;
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.album});

  final Album album;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final width = MediaQuery.sizeOf(context).width;
    final artSize = (width * 0.52).clamp(140.0, 260.0);
    final hsl = HSLColor.fromColor(Color(album.artwork.dominantColor));
    final dark = Theme.of(context).brightness == Brightness.dark;
    final tint = hsl
        .withSaturation((hsl.saturation * 0.5).clamp(0.0, 0.6))
        .withLightness(
            dark ? (hsl.lightness * 0.3).clamp(0.06, 0.16) : 0.92)
        .toColor();

    return SliverAppBar(
      pinned: true,
      expandedHeight: artSize + 150,
      backgroundColor: c.bg,
      flexibleSpace: FlexibleSpaceBar(
        background: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [tint, c.bg],
            ),
          ),
          child: SafeArea(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Hero(
                  tag: 'art-${album.id}',
                  child: AlbumArtwork(
                    artwork: album.artwork,
                    size: artSize.toDouble(),
                    title: album.title,
                    borderRadius: Radii.heroArtR,
                    dimmed: !album.format.codec.isSupported,
                  ),
                ),
                const SizedBox(height: Spacing.md),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: Spacing.md),
                  child: Column(
                    children: [
                      Text(
                        album.title,
                        style: context.t.headline,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: Spacing.xxs),
                      InkWell(
                        onTap: () =>
                            context.push(Routes.artist(album.artistId)),
                        borderRadius: Radii.badgeR,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          child: Text(
                            album.artist,
                            style: context.t.body.copyWith(color: c.accent),
                          ),
                        ),
                      ),
                      Text(
                        [
                          if (album.year != null) '${album.year}',
                          if (album.genre != null) album.genre!,
                        ].join(' · '),
                        style: context.t.bodySmall
                            .copyWith(color: c.textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Spacing.sm),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The mono technical line: `FLAC · 24-bit · 96 kHz · 12 tracks · 1.42 GB`.
class _Summary extends StatelessWidget {
  const _Summary({required this.album});

  final Album album;

  @override
  Widget build(BuildContext context) {
    final parts = [
      album.format.codec.label,
      '${album.format.bitDepth}-bit',
      Fmt.kHz(album.format.sampleRate),
      '${album.trackCount} tracks',
      Fmt.bytes(album.sizeBytes),
      Fmt.duration(album.durationMs),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: Spacing.md, vertical: Spacing.xs),
      child: Center(
        child: Text(
          parts.join(' · '),
          style: context.t.monoReadout.copyWith(color: context.c.textSecondary),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _Actions extends ConsumerWidget {
  const _Actions({required this.album, required this.tracks});

  final Album album;
  final List<Track> tracks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final l = context.l10n;
    final playable = tracks.where((t) => t.isPlayable).map((t) => t.id).toList();
    final pinned = album.availability == Availability.pinned;
    final downloading = album.availability == Availability.downloading;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          Spacing.md, Spacing.xs, Spacing.md, Spacing.xs),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: playable.isEmpty
                  ? null
                  : () => sendCommand(
                        ref,
                        PlayContext(
                          contextId: album.id,
                          trackIds: playable,
                          contextLabel: 'Album · ${album.title}',
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
                          contextId: album.id,
                          trackIds: playable,
                          shuffle: true,
                          contextLabel: 'Album · ${album.title}',
                        ),
                      ),
              icon: const Icon(Icons.shuffle),
              label: Text(l.actionShuffle),
            ),
          ),
          const SizedBox(width: Spacing.xs),
          // Download-for-offline shows its progress in place.
          Tooltip(
            message: pinned
                ? l.actionUnpin
                : 'Download for offline (${Fmt.bytes(album.sizeBytes)})',
            child: IconButton(
              onPressed: () => sendCommand(
                ref,
                pinned
                    ? Unpin(id: album.id, kind: 'album')
                    : Pin(id: album.id, kind: 'album'),
              ),
              icon: downloading
                  ? SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        value: album.downloadProgress,
                        strokeWidth: 2.5,
                        color: c.accent,
                        backgroundColor: c.outline,
                      ),
                    )
                  : Icon(
                      pinned ? Icons.push_pin : Icons.download_for_offline_outlined,
                      color: pinned ? c.success : null,
                    ),
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              switch (v) {
                case 'queue':
                  sendCommand(ref, Enqueue(playable));
                case 'artist':
                  context.push(Routes.artist(album.artistId));
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'queue', child: Text(l.actionAddToQueue)),
              PopupMenuItem(value: 'artist', child: Text(l.actionGoToArtist)),
            ],
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.album});

  final Album album;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          Spacing.md, Spacing.lg, Spacing.md, Spacing.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(color: c.outline),
          const SizedBox(height: Spacing.sm),
          _FooterRow(label: 'Total size', value: Fmt.bytes(album.sizeBytes)),
          _FooterRow(label: 'Source', value: album.folderPath),
          _FooterRow(
            label: 'Last modified',
            value: Fmt.relativeTime(album.lastModified),
          ),
        ],
      ),
    );
  }
}

class _FooterRow extends StatelessWidget {
  const _FooterRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 100,
              child: Text(
                label,
                style: context.t.bodySmall
                    .copyWith(color: context.c.textSecondary),
              ),
            ),
            Expanded(
              child: Text(value, style: context.t.bodySmall),
            ),
          ],
        ),
      );
}

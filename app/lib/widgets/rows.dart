import 'package:flutter/material.dart';

import '../core_api/enums.dart';
import '../core_api/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../util/format.dart';
import '../l10n/l10n.dart';
import 'artwork.dart';
import 'common.dart';
import 'indicators.dart';

/// Track row.
///
/// Swipe right queues the track next, swipe left appends it. Unsupported and
/// missing tracks stay visible but dimmed, are not swipeable, and explain
/// themselves in place — never hidden, per the unsupported-format policy.
class TrackRow extends StatelessWidget {
  const TrackRow({
    super.key,
    required this.track,
    this.onTap,
    this.onLongPress,
    this.onPlayNext,
    this.onAddToQueue,
    this.onMore,
    this.showArt = true,
    this.showTrackNumber = false,
    this.isPlaying = false,
    this.selected = false,
    this.selectionMode = false,
    this.badgeVisibility = BadgeVisibility.always,
    this.showAlbumLine = true,
    this.forceShowFormat = true,
  });

  final Track track;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onPlayNext;
  final VoidCallback? onAddToQueue;
  final VoidCallback? onMore;
  final bool showArt;

  /// Inside an album, the number replaces the artwork.
  final bool showTrackNumber;
  final bool isPlaying;
  final bool selected;
  final bool selectionMode;
  final BadgeVisibility badgeVisibility;
  final bool showAlbumLine;

  /// Album detail passes false and shows a badge only when the track differs.
  final bool forceShowFormat;

  bool get _blocked =>
      track.availability == Availability.unsupported ||
      track.availability == Availability.missing;

  @override
  Widget build(BuildContext context) {
    final row = _buildRow(context);
    if (_blocked || onPlayNext == null || onAddToQueue == null) return row;

    return Dismissible(
      key: ValueKey('swipe-${track.id}'),
      background: _SwipeAction(
        icon: Icons.playlist_play,
        label: context.l10n.actionPlayNext,
        alignment: Alignment.centerLeft,
      ),
      secondaryBackground: _SwipeAction(
        icon: Icons.queue_music,
        label: context.l10n.actionAddToQueue,
        alignment: Alignment.centerRight,
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          onPlayNext!();
        } else {
          onAddToQueue!();
        }
        // Never actually remove the row — the swipe is a shortcut, not a delete.
        return false;
      },
      child: row,
    );
  }

  Widget _buildRow(BuildContext context) {
    final c = context.c;
    final t = context.t;
    final dim = _blocked || track.availability == Availability.unavailable;

    final titleColor =
        dim ? c.textTertiary : (isPlaying ? c.accent : c.textPrimary);

    return Semantics(
      selected: selectionMode ? selected : null,
      label: _semantics(context),
      excludeSemantics: true,
      button: true,
      child: InkWell(
        onTap: _blocked ? () => _explain(context) : onTap,
        onLongPress: onLongPress,
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md, vertical: Spacing.xs),
          color: selected ? c.accent.withOpacity(0.12) : null,
          child: Row(
            children: [
              if (selectionMode)
                Padding(
                  padding: const EdgeInsets.only(right: Spacing.xs),
                  child: Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    color: selected ? c.accent : c.textTertiary,
                    size: 22,
                  ),
                )
              else if (showTrackNumber)
                SizedBox(
                  width: 28,
                  child: isPlaying
                      ? Icon(Icons.equalizer, size: 18, color: c.accent)
                      : Text(
                          '${track.trackNumber ?? '-'}',
                          style: t.monoReadout.copyWith(
                            color: dim ? c.textTertiary : c.textSecondary,
                          ),
                          textAlign: TextAlign.center,
                        ),
                )
              else if (showArt)
                AlbumArtwork(
                  artwork: track.artwork,
                  size: Sizes.trackArt,
                  title: track.albumTitle,
                  dimmed: dim,
                ),
              SizedBox(width: showTrackNumber ? Spacing.xs : Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (track.tagsPending)
                      const SkeletonLoader(width: 150, height: 14)
                    else
                      Text(
                        track.title,
                        style: t.body.copyWith(
                          color: titleColor,
                          fontWeight:
                              isPlaying ? FontWeight.w600 : FontWeight.w400,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    const SizedBox(height: 2),
                    if (_blocked)
                      Text(
                        track.availability == Availability.missing
                            ? context.l10n.removedFromDrive
                            : (track.unsupportedReason ??
                                context.l10n.formatNotSupported),
                        style: t.bodySmall.copyWith(color: c.textTertiary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    else if (showAlbumLine)
                      Text(
                        '${track.artist} · ${track.albumTitle}',
                        style: t.bodySmall.copyWith(
                          color: dim ? c.textTertiary : c.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: Spacing.xs),
              if (forceShowFormat)
                Padding(
                  padding: const EdgeInsets.only(right: Spacing.xs),
                  child: FormatBadge(
                    format: track.format,
                    compact: true,
                    visibility: badgeVisibility,
                  ),
                ),
              AvailabilityGlyph(
                availability: track.availability,
                cachedPercent: track.cachedPercent,
                downloadProgress: track.downloadProgress,
              ),
              const SizedBox(width: Spacing.xs),
              if (track.favorite)
                Padding(
                  padding: const EdgeInsets.only(right: Spacing.xxs),
                  child: Icon(Icons.favorite, size: 14, color: c.accent),
                ),
              SizedBox(
                width: 44,
                child: Text(
                  Fmt.duration(track.durationMs),
                  style: t.monoReadout.copyWith(
                    color: dim ? c.textTertiary : c.textSecondary,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
              if (onMore != null)
                IconButton(
                  onPressed: onMore,
                  icon: const Icon(Icons.more_vert, size: 20),
                  tooltip: context.l10n.actionMoreFor(track.title),
                  color: c.textSecondary,
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _explain(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        track.availability == Availability.missing
            ? context.l10n.missingExplain(track.title)
            : context.l10n.unsupportedExplain(
                track.unsupportedReason ?? context.l10n.formatNotSupported,
              ),
      ),
    ));
  }

  String _semantics(BuildContext context) {
    final parts = <String>[
      track.title,
      track.artist,
      track.format.badgeLabel,
      AvailabilityGlyph.describe(
          context, track.availability, track.cachedPercent),
      Fmt.duration(track.durationMs),
    ];
    if (isPlaying) parts.insert(0, context.l10n.nowPlayingLabel);
    return parts.join(', ');
  }
}

class _SwipeAction extends StatelessWidget {
  const _SwipeAction({
    required this.icon,
    required this.label,
    required this.alignment,
  });

  final IconData icon;
  final String label;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      color: c.accent.withOpacity(0.18),
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: c.accent),
          const SizedBox(width: Spacing.xs),
          Text(label, style: context.t.label.copyWith(color: c.accent)),
        ],
      ),
    );
  }
}

/// Album grid card: artwork, availability glyph, title, artist, format badge.
class AlbumCard extends StatelessWidget {
  const AlbumCard({
    super.key,
    required this.album,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.selectionMode = false,
    this.badgeVisibility = BadgeVisibility.always,
    this.compact = false,
  });

  final Album album;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final bool selectionMode;
  final BadgeVisibility badgeVisibility;
  final bool compact;

  /// Total height for a card of [width], including the text block.
  ///
  /// The caption grows with the user's text scale, so shelves and grids ask
  /// for this instead of assuming a fixed ratio — that is what keeps the
  /// 200% text check free of overflow.
  static double heightFor(
    BuildContext context,
    double width, {
    bool compact = false,
  }) {
    final scale = MediaQuery.textScalerOf(context).scale(1);
    // title 18 + gap 1 + artist 16 (+ gap 5 + format badge 20 when shown)
    final text = (compact ? 35.0 : 60.0) * scale;
    final gap = compact ? Spacing.xs : Spacing.xs + 2;
    return width + gap + text;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final dim = !album.format.codec.isSupported;

    return Semantics(
      label: '${album.title}, ${album.artist}, ${album.format.badgeLabel}, '
          '${AvailabilityGlyph.describe(context, album.availability)}',
      button: true,
      selected: selectionMode ? selected : null,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: Radii.cardR,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: LayoutBuilder(
                builder: (context, box) => Stack(
                  children: [
                    Positioned.fill(
                      child: AlbumArtwork(
                        artwork: album.artwork,
                        size: box.maxWidth,
                        title: album.title,
                        dimmed: dim,
                      ),
                    ),
                    if (selectionMode)
                      Positioned(
                        top: 6,
                        left: 6,
                        child: _Pill(
                          child: Icon(
                            selected
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            size: 16,
                            color: selected ? c.accent : Colors.white,
                          ),
                        ),
                      ),
                    if (album.availability != Availability.cloudOnly)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: _Pill(
                          child: AvailabilityGlyph(
                            availability: album.availability,
                            downloadProgress: album.downloadProgress,
                            size: 15,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SizedBox(height: compact ? Spacing.xs : Spacing.xs + 2),
            if (album.tagsPending)
              const SkeletonLoader(width: 110, height: 13)
            else
              Text(
                album.title,
                style: context.t.bodySmall.copyWith(
                  color: dim ? c.textTertiary : c.textPrimary,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            const SizedBox(height: 1),
            Text(
              album.artist,
              style: context.t.label.copyWith(color: c.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (!compact) ...[
              const SizedBox(height: Spacing.xxs + 1),
              FormatBadge(
                format: album.format,
                visibility: badgeVisibility,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.45),
          borderRadius: BorderRadius.circular(8),
        ),
        child: child,
      );
}

/// Album list row — the alternative to the grid.
class AlbumRow extends StatelessWidget {
  const AlbumRow({
    super.key,
    required this.album,
    this.onTap,
    this.onLongPress,
    this.badgeVisibility = BadgeVisibility.always,
  });

  final Album album;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final BadgeVisibility badgeVisibility;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final dim = !album.format.codec.isSupported;
    return Semantics(
      label: '${album.title}, ${album.artist}, ${album.trackCount} tracks, '
          '${album.format.badgeLabel}',
      button: true,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          constraints: const BoxConstraints(minHeight: 72),
          padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md, vertical: Spacing.xs),
          child: Row(
            children: [
              AlbumArtwork(
                artwork: album.artwork,
                size: 56,
                title: album.title,
                dimmed: dim,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      album.title,
                      style: context.t.body.copyWith(
                        color: dim ? c.textTertiary : c.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${album.artist} · ${album.year ?? '—'} · '
                      '${album.trackCount} tracks',
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
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FormatBadge(
                      format: album.format, visibility: badgeVisibility),
                  const SizedBox(height: Spacing.xxs),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AvailabilityGlyph(
                        availability: album.availability,
                        downloadProgress: album.downloadProgress,
                        size: 14,
                      ),
                      const SizedBox(width: Spacing.xxs),
                      Text(
                        Fmt.bytes(album.sizeBytes),
                        style: context.t.monoLabel
                            .copyWith(color: c.textSecondary),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ArtistTile extends StatelessWidget {
  const ArtistTile({super.key, required this.artist, this.onTap});

  final Artist artist;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      label: '${artist.name}, ${artist.albumCount} albums, '
          '${artist.trackCount} tracks',
      button: true,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md, vertical: Spacing.xs),
          child: Row(
            children: [
              ClipOval(
                child: AlbumArtwork(
                  artwork: artist.artwork,
                  size: 48,
                  title: artist.name,
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(artist.name,
                        style: context.t.body,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(
                      '${artist.albumCount} album'
                      '${artist.albumCount == 1 ? '' : 's'} · '
                      '${artist.trackCount} tracks',
                      style:
                          context.t.bodySmall.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: c.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

/// Folder or file row in the Drive browser.
class FolderRow extends StatelessWidget {
  const FolderRow({
    super.key,
    required this.entry,
    this.onTap,
    this.onPlay,
    this.onPin,
    this.badgeVisibility = BadgeVisibility.always,
  });

  final FolderEntry entry;
  final VoidCallback? onTap;
  final VoidCallback? onPlay;
  final VoidCallback? onPin;
  final BadgeVisibility badgeVisibility;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final track = entry.track;
    final dim = track != null && !track.format.codec.isSupported;

    return Semantics(
      label: entry.isDirectory
          ? 'Folder ${entry.name}, ${entry.itemCount} items, '
              '${Fmt.bytes(entry.sizeBytes)}'
          : '${entry.name}, ${track?.format.badgeLabel ?? ''}',
      button: true,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: Sizes.touchTarget + 8),
          padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md, vertical: Spacing.xs),
          child: Row(
            children: [
              Icon(
                entry.isDirectory
                    ? Icons.folder_outlined
                    : Icons.audio_file_outlined,
                color: dim ? c.textTertiary : c.textSecondary,
                size: 22,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      entry.name,
                      style: context.t.body.copyWith(
                        color: dim ? c.textTertiary : c.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.isDirectory
                          ? '${entry.itemCount} item'
                              '${entry.itemCount == 1 ? '' : 's'} · '
                              '${Fmt.bytes(entry.sizeBytes)}'
                          : '${Fmt.bytes(entry.sizeBytes)} · '
                              '${Fmt.duration(track?.durationMs ?? 0)}',
                      style:
                          context.t.bodySmall.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ),
              if (track != null)
                Padding(
                  padding: const EdgeInsets.only(right: Spacing.xs),
                  child: FormatBadge(
                    format: track.format,
                    compact: true,
                    visibility: badgeVisibility,
                  ),
                ),
              if (track != null)
                AvailabilityGlyph(
                  availability: track.availability,
                  cachedPercent: track.cachedPercent,
                ),
              if (entry.isDirectory && onPlay != null)
                IconButton(
                  onPressed: onPlay,
                  icon: const Icon(Icons.play_arrow, size: 20),
                  tooltip: context.l10n.playFolder,
                  color: c.textSecondary,
                  visualDensity: VisualDensity.compact,
                ),
              if (entry.isDirectory && onPin != null)
                IconButton(
                  onPressed: onPin,
                  icon: const Icon(Icons.push_pin_outlined, size: 18),
                  tooltip: context.l10n.pinFolder,
                  color: c.textSecondary,
                  visualDensity: VisualDensity.compact,
                ),
              if (entry.isDirectory && onPlay == null && onPin == null)
                Icon(Icons.chevron_right, color: c.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

/// Playlist row, shared by the Library tab and the Playlists screen.
class PlaylistRow extends StatelessWidget {
  const PlaylistRow({super.key, required this.playlist, this.onTap});

  final Playlist playlist;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      label: '${playlist.name}, ${playlist.trackCount} tracks, '
          '${Fmt.longDuration(playlist.durationMs)}',
      button: true,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md, vertical: Spacing.xs),
          child: Row(
            children: [
              AlbumArtwork(
                artwork: playlist.artwork,
                size: Sizes.trackArt,
                title: playlist.name,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        if (playlist.isSmart)
                          Padding(
                            padding: const EdgeInsets.only(right: 5),
                            child: Icon(Icons.auto_awesome,
                                size: 13, color: c.textSecondary),
                          ),
                        Flexible(
                          child: Text(
                            playlist.name,
                            style: context.t.body,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${playlist.trackCount} tracks · '
                      '${Fmt.longDuration(playlist.durationMs)} · '
                      '${Fmt.bytes(playlist.sizeBytes)}',
                      style:
                          context.t.bodySmall.copyWith(color: c.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              AvailabilityGlyph(availability: playlist.availability),
              const SizedBox(width: Spacing.xs),
              Icon(Icons.chevron_right, color: c.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

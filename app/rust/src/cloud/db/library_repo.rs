use crate::cloud::db::{
    AlbumSummaryRow, CloudTrackRow, FolderSummary, GenreSummary, ListeningRecap, RecapArtistItem,
    RecapTrackItem, ReplacedFile, TrackPlaceholder, TrackTagUpdate,
};
use crate::cloud::local_scanner::LocalTrackInfo;
use crate::cloud::lyrics::{LyricLine, TrackLyrics};
use rusqlite::{params, Connection, OptionalExtension, Result, Row};
use std::path::Path;

/// Repository for audio tracks, albums, artists, folders, genres, and metadata indexing.
pub struct LibraryRepository<'a> {
    pub conn: &'a Connection,
}

impl<'a> LibraryRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    #[inline]
    fn row_to_cloud_track(r: &Row) -> Result<CloudTrackRow> {
        let name: String = r.get(1)?;
        let title: Option<String> = r.get(3)?;
        Ok(CloudTrackRow {
            file_id: r.get(0)?,
            name: name.clone(),
            folder_path: r.get::<_, Option<String>>(2)?.unwrap_or_default(),
            title: title.filter(|t| !t.is_empty()).unwrap_or_else(|| {
                name.rsplit_once('.')
                    .map(|(s, _)| s.to_string())
                    .unwrap_or(name)
            }),
            artist: r.get::<_, Option<String>>(4)?.unwrap_or_default(),
            album: r.get::<_, Option<String>>(5)?.unwrap_or_default(),
            album_artist: r.get::<_, Option<String>>(6)?.unwrap_or_default(),
            genre: r.get::<_, Option<String>>(7)?.unwrap_or_default(),
            year: r.get::<_, Option<u32>>(8)?.unwrap_or(0),
            track_number: r.get::<_, Option<u32>>(9)?.unwrap_or(0),
            disc_number: r.get::<_, Option<u32>>(10)?.unwrap_or(1),
            duration_ms: r.get::<_, Option<u32>>(11)?.unwrap_or(0),
            sample_rate: r.get::<_, Option<u32>>(12)?.unwrap_or(0),
            channels: r.get::<_, Option<u32>>(13)?.unwrap_or(0),
            bits_per_sample: r.get::<_, Option<u32>>(14)?.unwrap_or(0),
            size_bytes: r.get::<_, Option<i64>>(15)?.unwrap_or(0) as u64,
            tags_read: r.get::<_, i64>(16)? != 0,
            artwork_path: r.get::<_, Option<String>>(17)?.unwrap_or_default(),
        })
    }

    /// Single placeholder insertion (backward compatible wrapper).
    pub fn insert_placeholder(
        &mut self,
        file_id: &str,
        name: &str,
        folder_path: &str,
        size_bytes: u64,
    ) -> Result<Vec<ReplacedFile>> {
        self.batch_insert_placeholders(&[TrackPlaceholder {
            file_id: file_id.to_string(),
            name: name.to_string(),
            folder_path: folder_path.to_string(),
            size_bytes,
        }])
    }

    /// Batched placeholder insertion within a single atomic transaction.
    ///
    /// If a track with the same (folder_path, name) already exists with a different
    /// file_id (e.g. re-uploaded or replaced on Google Drive), the old row is pruned
    /// and its ReplacedFile mapping is returned so the caller can migrate favorites, pinned state,
    /// and clean up cached sparse files.
    pub fn batch_insert_placeholders(
        &mut self,
        items: &[TrackPlaceholder],
    ) -> Result<Vec<ReplacedFile>> {
        let mut replaced_files = Vec::new();
        let tx = self.conn.unchecked_transaction()?;
        {
            let mut find_stmt = tx.prepare_cached(
                "SELECT file_id FROM tracks WHERE folder_path = ?1 AND name = ?2 AND file_id != ?3",
            )?;
            let mut del_stmt = tx.prepare_cached("DELETE FROM tracks WHERE file_id = ?1")?;
            let mut insert_stmt = tx.prepare_cached(
                "INSERT INTO tracks (file_id, name, folder_path, size_bytes, tags_read)
                 VALUES (?1, ?2, ?3, ?4, 0)
                 ON CONFLICT(file_id) DO UPDATE SET
                    name = excluded.name,
                    folder_path = excluded.folder_path,
                    size_bytes = excluded.size_bytes,
                    tags_read = CASE WHEN tracks.size_bytes != excluded.size_bytes THEN 0 ELSE tracks.tags_read END",
            )?;

            for item in items {
                let old_ids: Vec<String> = find_stmt
                    .query_map(params![&item.folder_path, &item.name, &item.file_id], |r| {
                        r.get(0)
                    })?
                    .filter_map(|r| r.ok())
                    .collect();

                for old_id in old_ids {
                    del_stmt.execute(params![&old_id])?;
                    replaced_files.push(ReplacedFile {
                        old_file_id: old_id,
                        new_file_id: item.file_id.clone(),
                    });
                }

                insert_stmt.execute(params![
                    item.file_id,
                    item.name,
                    item.folder_path,
                    item.size_bytes as i64
                ])?;
            }
        }
        tx.commit()?;

        if !replaced_files.is_empty() {
            self.rebuild_albums_summary()?;
        }

        Ok(replaced_files)
    }

    /// Batched insertion of local tracks with fully extracted metadata.
    ///
    /// Inserts or updates tracks, setting `tags_read = 1`, and rebuilds the
    /// albums summary table so UI grids immediately display the imported tracks.
    pub fn batch_insert_local_tracks(&mut self, items: &[LocalTrackInfo]) -> Result<()> {
        if items.is_empty() {
            return Ok(());
        }

        let tx = self.conn.unchecked_transaction()?;
        {
            let mut stmt = tx.prepare_cached(
                "INSERT INTO tracks (
                    file_id, name, folder_path, size_bytes, title, artist,
                    album, album_artist, genre, year, track_number, disc_number,
                    duration_ms, sample_rate, channels, bits_per_sample,
                    artwork_path, artwork_checked, tags_read
                 ) VALUES (
                    ?1, ?2, ?3, ?4, ?5, ?6,
                    ?7, ?8, ?9, ?10, ?11, ?12,
                    ?13, ?14, ?15, ?16,
                    ?17, ?18, 1
                 )
                 ON CONFLICT(file_id) DO UPDATE SET
                    name = excluded.name,
                    folder_path = excluded.folder_path,
                    size_bytes = excluded.size_bytes,
                    title = excluded.title,
                    artist = excluded.artist,
                    album = excluded.album,
                    album_artist = excluded.album_artist,
                    genre = excluded.genre,
                    year = excluded.year,
                    track_number = excluded.track_number,
                    disc_number = excluded.disc_number,
                    duration_ms = excluded.duration_ms,
                    sample_rate = excluded.sample_rate,
                    channels = excluded.channels,
                    bits_per_sample = excluded.bits_per_sample,
                    artwork_path = COALESCE(excluded.artwork_path, tracks.artwork_path),
                    artwork_checked = CASE WHEN excluded.artwork_path IS NOT NULL AND excluded.artwork_path != '' THEN 1 ELSE tracks.artwork_checked END,
                    tags_read = 1",
            )?;

            for item in items {
                let artwork_checked = if item
                    .artwork_path
                    .as_deref()
                    .map(|s| !s.is_empty())
                    .unwrap_or(false)
                {
                    1i64
                } else {
                    0i64
                };
                let sample_rate = if item.sample_rate > 0 {
                    Some(item.sample_rate as i64)
                } else {
                    None
                };
                let channels = if item.channels > 0 {
                    Some(item.channels as i64)
                } else {
                    None
                };
                let bits_per_sample = if item.bits_per_sample > 0 {
                    Some(item.bits_per_sample as i64)
                } else {
                    None
                };

                stmt.execute(params![
                    &item.path,
                    &item.name,
                    &item.folder_path,
                    item.size_bytes as i64,
                    &item.title,
                    &item.artist,
                    &item.album,
                    &item.album_artist,
                    &item.genre,
                    item.year.map(|y| y as i64),
                    item.track_number.map(|tn| tn as i64).unwrap_or(0),
                    item.disc_number.map(|dn| dn as i64).unwrap_or(1),
                    item.duration_ms as i64,
                    sample_rate,
                    channels,
                    bits_per_sample,
                    &item.artwork_path,
                    artwork_checked,
                ])?;
            }
        }
        tx.commit()?;

        self.rebuild_albums_summary()?;
        Ok(())
    }

    /// Prunes local tracks belonging to `root_label` whose underlying files
    /// no longer exist on the local filesystem.
    ///
    /// Returns the number of pruned tracks.
    pub fn prune_missing_local_tracks(&mut self, root_label: &str) -> Result<usize> {
        let like_pattern = format!("{} / %", root_label);
        let mut missing_ids = Vec::new();

        {
            let mut stmt = self.conn.prepare(
                "SELECT file_id FROM tracks WHERE folder_path = ?1 OR folder_path LIKE ?2",
            )?;
            let rows =
                stmt.query_map(params![root_label, like_pattern], |r| r.get::<_, String>(0))?;

            for id in rows.flatten() {
                if !Path::new(&id).exists() {
                    missing_ids.push(id);
                }
            }
        }

        if missing_ids.is_empty() {
            return Ok(0);
        }

        let count = missing_ids.len();
        let tx = self.conn.unchecked_transaction()?;
        {
            let mut del_stmt = tx.prepare_cached("DELETE FROM tracks WHERE file_id = ?1")?;
            for id in &missing_ids {
                del_stmt.execute(params![id])?;
            }
        }
        tx.commit()?;

        self.rebuild_albums_summary()?;
        Ok(count)
    }

    /// Batched tag update within a single transaction, updating both `tracks`
    /// and `albums_summary` atomically.
    pub fn batch_update_tags(&mut self, updates: &[TrackTagUpdate]) -> Result<()> {
        let tx = self.conn.unchecked_transaction()?;
        {
            let mut track_stmt = tx.prepare_cached(
                "UPDATE tracks SET
                    title = ?2, artist = ?3, album = ?4, album_artist = ?5,
                    genre = ?6, year = ?7, track_number = ?8, disc_number = ?9,
                    duration_ms = ?10, sample_rate = ?11, channels = ?12,
                    bits_per_sample = ?13, artwork_path = ?14,
                    artwork_checked = CASE WHEN ?14 IS NOT NULL AND ?14 != '' THEN 1 ELSE tracks.artwork_checked END,
                    tags_read = 1
                 WHERE file_id = ?1",
            )?;

            let mut album_stmt = tx.prepare_cached(
                "INSERT INTO albums_summary (
                    album_key, album, album_artist, year, artwork_path,
                    track_count, max_sample_rate, max_bit_depth
                 ) VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6, ?7)
                 ON CONFLICT(album_key) DO UPDATE SET
                    track_count = albums_summary.track_count + 1,
                    max_sample_rate = MAX(COALESCE(albums_summary.max_sample_rate, 0), excluded.max_sample_rate),
                    max_bit_depth = MAX(COALESCE(albums_summary.max_bit_depth, 0), excluded.max_bit_depth),
                    artwork_path = CASE WHEN albums_summary.artwork_path IS NULL OR albums_summary.artwork_path = ''
                                        THEN excluded.artwork_path ELSE albums_summary.artwork_path END,
                    year = CASE WHEN albums_summary.year IS NULL OR albums_summary.year = 0
                                THEN excluded.year ELSE albums_summary.year END",
            )?;

            for u in updates {
                track_stmt.execute(params![
                    u.file_id,
                    u.title,
                    u.artist,
                    u.album,
                    u.album_artist,
                    u.genre,
                    u.year,
                    u.track_number,
                    u.disc_number,
                    u.duration_ms,
                    u.sample_rate,
                    u.channels,
                    u.bits_per_sample,
                    u.artwork_path,
                ])?;

                let album_clean = if u.album.is_empty() {
                    "Unknown Album"
                } else {
                    &u.album
                };
                let artist_clean = if !u.album_artist.is_empty() {
                    &u.album_artist
                } else if !u.artist.is_empty() {
                    &u.artist
                } else {
                    "Unknown Artist"
                };
                let album_key = format!(
                    "{}::{}",
                    artist_clean.to_lowercase(),
                    album_clean.to_lowercase()
                );

                album_stmt.execute(params![
                    album_key,
                    album_clean,
                    artist_clean,
                    u.year,
                    u.artwork_path,
                    u.sample_rate,
                    u.bits_per_sample,
                ])?;
            }

            // Propagate album artwork to any tracks that lack it (primary: artist::album)
            let _ = tx.execute(
                "UPDATE tracks SET artwork_path = (
                    SELECT a.artwork_path FROM albums_summary a
                    WHERE a.album_key = lower(trim(CASE WHEN tracks.album_artist != '' THEN tracks.album_artist ELSE tracks.artist END)) || '::' || lower(trim(CASE WHEN tracks.album != '' THEN tracks.album ELSE 'unknown album' END))
                      AND a.artwork_path IS NOT NULL AND a.artwork_path != '' AND a.artwork_path NOT LIKE '%unknown_artist__unknown_album%'
                )
                WHERE (tracks.artwork_path IS NULL OR tracks.artwork_path = '' OR tracks.artwork_path LIKE '%unknown_artist__unknown_album%')
                  AND EXISTS (
                    SELECT 1 FROM albums_summary a
                    WHERE a.album_key = lower(trim(CASE WHEN tracks.album_artist != '' THEN tracks.album_artist ELSE tracks.artist END)) || '::' || lower(trim(CASE WHEN tracks.album != '' THEN tracks.album ELSE 'unknown album' END))
                      AND a.artwork_path IS NOT NULL AND a.artwork_path != '' AND a.artwork_path NOT LIKE '%unknown_artist__unknown_album%'
                  )",
                [],
            );

            // Secondary propagation by album title (e.g. soundtracks like Rockstar where different songs have different artists)
            let _ = tx.execute(
                "UPDATE tracks SET artwork_path = (
                    SELECT a.artwork_path FROM albums_summary a
                    WHERE lower(trim(a.album)) = lower(trim(tracks.album))
                      AND a.artwork_path IS NOT NULL AND a.artwork_path != '' AND a.artwork_path NOT LIKE '%unknown_artist__unknown_album%'
                    LIMIT 1
                )
                WHERE (tracks.artwork_path IS NULL OR tracks.artwork_path = '' OR tracks.artwork_path LIKE '%unknown_artist__unknown_album%')
                  AND tracks.album IS NOT NULL AND trim(tracks.album) != '' AND lower(trim(tracks.album)) != 'unknown album'
                  AND EXISTS (
                    SELECT 1 FROM albums_summary a
                    WHERE lower(trim(a.album)) = lower(trim(tracks.album))
                      AND a.artwork_path IS NOT NULL AND a.artwork_path != '' AND a.artwork_path NOT LIKE '%unknown_artist__unknown_album%'
                  )",
                [],
            );
        }
        tx.commit()?;
        self.rebuild_genres_index()?;
        Ok(())
    }

    /// Single track tag update (backward compatible wrapper).
    pub fn update_tags_single(&mut self, update: &TrackTagUpdate) -> Result<()> {
        self.batch_update_tags(std::slice::from_ref(update))
    }

    pub fn set_artwork(&self, file_id: &str, path: &str) -> Result<()> {
        self.conn.execute(
            "UPDATE tracks SET artwork_path = ?2, artwork_checked = 1 WHERE file_id = ?1",
            params![file_id, path],
        )?;
        Ok(())
    }

    /// Marks artwork as checked (negative caching) so repeated online searches are avoided.
    pub fn mark_artwork_checked(&self, file_id: &str) -> Result<()> {
        self.conn.execute(
            "UPDATE tracks SET artwork_checked = 1 WHERE file_id = ?1",
            params![file_id],
        )?;
        Ok(())
    }

    /// Returns whether artwork has already been checked for this track.
    pub fn is_artwork_checked(&self, file_id: &str) -> Result<bool> {
        let checked: Option<i64> = self
            .conn
            .query_row(
                "SELECT artwork_checked FROM tracks WHERE file_id = ?1",
                params![file_id],
                |r| r.get(0),
            )
            .optional()?;
        Ok(checked.unwrap_or(0) == 1)
    }

    /// Sub-3ms Ranked Multi-Field Search Query using External Content FTS5 and BM25.
    pub fn search_tracks_fts(&self, query: &str, limit: u32) -> Result<Vec<CloudTrackRow>> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return Ok(Vec::new());
        }

        // Sanitize and format terms into FTS5 prefix tokens:
        // "bill evans waltz" -> "\"bill\"* AND \"evans\"* AND \"waltz\"*"
        let terms: Vec<String> = trimmed
            .split_whitespace()
            .filter(|w| !w.is_empty())
            .map(|w| {
                let sanitized: String = w.chars().filter(|c| c.is_alphanumeric()).collect();
                if sanitized.is_empty() {
                    String::new()
                } else {
                    format!("\"{}\"*", sanitized)
                }
            })
            .filter(|s| !s.is_empty())
            .collect();

        if terms.is_empty() {
            return Ok(Vec::new());
        }

        let fts_query = terms.join(" AND ");

        let mut stmt = self.conn.prepare(
            "SELECT t.file_id, t.name, t.folder_path, t.title, t.artist, t.album,
                    t.album_artist, t.genre, t.year, t.track_number, t.disc_number,
                    t.duration_ms, t.sample_rate, t.channels, t.bits_per_sample,
                    t.size_bytes, t.tags_read, t.artwork_path
             FROM tracks_fts f
             JOIN tracks t ON t.rowid = f.rowid
             WHERE tracks_fts MATCH ?1
             ORDER BY bm25(tracks_fts, 10.0, 6.0, 4.0, 3.0, 1.0, 2.0)
             LIMIT ?2",
        )?;

        let rows = stmt.query_map(params![fts_query, limit], Self::row_to_cloud_track)?;

        rows.collect()
    }

    /// Lists all albums from the materialized `albums_summary` table in <1ms.
    pub fn list_albums_summary(&self) -> Result<Vec<AlbumSummaryRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT album_key, album, album_artist, year, artwork_path,
                    track_count, max_sample_rate, max_bit_depth
             FROM albums_summary
             ORDER BY album_artist COLLATE NOCASE, album COLLATE NOCASE",
        )?;

        let rows = stmt.query_map([], |r| {
            Ok(AlbumSummaryRow {
                album_key: r.get(0)?,
                album: r.get(1)?,
                album_artist: r.get(2)?,
                year: r.get::<_, Option<u32>>(3)?.unwrap_or(0),
                artwork_path: r.get::<_, Option<String>>(4)?.unwrap_or_default(),
                track_count: r.get::<_, Option<u32>>(5)?.unwrap_or(0),
                max_sample_rate: r.get::<_, Option<u32>>(6)?.unwrap_or(0),
                max_bit_depth: r.get::<_, Option<u32>>(7)?.unwrap_or(0),
            })
        })?;

        rows.collect()
    }

    /// Full track listing ordered using covering index `idx_tracks_album_order`.
    pub fn list_tracks(&self) -> Result<Vec<CloudTrackRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT file_id, name, folder_path, title, artist, album,
                    album_artist, genre, year, track_number, disc_number,
                    duration_ms, sample_rate, channels, bits_per_sample,
                    size_bytes, tags_read, artwork_path
             FROM tracks
             ORDER BY album, album_artist, disc_number, track_number, title",
        )?;

        let rows = stmt.query_map([], Self::row_to_cloud_track)?;
        rows.collect()
    }

    /// Retrieve a single track by its file_id.
    pub fn get_track(&self, file_id: &str) -> Result<Option<CloudTrackRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT file_id, name, folder_path, title, artist, album,
                    album_artist, genre, year, track_number, disc_number,
                    duration_ms, sample_rate, channels, bits_per_sample,
                    size_bytes, tags_read, artwork_path
             FROM tracks WHERE file_id = ?1",
        )?;
        let mut rows = stmt.query_map(params![file_id], Self::row_to_cloud_track)?;
        match rows.next() {
            Some(res) => res.map(Some),
            None => Ok(None),
        }
    }

    /// Aggregates distinct genres across normalized `genres` and `track_genres` tables,
    /// returning track counts, album counts, and up to 4 mosaic artwork paths per genre.
    pub fn get_genres(&self) -> Result<Vec<GenreSummary>> {
        let mut stmt = self.conn.prepare(
            "SELECT
                g.name,
                g.track_count,
                g.album_count,
                COALESCE((
                    SELECT GROUP_CONCAT(artwork, ';')
                    FROM (
                        SELECT DISTINCT t.artwork_path AS artwork
                        FROM track_genres tg
                        JOIN tracks t ON tg.track_id = t.rowid
                        WHERE tg.genre_id = g.id
                          AND t.artwork_path IS NOT NULL
                          AND t.artwork_path != ''
                          AND t.artwork_path NOT LIKE '%unknown_artist__unknown_album%'
                        ORDER BY t.rowid ASC
                        LIMIT 4
                    )
                ), '') AS mosaic_artworks
             FROM genres g
             WHERE g.track_count > 0
             ORDER BY CASE WHEN g.name = 'Unknown Genre' THEN 1 ELSE 0 END, g.name COLLATE NOCASE ASC",
        )?;

        let rows = stmt.query_map([], |row| {
            Ok(GenreSummary {
                genre: row.get(0)?,
                track_count: row.get(1)?,
                album_count: row.get(2)?,
                artwork_path: row.get(3)?,
            })
        })?;

        rows.collect()
    }

    /// Retrieves all tracks matching a given genre, ordered by album, disc number, track number, and title.
    pub fn get_tracks_by_genre(&self, genre: &str) -> Result<Vec<CloudTrackRow>> {
        let trimmed = genre.trim();
        let is_unknown = trimmed.is_empty()
            || trimmed.eq_ignore_ascii_case("Unknown Genre")
            || trimmed.eq_ignore_ascii_case("unknown");

        let norm = trimmed.to_lowercase();
        let mut stmt = if is_unknown {
            self.conn.prepare(
                "SELECT DISTINCT t.file_id, t.name, t.folder_path, t.title, t.artist, t.album,
                        t.album_artist, t.genre, t.year, t.track_number, t.disc_number,
                        t.duration_ms, t.sample_rate, t.channels, t.bits_per_sample,
                        t.size_bytes, t.tags_read, t.artwork_path
                 FROM tracks t
                 LEFT JOIN track_genres tg ON t.rowid = tg.track_id
                 LEFT JOIN genres g ON tg.genre_id = g.id
                 WHERE g.normalized_name = 'unknown genre' OR t.genre IS NULL OR TRIM(t.genre) = ''
                 ORDER BY t.album COLLATE NOCASE, t.disc_number, t.track_number, t.title COLLATE NOCASE",
            )?
        } else {
            self.conn.prepare(
                "SELECT DISTINCT t.file_id, t.name, t.folder_path, t.title, t.artist, t.album,
                        t.album_artist, t.genre, t.year, t.track_number, t.disc_number,
                        t.duration_ms, t.sample_rate, t.channels, t.bits_per_sample,
                        t.size_bytes, t.tags_read, t.artwork_path
                 FROM tracks t
                 JOIN track_genres tg ON t.rowid = tg.track_id
                 JOIN genres g ON tg.genre_id = g.id
                 WHERE g.normalized_name = ?1
                 ORDER BY t.album COLLATE NOCASE, t.disc_number, t.track_number, t.title COLLATE NOCASE",
            )?
        };

        let rows = if is_unknown {
            stmt.query_map([], Self::row_to_cloud_track)?
        } else {
            stmt.query_map(params![norm], Self::row_to_cloud_track)?
        };

        rows.collect()
    }

    /// Aggregates immediate subfolders under `parent_path` from indexed tracks.
    ///
    /// If `parent_path` is None, empty, "/", or "root", queries the root directories.
    /// Returns each immediate subfolder with cumulative track count, immediate subfolder count,
    /// and total byte size.
    pub fn get_folders(&self, parent_path: Option<&str>) -> Result<Vec<FolderSummary>> {
        use std::collections::{BTreeMap, HashSet};

        let parent_norm: Vec<String> = match parent_path {
            Some(p) => {
                let s = p.trim();
                if s.is_empty() || s == "/" || s.eq_ignore_ascii_case("root") {
                    Vec::new()
                } else {
                    s.split('/')
                        .map(|seg| seg.trim().to_string())
                        .filter(|seg| !seg.is_empty())
                        .collect()
                }
            }
            None => Vec::new(),
        };

        let mut stmt = self.conn.prepare(
            "SELECT folder_path, COUNT(*), COALESCE(SUM(size_bytes), 0)
             FROM tracks
             WHERE folder_path IS NOT NULL AND TRIM(folder_path) != ''
             GROUP BY folder_path",
        )?;

        let rows = stmt.query_map([], |row| {
            let path: String = row.get(0)?;
            let count: u32 = row.get(1)?;
            let size: i64 = row.get(2)?;
            Ok((path, count, size as u64))
        })?;

        // child_name -> (full_path, cumulative_tracks, cumulative_size, Set<immediate_subfolder_names>)
        let mut children: BTreeMap<String, (String, u32, u64, HashSet<String>)> = BTreeMap::new();

        for r in rows.flatten() {
            let (raw_path, count, size) = r;
            let segments: Vec<String> = raw_path
                .split('/')
                .map(|seg| seg.trim().to_string())
                .filter(|seg| !seg.is_empty())
                .collect();

            if segments.len() <= parent_norm.len() {
                continue;
            }

            let mut matches_parent = true;
            for (i, p_seg) in parent_norm.iter().enumerate() {
                if !segments[i].eq_ignore_ascii_case(p_seg) {
                    matches_parent = false;
                    break;
                }
            }

            if !matches_parent {
                continue;
            }

            let child_idx = parent_norm.len();
            let child_name = segments[child_idx].clone();

            let child_full_path = if parent_norm.is_empty() {
                child_name.clone()
            } else {
                let mut path_segs = parent_norm.clone();
                path_segs.push(child_name.clone());
                path_segs.join("/")
            };

            let entry = children
                .entry(child_name)
                .or_insert_with(|| (child_full_path, 0, 0, HashSet::new()));

            entry.1 += count;
            entry.2 += size;

            if segments.len() > child_idx + 1 {
                entry.3.insert(segments[child_idx + 1].clone());
            }
        }

        let mut result = Vec::new();
        for (name, (full_path, track_count, total_size, subfolders)) in children {
            result.push(FolderSummary {
                folder_id: full_path.clone(),
                name,
                path: full_path,
                track_count,
                subfolder_count: subfolders.len() as u32,
                total_size_bytes: total_size,
            });
        }

        result.sort_by_key(|a| a.name.to_lowercase());
        Ok(result)
    }

    /// Retrieves all tracks located in `folder_path`.
    ///
    /// If `recursive` is false, only returns tracks directly within `folder_path`.
    /// If `recursive` is true, returns all tracks within `folder_path` and all its nested subdirectories.
    pub fn get_tracks_in_folder(
        &self,
        folder_path: &str,
        recursive: bool,
    ) -> Result<Vec<CloudTrackRow>> {
        let trimmed = folder_path.trim();
        let is_root = trimmed.is_empty() || trimmed == "/" || trimmed.eq_ignore_ascii_case("root");

        let segments: Vec<&str> = trimmed
            .split('/')
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .collect();
        let slash_path = segments.join("/");
        let space_slash_path = segments.join(" / ");

        let mut stmt = if is_root {
            if recursive {
                self.conn.prepare(
                    "SELECT file_id, name, folder_path, title, artist, album,
                            album_artist, genre, year, track_number, disc_number,
                            duration_ms, sample_rate, channels, bits_per_sample,
                            size_bytes, tags_read, artwork_path
                     FROM tracks
                     ORDER BY folder_path, album COLLATE NOCASE, disc_number, track_number, title COLLATE NOCASE",
                )?
            } else {
                self.conn.prepare(
                    "SELECT file_id, name, folder_path, title, artist, album,
                            album_artist, genre, year, track_number, disc_number,
                            duration_ms, sample_rate, channels, bits_per_sample,
                            size_bytes, tags_read, artwork_path
                     FROM tracks
                     WHERE folder_path = '' OR folder_path = '/'
                     ORDER BY album COLLATE NOCASE, disc_number, track_number, title COLLATE NOCASE",
                )?
            }
        } else if recursive {
            let slash_prefix = format!("{}/%", slash_path);
            let space_prefix = format!("{} / %", space_slash_path);
            let mut s = self.conn.prepare(
                "SELECT file_id, name, folder_path, title, artist, album,
                        album_artist, genre, year, track_number, disc_number,
                        duration_ms, sample_rate, channels, bits_per_sample,
                        size_bytes, tags_read, artwork_path
                 FROM tracks
                 WHERE folder_path = ?1 OR folder_path = ?2 OR folder_path LIKE ?3 OR folder_path LIKE ?4
                 ORDER BY folder_path, album COLLATE NOCASE, disc_number, track_number, title COLLATE NOCASE",
            )?;
            let rows = s.query_map(
                params![slash_path, space_slash_path, slash_prefix, space_prefix],
                Self::row_to_cloud_track,
            )?;
            return rows.collect();
        } else {
            let mut s = self.conn.prepare(
                "SELECT file_id, name, folder_path, title, artist, album,
                        album_artist, genre, year, track_number, disc_number,
                        duration_ms, sample_rate, channels, bits_per_sample,
                        size_bytes, tags_read, artwork_path
                 FROM tracks
                 WHERE folder_path = ?1 OR folder_path = ?2
                 ORDER BY album COLLATE NOCASE, disc_number, track_number, title COLLATE NOCASE",
            )?;
            let rows = s.query_map(
                params![slash_path, space_slash_path],
                Self::row_to_cloud_track,
            )?;
            return rows.collect();
        };

        let rows = stmt.query_map([], Self::row_to_cloud_track)?;
        rows.collect()
    }

    /// Pending unscanned files.
    pub fn pending_tag_reads(&self, limit: u32) -> Result<Vec<String>> {
        let mut stmt = self
            .conn
            .prepare("SELECT file_id FROM tracks WHERE tags_read = 0 LIMIT ?1")?;
        let rows = stmt.query_map(params![limit], |r| r.get::<_, String>(0))?;
        rows.collect()
    }

    pub fn count(&self) -> Result<(u32, u32)> {
        let total: u32 = self
            .conn
            .query_row("SELECT COUNT(*) FROM tracks", [], |r| r.get(0))?;
        let tagged: u32 =
            self.conn
                .query_row("SELECT COUNT(*) FROM tracks WHERE tags_read = 1", [], |r| {
                    r.get(0)
                })?;
        Ok((total, tagged))
    }

    pub fn mark_tags_attempted(&self, file_id: &str) -> Result<()> {
        self.conn.execute(
            "UPDATE tracks SET tags_read = 1 WHERE file_id = ?",
            [file_id],
        )?;
        Ok(())
    }

    /// Prunes tracks under `folder_prefixes` whose file_id is NOT in `valid_file_ids`.
    /// If `folder_prefixes` is empty, prunes any track in the entire library whose file_id
    /// is NOT in `valid_file_ids`.
    ///
    /// Returns the list of deleted file_ids.
    pub fn prune_missing_files(
        &mut self,
        folder_prefixes: &[String],
        valid_file_ids: &[String],
    ) -> Result<Vec<String>> {
        let tx = self.conn.unchecked_transaction()?;
        tx.execute(
            "CREATE TEMP TABLE IF NOT EXISTS temp_valid_ids (file_id TEXT PRIMARY KEY)",
            [],
        )?;
        tx.execute("DELETE FROM temp_valid_ids", [])?;

        {
            let mut insert_temp =
                tx.prepare_cached("INSERT OR IGNORE INTO temp_valid_ids (file_id) VALUES (?1)")?;
            for id in valid_file_ids {
                insert_temp.execute(params![id])?;
            }
        }

        let mut to_delete = Vec::new();
        if folder_prefixes.is_empty() {
            let mut stmt = tx.prepare(
                "SELECT file_id FROM tracks WHERE file_id NOT IN (SELECT file_id FROM temp_valid_ids)",
            )?;
            let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
            for id in rows.flatten() {
                to_delete.push(id);
            }
        } else {
            for prefix in folder_prefixes {
                let mut stmt = tx.prepare(
                    "SELECT file_id FROM tracks
                     WHERE (folder_path = ?1 OR folder_path LIKE ?2)
                       AND file_id NOT IN (SELECT file_id FROM temp_valid_ids)",
                )?;
                let like_pattern = format!("{} / %", prefix);
                let rows =
                    stmt.query_map(params![prefix, like_pattern], |r| r.get::<_, String>(0))?;
                for id in rows.flatten() {
                    to_delete.push(id);
                }
            }
        }

        to_delete.sort();
        to_delete.dedup();

        {
            let mut del_stmt = tx.prepare_cached("DELETE FROM tracks WHERE file_id = ?1")?;
            for id in &to_delete {
                del_stmt.execute(params![id])?;
            }
        }

        tx.execute("DELETE FROM temp_valid_ids", [])?;
        tx.commit()?;

        if !to_delete.is_empty() {
            self.rebuild_albums_summary()?;
        }

        Ok(to_delete)
    }

    /// Recomputes `albums_summary` from scratch based on current `tracks` rows with `tags_read = 1`.
    pub fn rebuild_albums_summary(&mut self) -> Result<()> {
        let tx = self.conn.unchecked_transaction()?;
        tx.execute("DELETE FROM albums_summary", [])?;
        tx.execute(
            "INSERT INTO albums_summary (
                album_key, album, album_artist, year, artwork_path,
                track_count, max_sample_rate, max_bit_depth
            )
            SELECT
                LOWER(COALESCE(NULLIF(album_artist, ''), NULLIF(artist, ''), 'Unknown Artist')) || '::' || LOWER(COALESCE(NULLIF(album, ''), 'Unknown Album')) AS album_key,
                COALESCE(NULLIF(album, ''), 'Unknown Album') AS album,
                COALESCE(NULLIF(album_artist, ''), NULLIF(artist, ''), 'Unknown Artist') AS album_artist,
                MAX(COALESCE(year, 0)) AS year,
                MAX(COALESCE(artwork_path, '')) AS artwork_path,
                COUNT(*) AS track_count,
                MAX(COALESCE(sample_rate, 0)) AS max_sample_rate,
                MAX(COALESCE(bits_per_sample, 0)) AS max_bit_depth
            FROM tracks
            WHERE tags_read = 1
            GROUP BY album_key",
            [],
        )?;
        tx.commit()?;
        self.rebuild_genres_index()?;
        Ok(())
    }

    /// Rebuilds normalized `genres` and `track_genres` junction tables from scratch based on current `tracks`.
    pub fn rebuild_genres_index(&self) -> Result<()> {
        let tx = self.conn.unchecked_transaction()?;
        tx.execute("DELETE FROM track_genres", [])?;
        tx.execute("DELETE FROM genres", [])?;

        struct TrackGenreRow {
            rowid: i64,
            genre: String,
        }

        let mut query_stmt = tx.prepare("SELECT rowid, genre FROM tracks")?;
        let rows = query_stmt.query_map([], |row| {
            Ok(TrackGenreRow {
                rowid: row.get(0)?,
                genre: row.get(1)?,
            })
        })?;

        let entries: Vec<TrackGenreRow> = rows.filter_map(|r| r.ok()).collect();
        drop(query_stmt);

        let mut insert_genre = tx.prepare_cached(
            "INSERT INTO genres (name, normalized_name, track_count, album_count)
             VALUES (?1, ?2, 0, 0)
             ON CONFLICT(normalized_name) DO NOTHING",
        )?;

        let mut get_genre_id =
            tx.prepare_cached("SELECT id FROM genres WHERE normalized_name = ?1")?;

        let mut insert_track_genre = tx.prepare_cached(
            "INSERT OR IGNORE INTO track_genres (track_id, genre_id) VALUES (?1, ?2)",
        )?;

        for entry in entries {
            let parsed = crate::cloud::tag_parser::parse_multi_value_tag(&entry.genre);
            let genres_to_link = if parsed.is_empty() {
                vec!["Unknown Genre".to_string()]
            } else {
                parsed
            };

            for g in genres_to_link {
                let norm = g.trim().to_lowercase();
                if norm.is_empty() {
                    continue;
                }
                insert_genre.execute(params![g.trim(), norm])?;
                if let Ok(id) = get_genre_id.query_row(params![norm], |row| row.get::<_, i64>(0)) {
                    insert_track_genre.execute(params![entry.rowid, id])?;
                }
            }
        }
        drop(insert_genre);
        drop(get_genre_id);
        drop(insert_track_genre);

        // Update track_count and album_count for each genre
        tx.execute(
            "UPDATE genres SET
                track_count = (
                    SELECT COUNT(*) FROM track_genres WHERE track_genres.genre_id = genres.id
                ),
                album_count = (
                    SELECT COUNT(DISTINCT CASE 
                        WHEN t.album != '' AND t.album != 'Unknown Album'
                        THEN LOWER(TRIM(CASE WHEN t.album_artist != '' THEN t.album_artist ELSE t.artist END)) || '::' || LOWER(TRIM(t.album))
                        ELSE NULL 
                    END)
                    FROM track_genres tg
                    JOIN tracks t ON tg.track_id = t.rowid
                    WHERE tg.genre_id = genres.id
                )",
            [],
        )?;

        tx.execute("DELETE FROM genres WHERE track_count = 0", [])?;

        tx.commit()?;
        Ok(())
    }

    /// Retrieves cached lyrics for `file_id` if present in the SQLite database.
    pub fn get_lyrics(&self, file_id: &str) -> Result<Option<TrackLyrics>> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT synced, plain_text, synced_json FROM track_lyrics WHERE file_id = ?1",
        )?;
        let mut rows = stmt.query(params![file_id])?;
        if let Some(row) = rows.next()? {
            let synced: i64 = row.get(0)?;
            let plain_text: String = row.get(1)?;
            let synced_json: String = row.get(2)?;
            let lines: Vec<LyricLine> = serde_json::from_str(&synced_json).unwrap_or_default();
            Ok(Some(TrackLyrics {
                synced: synced != 0,
                lines,
                plain_lyrics: plain_text,
            }))
        } else {
            Ok(None)
        }
    }

    /// Persists lyrics for `file_id` into the `track_lyrics` cache.
    pub fn save_lyrics(&self, file_id: &str, lyrics: &TrackLyrics) -> Result<()> {
        let now_ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let synced_json = serde_json::to_string(&lyrics.lines).unwrap_or_else(|_| "[]".to_string());
        self.conn.execute(
            "INSERT INTO track_lyrics (file_id, synced, plain_text, synced_json, fetched_at)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(file_id) DO UPDATE SET
                synced = excluded.synced,
                plain_text = excluded.plain_text,
                synced_json = excluded.synced_json,
                fetched_at = excluded.fetched_at",
            params![
                file_id,
                if lyrics.synced { 1 } else { 0 },
                lyrics.plain_lyrics,
                synced_json,
                now_ts
            ],
        )?;
        Ok(())
    }

    /// Records a qualified playback entry into the `playback_history` table.
    pub fn record_playback(
        &self,
        file_id: &str,
        listened_ms: u32,
        sample_rate: Option<u32>,
        bit_depth: Option<u32>,
    ) -> Result<()> {
        let now_ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);

        let (sr, bd) = if sample_rate.is_some() && bit_depth.is_some() {
            (sample_rate, bit_depth)
        } else {
            let mut stmt = self.conn.prepare_cached(
                "SELECT sample_rate, bits_per_sample FROM tracks WHERE file_id = ?1",
            )?;
            let mut rows = stmt.query(params![file_id])?;
            if let Some(r) = rows.next()? {
                let db_sr: Option<u32> = r.get(0)?;
                let db_bd: Option<u32> = r.get(1)?;
                (sample_rate.or(db_sr), bit_depth.or(db_bd))
            } else {
                (sample_rate, bit_depth)
            }
        };

        self.conn.execute(
            "INSERT INTO playback_history (file_id, played_at_ts, listened_ms, sample_rate, bit_depth)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![file_id, now_ts, listened_ms, sr, bd],
        )?;
        Ok(())
    }

    /// Aggregates and computes the Audiophile Listening Recap across listening history.
    pub fn get_listening_recap(&self) -> Result<ListeningRecap> {
        let (total_listened_ms, total_plays): (i64, i64) = self
            .conn
            .query_row(
                "SELECT COALESCE(SUM(listened_ms), 0), COUNT(*) FROM playback_history",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap_or((0, 0));

        let total_minutes_listened = (total_listened_ms.max(0) as u64) / 60_000;

        let mut top_tracks = Vec::new();
        {
            let mut stmt = self.conn.prepare_cached(
                "SELECT p.file_id, 
                        COALESCE(NULLIF(t.title, ''), p.file_id) as track_title,
                        COALESCE(NULLIF(t.artist, ''), 'Unknown Artist') as track_artist,
                        COUNT(*) as plays,
                        COALESCE(SUM(p.listened_ms), 0) / 60000 as mins
                 FROM playback_history p
                 LEFT JOIN tracks t ON p.file_id = t.file_id
                 GROUP BY p.file_id
                 ORDER BY plays DESC, mins DESC
                 LIMIT 5",
            )?;
            let mut rows = stmt.query([])?;
            while let Some(r) = rows.next()? {
                let fid: String = r.get(0)?;
                let title: String = r.get(1)?;
                let artist: String = r.get(2)?;
                let plays: u32 = r.get(3)?;
                let mins: u32 = r.get(4)?;
                top_tracks.push(RecapTrackItem {
                    file_id: fid,
                    title,
                    artist,
                    play_count: plays,
                    total_minutes: mins,
                });
            }
        }

        let mut top_artists = Vec::new();
        {
            let mut stmt = self.conn.prepare_cached(
                "SELECT COALESCE(NULLIF(t.artist, ''), 'Unknown Artist') as artist_name,
                        COUNT(*) as plays,
                        COALESCE(SUM(p.listened_ms), 0) / 60000 as mins
                 FROM playback_history p
                 LEFT JOIN tracks t ON p.file_id = t.file_id
                 WHERE t.artist IS NOT NULL AND t.artist != '' AND t.artist != 'Unknown Artist'
                 GROUP BY artist_name
                 ORDER BY plays DESC, mins DESC
                 LIMIT 5",
            )?;
            let mut rows = stmt.query([])?;
            while let Some(r) = rows.next()? {
                let artist_name: String = r.get(0)?;
                let plays: u32 = r.get(1)?;
                let mins: u32 = r.get(2)?;
                top_artists.push(RecapArtistItem {
                    artist: artist_name,
                    play_count: plays,
                    total_minutes: mins,
                });
            }
        }

        let top_genre: Option<String> = {
            let mut stmt = self.conn.prepare_cached(
                "SELECT t.genre, COUNT(*) as plays
                 FROM playback_history p
                 JOIN tracks t ON p.file_id = t.file_id
                 WHERE t.genre IS NOT NULL AND t.genre != '' AND t.genre != 'Unknown Genre'
                 GROUP BY t.genre
                 ORDER BY plays DESC
                 LIMIT 1",
            )?;
            let mut rows = stmt.query([])?;
            if let Some(r) = rows.next()? {
                let g: String = r.get(0)?;
                let primary = g.split(';').next().unwrap_or(&g).trim().to_string();
                if primary.is_empty() {
                    None
                } else {
                    Some(primary)
                }
            } else {
                None
            }
        };

        let (lossless_count, hires_count): (i64, i64) = if total_plays > 0 {
            self.conn
                .query_row(
                    "SELECT 
                        COUNT(CASE WHEN (p.sample_rate >= 44100 AND p.bit_depth >= 16) OR (t.sample_rate >= 44100 AND t.bits_per_sample >= 16) THEN 1 END),
                        COUNT(CASE WHEN p.sample_rate > 48000 OR p.bit_depth > 16 OR t.sample_rate > 48000 OR t.bits_per_sample > 16 THEN 1 END)
                     FROM playback_history p
                     LEFT JOIN tracks t ON p.file_id = t.file_id",
                    [],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .unwrap_or((0, 0))
        } else {
            (0, 0)
        };

        let (lossless_percentage, hi_res_percentage) = if total_plays > 0 {
            (
                (lossless_count as f64 * 100.0) / (total_plays as f64),
                (hires_count as f64 * 100.0) / (total_plays as f64),
            )
        } else {
            (0.0, 0.0)
        };

        Ok(ListeningRecap {
            total_minutes_listened,
            total_plays: total_plays as u64,
            top_tracks,
            top_artists,
            top_genre,
            lossless_percentage,
            hi_res_percentage,
        })
    }

    pub fn clear_library_tables(&self) -> Result<()> {
        self.conn.execute("DELETE FROM tracks", [])?;
        self.conn.execute("DELETE FROM albums_summary", [])?;
        self.conn.execute("DELETE FROM track_genres", [])?;
        self.conn.execute("DELETE FROM genres", [])?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use crate::cloud::db::MetadataDb;
    use crate::cloud::local_scanner::LocalTrackInfo;

    #[test]
    fn test_normalized_genres_and_mosaic_aggregation() {
        let mut db = MetadataDb::new_in_memory().expect("open in memory db");

        let tracks = vec![
            LocalTrackInfo {
                path: "/music/t1.flac".into(),
                name: "t1.flac".into(),
                folder_path: "/music".into(),
                size_bytes: 1000,
                title: "Track 1".into(),
                artist: "Artist 1".into(),
                album: "Album A".into(),
                album_artist: "Artist 1".into(),
                genre: "Electronic; Ambient".into(),
                year: Some(2024),
                track_number: Some(1),
                disc_number: Some(1),
                duration_ms: 200_000,
                sample_rate: 44100,
                channels: 2,
                bits_per_sample: 16,
                artwork_path: Some("/music/art1.img".into()),
            },
            LocalTrackInfo {
                path: "/music/t2.flac".into(),
                name: "t2.flac".into(),
                folder_path: "/music".into(),
                size_bytes: 1000,
                title: "Track 2".into(),
                artist: "Artist 2".into(),
                album: "Album B".into(),
                album_artist: "Artist 2".into(),
                genre: "Ambient / Drone".into(),
                year: Some(2024),
                track_number: Some(1),
                disc_number: Some(1),
                duration_ms: 210_000,
                sample_rate: 44100,
                channels: 2,
                bits_per_sample: 16,
                artwork_path: Some("/music/art2.img".into()),
            },
            LocalTrackInfo {
                path: "/music/t3.flac".into(),
                name: "t3.flac".into(),
                folder_path: "/music".into(),
                size_bytes: 1000,
                title: "Track 3".into(),
                artist: "Artist 3".into(),
                album: "Album C".into(),
                album_artist: "Artist 3".into(),
                genre: "Electronic".into(),
                year: Some(2024),
                track_number: Some(1),
                disc_number: Some(1),
                duration_ms: 190_000,
                sample_rate: 44100,
                channels: 2,
                bits_per_sample: 16,
                artwork_path: Some("/music/art3.img".into()),
            },
            LocalTrackInfo {
                path: "/music/t4.flac".into(),
                name: "t4.flac".into(),
                folder_path: "/music".into(),
                size_bytes: 1000,
                title: "Track 4".into(),
                artist: "Artist 4".into(),
                album: "Album D".into(),
                album_artist: "Artist 4".into(),
                genre: "Electronic".into(),
                year: Some(2024),
                track_number: Some(1),
                disc_number: Some(1),
                duration_ms: 220_000,
                sample_rate: 44100,
                channels: 2,
                bits_per_sample: 16,
                artwork_path: Some("/music/art4.img".into()),
            },
            LocalTrackInfo {
                path: "/music/t5.flac".into(),
                name: "t5.flac".into(),
                folder_path: "/music".into(),
                size_bytes: 1000,
                title: "Track 5".into(),
                artist: "Artist 5".into(),
                album: "Album E".into(),
                album_artist: "Artist 5".into(),
                genre: "Electronic".into(),
                year: Some(2024),
                track_number: Some(1),
                disc_number: Some(1),
                duration_ms: 230_000,
                sample_rate: 44100,
                channels: 2,
                bits_per_sample: 16,
                artwork_path: Some("/music/art5.img".into()),
            },
            LocalTrackInfo {
                path: "/music/t6.flac".into(),
                name: "t6.flac".into(),
                folder_path: "/music".into(),
                size_bytes: 1000,
                title: "Track 6".into(),
                artist: "Artist 6".into(),
                album: "Album F".into(),
                album_artist: "Artist 6".into(),
                genre: "".into(),
                year: Some(2024),
                track_number: Some(1),
                disc_number: Some(1),
                duration_ms: 240_000,
                sample_rate: 44100,
                channels: 2,
                bits_per_sample: 16,
                artwork_path: None,
            },
        ];

        db.batch_insert_local_tracks(&tracks)
            .expect("batch insert tracks");

        let genres = db.get_genres().expect("get genres");

        let electronic = genres.iter().find(|g| g.genre == "Electronic").unwrap();
        assert_eq!(electronic.track_count, 4);
        assert_eq!(electronic.album_count, 4);
        let electronic_arts: Vec<&str> = electronic.artwork_path.split(';').collect();
        assert_eq!(electronic_arts.len(), 4);
        assert_eq!(
            electronic_arts,
            vec![
                "/music/art1.img",
                "/music/art3.img",
                "/music/art4.img",
                "/music/art5.img"
            ]
        );

        let ambient = genres.iter().find(|g| g.genre == "Ambient").unwrap();
        assert_eq!(ambient.track_count, 2);
        assert_eq!(ambient.album_count, 2);
        let ambient_arts: Vec<&str> = ambient.artwork_path.split(';').collect();
        assert_eq!(ambient_arts, vec!["/music/art1.img", "/music/art2.img"]);

        let drone = genres.iter().find(|g| g.genre == "Drone").unwrap();
        assert_eq!(drone.track_count, 1);
        assert_eq!(drone.album_count, 1);

        let unknown = genres.iter().find(|g| g.genre == "Unknown Genre").unwrap();
        assert_eq!(unknown.track_count, 1);

        // Test querying tracks by genre
        let ambient_tracks = db.get_tracks_by_genre("Ambient").expect("tracks by genre");
        assert_eq!(ambient_tracks.len(), 2);

        let electronic_tracks = db
            .get_tracks_by_genre("Electronic")
            .expect("tracks by genre");
        assert_eq!(electronic_tracks.len(), 4);

        let unknown_tracks = db
            .get_tracks_by_genre("Unknown Genre")
            .expect("tracks by genre");
        assert_eq!(unknown_tracks.len(), 1);
        assert_eq!(unknown_tracks[0].title, "Track 6");
    }

    #[test]
    fn test_track_lyrics_db_caching() {
        use crate::cloud::lyrics::{LyricLine, TrackLyrics};
        let db = MetadataDb::new_in_memory().expect("open db");

        assert!(db.get_lyrics("track-1").unwrap().is_none());

        let lyrics = TrackLyrics {
            synced: true,
            lines: vec![
                LyricLine {
                    timestamp_ms: 12_500,
                    text: "First line of lyric".into(),
                },
                LyricLine {
                    timestamp_ms: 18_000,
                    text: "Second line of lyric".into(),
                },
            ],
            plain_lyrics: "First line of lyric\nSecond line of lyric".into(),
        };

        db.save_lyrics("track-1", &lyrics).unwrap();

        let cached = db.get_lyrics("track-1").unwrap().expect("cached lyrics");
        assert!(cached.synced);
        assert_eq!(cached.lines.len(), 2);
        assert_eq!(cached.lines[0].timestamp_ms, 12_500);
        assert_eq!(cached.lines[0].text, "First line of lyric");
        assert_eq!(cached.lines[1].timestamp_ms, 18_000);
        assert_eq!(cached.plain_lyrics, lyrics.plain_lyrics);
    }

    #[test]
    fn test_playback_history_and_recap_metrics() {
        let mut db = MetadataDb::new_in_memory().expect("open db");

        // Insert tracks
        let tracks = vec![
            LocalTrackInfo {
                path: "/music/t1.flac".into(),
                name: "t1.flac".into(),
                folder_path: "/music".into(),
                size_bytes: 1000,
                title: "Paranoid Android".into(),
                artist: "Radiohead".into(),
                album: "OK Computer".into(),
                album_artist: "Radiohead".into(),
                genre: "Alternative Rock".into(),
                year: Some(1997),
                track_number: Some(2),
                disc_number: Some(1),
                duration_ms: 383_000,
                sample_rate: 96_000,
                channels: 2,
                bits_per_sample: 24,
                artwork_path: None,
            },
            LocalTrackInfo {
                path: "/music/t2.flac".into(),
                name: "t2.flac".into(),
                folder_path: "/music".into(),
                size_bytes: 1000,
                title: "Karma Police".into(),
                artist: "Radiohead".into(),
                album: "OK Computer".into(),
                album_artist: "Radiohead".into(),
                genre: "Alternative Rock".into(),
                year: Some(1997),
                track_number: Some(6),
                disc_number: Some(1),
                duration_ms: 261_000,
                sample_rate: 44_100,
                channels: 2,
                bits_per_sample: 16,
                artwork_path: None,
            },
            LocalTrackInfo {
                path: "/music/t3.mp3".into(),
                name: "t3.mp3".into(),
                folder_path: "/music".into(),
                size_bytes: 500,
                title: "Time".into(),
                artist: "Pink Floyd".into(),
                album: "The Dark Side of the Moon".into(),
                album_artist: "Pink Floyd".into(),
                genre: "Progressive Rock".into(),
                year: Some(1973),
                track_number: Some(4),
                disc_number: Some(1),
                duration_ms: 425_000,
                sample_rate: 44_100,
                channels: 2,
                bits_per_sample: 16,
                artwork_path: None,
            },
        ];
        db.batch_insert_local_tracks(&tracks).unwrap();

        // Record playback
        // Track 1 (Hi-Res: 96k/24) played twice, 300s each = 600s = 10 mins
        db.record_playback("/music/t1.flac", 300_000, Some(96_000), Some(24))
            .unwrap();
        db.record_playback("/music/t1.flac", 300_000, Some(96_000), Some(24))
            .unwrap();
        // Track 2 (Lossless CD: 44.1k/16) played once, 200s = 3.3 mins
        db.record_playback("/music/t2.flac", 200_000, Some(44_100), Some(16))
            .unwrap();
        // Track 3 (Lossless CD: 44.1k/16) played once, 100s = 1.6 mins
        db.record_playback("/music/t3.mp3", 100_000, Some(44_100), Some(16))
            .unwrap();

        let recap = db.get_listening_recap().expect("get listening recap");
        assert_eq!(recap.total_plays, 4);
        assert_eq!(recap.total_minutes_listened, 15); // (600 + 200 + 100) / 60 = 15 mins

        // Top tracks
        assert_eq!(recap.top_tracks.len(), 3);
        assert_eq!(recap.top_tracks[0].title, "Paranoid Android");
        assert_eq!(recap.top_tracks[0].play_count, 2);

        // Top artists
        assert_eq!(recap.top_artists.len(), 2);
        assert_eq!(recap.top_artists[0].artist, "Radiohead");
        assert_eq!(recap.top_artists[0].play_count, 3);
        assert_eq!(recap.top_artists[1].artist, "Pink Floyd");
        assert_eq!(recap.top_artists[1].play_count, 1);

        // Top genre
        assert_eq!(recap.top_genre, Some("Alternative Rock".into()));

        // Lossless and Hi-Res percentage:
        // All 4 plays are >= 44.1k/16 => 100% lossless
        // 2 of 4 plays are 96k/24 => 50% hi-res
        assert!((recap.lossless_percentage - 100.0).abs() < 1e-3);
        assert!((recap.hi_res_percentage - 50.0).abs() < 1e-3);
    }
}

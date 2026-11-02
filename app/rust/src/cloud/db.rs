use rusqlite::{params, Connection, Result, Row};
use std::path::Path;

/// One indexed track, flat enough to cross the FFI boundary unchanged.
#[derive(Debug, Clone)]
pub struct CloudTrackRow {
    pub file_id: String,
    pub name: String,
    pub folder_path: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_artist: String,
    pub genre: String,
    pub year: u32,
    pub track_number: u32,
    pub disc_number: u32,
    pub duration_ms: u32,
    pub sample_rate: u32,
    pub channels: u32,
    pub bits_per_sample: u32,
    pub size_bytes: u64,
    /// Absolute path to artwork extracted from the file, or empty.
    pub artwork_path: String,
    /// False while only the filename is known, i.e. before the tag pass has
    /// reached this row. The UI shimmers these fields rather than hiding them.
    pub tags_read: bool,
}

/// Materialized album summary row for instant rendering without runtime GROUP BY.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlbumSummaryRow {
    pub album_key: String,
    pub album: String,
    pub album_artist: String,
    pub year: u32,
    pub artwork_path: String,
    pub track_count: u32,
    pub max_sample_rate: u32,
    pub max_bit_depth: u32,
}

/// Record of an old file_id replaced by a newly uploaded file with the same path and name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReplacedFile {
    pub old_file_id: String,
    pub new_file_id: String,
}

/// A placeholder record for a newly discovered audio file.
pub struct TrackPlaceholder {
    pub file_id: String,
    pub name: String,
    pub folder_path: String,
    pub size_bytes: u64,
}

/// A batch tag update payload from metadata extraction.
#[derive(Debug, Clone)]
pub struct TrackTagUpdate {
    pub file_id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_artist: String,
    pub genre: String,
    pub year: u32,
    pub track_number: u32,
    pub disc_number: u32,
    pub duration_ms: u32,
    pub sample_rate: u32,
    pub channels: u32,
    pub bits_per_sample: u32,
    pub artwork_path: String,
}

/// Record of a completed audio chunk with CRC32 integrity checksum.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CachedChunkRecord {
    pub file_id: String,
    pub chunk_idx: u32,
    pub byte_offset: u64,
    pub byte_len: u32,
    pub crc32: u32,
    pub file_mtime: i64,
    pub last_accessed_ts: i64,
}

/// Result of an evicted chunk from the LRU cache pruner.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EvictedChunk {
    pub file_id: String,
    pub chunk_idx: u32,
    pub byte_offset: u64,
    pub byte_len: u32,
}

/// Aggregated cache usage statistics for storage budgeting.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CacheStatsRecord {
    pub total_bytes: u64,
    pub pinned_bytes: u64,
    pub unpinned_bytes: u64,
    pub chunk_count: u32,
}

pub struct MetadataDb {
    pub conn: Connection,
}

impl MetadataDb {
    /// Opens the SQLite database with high-throughput PRAGMAs configured.
    pub fn new<P: AsRef<Path>>(path: P) -> Result<Self> {
        let conn = Connection::open(path)?;
        Self::apply_pragmas(&conn)?;
        let db = Self { conn };
        db.init_schema()?;
        Ok(db)
    }

    /// In-memory database for testing.
    pub fn new_in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory()?;
        Self::apply_pragmas(&conn)?;
        let db = Self { conn };
        db.init_schema()?;
        Ok(db)
    }

    fn apply_pragmas(conn: &Connection) -> Result<()> {
        let _ = conn.pragma_update(None, "journal_mode", "WAL");
        let _ = conn.pragma_update(None, "synchronous", "NORMAL");
        let _ = conn.pragma_update(None, "mmap_size", 268435456); // 256 MB zero-copy memory-mapped I/O
        let _ = conn.pragma_update(None, "cache_size", -32768);   // 32 MB page cache in RAM
        let _ = conn.pragma_update(None, "temp_store", "MEMORY"); // Temp tables strictly in RAM
        let _ = conn.pragma_update(None, "wal_autocheckpoint", 2000);
        let _ = conn.pragma_update(None, "busy_timeout", 5000);
        Ok(())
    }

    fn init_schema(&self) -> Result<()> {
        // 1. Primary tracks table with explicit rowid primary key for fast joins
        self.conn.execute(
            "CREATE TABLE IF NOT EXISTS tracks (
                rowid            INTEGER PRIMARY KEY AUTOINCREMENT,
                file_id          TEXT NOT NULL UNIQUE,
                md5_checksum     TEXT,
                name             TEXT NOT NULL DEFAULT '',
                folder_path      TEXT NOT NULL DEFAULT '',
                title            TEXT NOT NULL DEFAULT '',
                artist           TEXT NOT NULL DEFAULT '',
                album            TEXT NOT NULL DEFAULT '',
                album_artist     TEXT NOT NULL DEFAULT '',
                genre            TEXT NOT NULL DEFAULT '',
                year             INTEGER,
                track_number     INTEGER DEFAULT 0,
                disc_number      INTEGER DEFAULT 1,
                duration_ms      INTEGER DEFAULT 0,
                sample_rate      INTEGER,
                channels         INTEGER,
                bits_per_sample  INTEGER,
                size_bytes       INTEGER DEFAULT 0,
                picture_offset   INTEGER,
                picture_length   INTEGER,
                artwork_path     TEXT,
                tags_read        INTEGER NOT NULL DEFAULT 0
            )",
            [],
        )?;

        // Non-destructive migrations for legacy tables
        let _ = self.conn.execute("ALTER TABLE tracks ADD COLUMN artwork_path TEXT", []);
        let _ = self.conn.execute("ALTER TABLE tracks ADD COLUMN md5_checksum TEXT", []);
        let _ = self.conn.execute("ALTER TABLE tracks ADD COLUMN picture_offset INTEGER", []);
        let _ = self.conn.execute("ALTER TABLE tracks ADD COLUMN picture_length INTEGER", []);

        // 2. Covering indexes for zero-heap UI sorting (<1.5ms at 100k tracks)
        self.conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_tracks_album_order
             ON tracks(album, album_artist, disc_number, track_number, title)",
            [],
        )?;
        self.conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_tracks_artist_order
             ON tracks(artist, album, disc_number, track_number)",
            [],
        )?;
        self.conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_tracks_unscanned
             ON tracks(tags_read, file_id) WHERE tags_read = 0",
            [],
        )?;
        self.conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_tracks_folder_name
             ON tracks(folder_path, name)",
            [],
        )?;

        // 3. Materialized albums summary table (renders 10,000-album grid in <1ms without GROUP BY)
        self.conn.execute(
            "CREATE TABLE IF NOT EXISTS albums_summary (
                album_key        TEXT PRIMARY KEY,
                album            TEXT NOT NULL,
                album_artist     TEXT NOT NULL,
                year             INTEGER,
                artwork_path     TEXT,
                track_count      INTEGER NOT NULL DEFAULT 0,
                max_sample_rate  INTEGER,
                max_bit_depth    INTEGER
            )",
            [],
        )?;

        // 4. External Content FTS5 Virtual Table (zero duplicate string storage on disk!)
        self.conn.execute(
            "CREATE VIRTUAL TABLE IF NOT EXISTS tracks_fts USING fts5(
                title,
                artist,
                album,
                album_artist,
                folder_path,
                name,
                content='tracks',
                content_rowid='rowid',
                tokenize='unicode61 remove_diacritics 2',
                prefix='2 3'
            )",
            [],
        )?;

        // 5. Automatic FTS5 Synchronization Triggers
        self.conn.execute(
            "CREATE TRIGGER IF NOT EXISTS trg_tracks_ai AFTER INSERT ON tracks BEGIN
                INSERT INTO tracks_fts(rowid, title, artist, album, album_artist, folder_path, name)
                VALUES (new.rowid, new.title, new.artist, new.album, new.album_artist, new.folder_path, new.name);
            END",
            [],
        )?;

        self.conn.execute(
            "CREATE TRIGGER IF NOT EXISTS trg_tracks_ad AFTER DELETE ON tracks BEGIN
                INSERT INTO tracks_fts(tracks_fts, rowid, title, artist, album, album_artist, folder_path, name)
                VALUES ('delete', old.rowid, old.title, old.artist, old.album, old.album_artist, old.folder_path, old.name);
            END",
            [],
        )?;

        self.conn.execute(
            "CREATE TRIGGER IF NOT EXISTS trg_tracks_au AFTER UPDATE OF title, artist, album, album_artist, folder_path, name ON tracks BEGIN
                INSERT INTO tracks_fts(tracks_fts, rowid, title, artist, album, album_artist, folder_path, name)
                VALUES ('delete', old.rowid, old.title, old.artist, old.album, old.album_artist, old.folder_path, old.name);
                INSERT INTO tracks_fts(rowid, title, artist, album, album_artist, folder_path, name)
                VALUES (new.rowid, new.title, new.artist, new.album, new.album_artist, new.folder_path, new.name);
            END",
            [],
        )?;

        // Propagate album artwork to any tracks that lack it
        let _ = self.conn.execute(
            "UPDATE tracks SET artwork_path = (
                SELECT a.artwork_path FROM albums_summary a
                WHERE a.album_key = lower(trim(CASE WHEN tracks.album_artist != '' THEN tracks.album_artist ELSE tracks.artist END)) || '::' || lower(trim(CASE WHEN tracks.album != '' THEN tracks.album ELSE 'unknown album' END))
                  AND a.artwork_path IS NOT NULL AND a.artwork_path != ''
            )
            WHERE (tracks.artwork_path IS NULL OR tracks.artwork_path = '')
              AND EXISTS (
                SELECT 1 FROM albums_summary a
                WHERE a.album_key = lower(trim(CASE WHEN tracks.album_artist != '' THEN tracks.album_artist ELSE tracks.artist END)) || '::' || lower(trim(CASE WHEN tracks.album != '' THEN tracks.album ELSE 'unknown album' END))
                  AND a.artwork_path IS NOT NULL AND a.artwork_path != ''
              )",
            [],
        );

        // 6. Cached chunks table for streaming data integrity and CRC32 verification (Phase 5.1)
        self.conn.execute(
            "CREATE TABLE IF NOT EXISTS cached_chunks (
                file_id          TEXT NOT NULL,
                chunk_idx        INTEGER NOT NULL,
                byte_offset      INTEGER NOT NULL,
                byte_len         INTEGER NOT NULL,
                crc32            INTEGER NOT NULL,
                file_mtime       INTEGER NOT NULL,
                last_accessed_ts INTEGER NOT NULL,
                PRIMARY KEY (file_id, chunk_idx)
            )",
            [],
        )?;

        self.conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_cached_chunks_lru
             ON cached_chunks(last_accessed_ts ASC)",
            [],
        )?;

        self.conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_cached_chunks_file
             ON cached_chunks(file_id)",
            [],
        )?;

        // 7. Pinned tracks table for protecting downloaded/pinned audio from LRU eviction (Phase 5.3)
        self.conn.execute(
            "CREATE TABLE IF NOT EXISTS pinned_tracks (
                file_id TEXT PRIMARY KEY
            )",
            [],
        )?;

        // 8. Key-value table for persistent settings like cache limit
        self.conn.execute(
            "CREATE TABLE IF NOT EXISTS app_kv (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )",
            [],
        )?;

        Ok(())
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
                name.rsplit_once('.').map(|(s, _)| s.to_string()).unwrap_or(name)
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
        let tx = self.conn.transaction()?;
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

    /// Batched tag update within a single transaction, updating both `tracks`
    /// and `albums_summary` atomically.
    pub fn batch_update_tags(&mut self, updates: &[TrackTagUpdate]) -> Result<()> {
        let tx = self.conn.transaction()?;
        {
            let mut track_stmt = tx.prepare_cached(
                "UPDATE tracks SET
                    title = ?2, artist = ?3, album = ?4, album_artist = ?5,
                    genre = ?6, year = ?7, track_number = ?8, disc_number = ?9,
                    duration_ms = ?10, sample_rate = ?11, channels = ?12,
                    bits_per_sample = ?13, artwork_path = ?14, tags_read = 1
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

                let album_clean = if u.album.is_empty() { "Unknown Album" } else { &u.album };
                let artist_clean = if !u.album_artist.is_empty() {
                    &u.album_artist
                } else if !u.artist.is_empty() {
                    &u.artist
                } else {
                    "Unknown Artist"
                };
                let album_key = format!("{}::{}", artist_clean.to_lowercase(), album_clean.to_lowercase());

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

            // Propagate album artwork to any tracks that lack it
            let _ = tx.execute(
                "UPDATE tracks SET artwork_path = (
                    SELECT a.artwork_path FROM albums_summary a
                    WHERE a.album_key = lower(trim(CASE WHEN tracks.album_artist != '' THEN tracks.album_artist ELSE tracks.artist END)) || '::' || lower(trim(CASE WHEN tracks.album != '' THEN tracks.album ELSE 'unknown album' END))
                      AND a.artwork_path IS NOT NULL AND a.artwork_path != ''
                )
                WHERE (tracks.artwork_path IS NULL OR tracks.artwork_path = '')
                  AND EXISTS (
                    SELECT 1 FROM albums_summary a
                    WHERE a.album_key = lower(trim(CASE WHEN tracks.album_artist != '' THEN tracks.album_artist ELSE tracks.artist END)) || '::' || lower(trim(CASE WHEN tracks.album != '' THEN tracks.album ELSE 'unknown album' END))
                      AND a.artwork_path IS NOT NULL AND a.artwork_path != ''
                  )",
                [],
            );
        }
        tx.commit()?;
        Ok(())
    }

    /// Single track tag update (backward compatible wrapper).
    pub fn update_tags_single(&mut self, update: &TrackTagUpdate) -> Result<()> {
        self.batch_update_tags(std::slice::from_ref(update))
    }

    pub fn set_artwork(&self, file_id: &str, path: &str) -> Result<()> {
        self.conn.execute(
            "UPDATE tracks SET artwork_path = ?2 WHERE file_id = ?1",
            params![file_id, path],
        )?;
        Ok(())
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

        let rows = stmt.query_map(params![fts_query, limit], |r| {
            Self::row_to_cloud_track(r)
        })?;

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
        let tagged: u32 = self
            .conn
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
        let tx = self.conn.transaction()?;
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
        let tx = self.conn.transaction()?;
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
        Ok(())
    }

    /// Records or updates a cached chunk with verified CRC32 checksum.
    pub fn record_cached_chunk(&self, chunk: &CachedChunkRecord) -> Result<()> {
        self.conn.execute(
            "INSERT OR REPLACE INTO cached_chunks (
                file_id, chunk_idx, byte_offset, byte_len, crc32, file_mtime, last_accessed_ts
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                chunk.file_id,
                chunk.chunk_idx,
                chunk.byte_offset as i64,
                chunk.byte_len as i64,
                chunk.crc32 as i64,
                chunk.file_mtime,
                chunk.last_accessed_ts,
            ],
        )?;
        Ok(())
    }

    /// Fetches all cached chunk records for a given file_id.
    pub fn get_cached_chunks(&self, file_id: &str) -> Result<Vec<CachedChunkRecord>> {
        let mut stmt = self.conn.prepare(
            "SELECT file_id, chunk_idx, byte_offset, byte_len, crc32, file_mtime, last_accessed_ts
             FROM cached_chunks WHERE file_id = ?1 ORDER BY chunk_idx ASC",
        )?;
        let rows = stmt.query_map(params![file_id], |r| {
            Ok(CachedChunkRecord {
                file_id: r.get(0)?,
                chunk_idx: r.get::<_, u32>(1)?,
                byte_offset: r.get::<_, i64>(2)? as u64,
                byte_len: r.get::<_, i64>(3)? as u32,
                crc32: r.get::<_, i64>(4)? as u32,
                file_mtime: r.get(5)?,
                last_accessed_ts: r.get(6)?,
            })
        })?;
        let mut list = Vec::new();
        for r in rows {
            list.push(r?);
        }
        Ok(list)
    }

    /// Fetches a specific cached chunk record.
    pub fn get_cached_chunk(&self, file_id: &str, chunk_idx: u32) -> Result<Option<CachedChunkRecord>> {
        let mut stmt = self.conn.prepare(
            "SELECT file_id, chunk_idx, byte_offset, byte_len, crc32, file_mtime, last_accessed_ts
             FROM cached_chunks WHERE file_id = ?1 AND chunk_idx = ?2",
        )?;
        let mut rows = stmt.query_map(params![file_id, chunk_idx], |r| {
            Ok(CachedChunkRecord {
                file_id: r.get(0)?,
                chunk_idx: r.get::<_, u32>(1)?,
                byte_offset: r.get::<_, i64>(2)? as u64,
                byte_len: r.get::<_, i64>(3)? as u32,
                crc32: r.get::<_, i64>(4)? as u32,
                file_mtime: r.get(5)?,
                last_accessed_ts: r.get(6)?,
            })
        })?;
        if let Some(r) = rows.next() {
            Ok(Some(r?))
        } else {
            Ok(None)
        }
    }

    /// Deletes a specific cached chunk record (e.g. after CRC32 mismatch or truncation).
    pub fn delete_cached_chunk(&self, file_id: &str, chunk_idx: u32) -> Result<()> {
        self.conn.execute(
            "DELETE FROM cached_chunks WHERE file_id = ?1 AND chunk_idx = ?2",
            params![file_id, chunk_idx],
        )?;
        Ok(())
    }

    /// Deletes all cached chunk records for a file.
    pub fn delete_all_cached_chunks(&self, file_id: &str) -> Result<()> {
        self.conn.execute(
            "DELETE FROM cached_chunks WHERE file_id = ?1",
            params![file_id],
        )?;
        Ok(())
    }

    /// Updates last_accessed_ts for a chunk.
    pub fn touch_chunk_access(&self, file_id: &str, chunk_idx: u32, now_ts: i64) -> Result<()> {
        self.conn.execute(
            "UPDATE cached_chunks SET last_accessed_ts = ?1 WHERE file_id = ?2 AND chunk_idx = ?3",
            params![now_ts, file_id, chunk_idx],
        )?;
        Ok(())
    }

    /// Updates last_accessed_ts for all chunks of a file.
    pub fn touch_file_access(&self, file_id: &str, now_ts: i64) -> Result<()> {
        self.conn.execute(
            "UPDATE cached_chunks SET last_accessed_ts = ?1 WHERE file_id = ?2",
            params![now_ts, file_id],
        )?;
        Ok(())
    }

    /// Returns the total bytes across all cached chunks.
    pub fn total_cached_bytes(&self) -> Result<u64> {
        let total: Option<i64> = self.conn.query_row(
            "SELECT SUM(byte_len) FROM cached_chunks",
            [],
            |r| r.get(0),
        )?;
        Ok(total.unwrap_or(0).max(0) as u64)
    }

    /// Syncs pinned track file_ids in SQLite atomically.
    pub fn sync_pinned_tracks(&mut self, pinned_ids: &[String]) -> Result<()> {
        let tx = self.conn.transaction()?;
        tx.execute("DELETE FROM pinned_tracks", [])?;
        {
            let mut stmt = tx.prepare_cached("INSERT OR IGNORE INTO pinned_tracks (file_id) VALUES (?1)")?;
            for id in pinned_ids {
                stmt.execute(params![id])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// Checks if a file is marked pinned in SQLite.
    pub fn is_track_pinned(&self, file_id: &str) -> Result<bool> {
        let count: u32 = self.conn.query_row(
            "SELECT COUNT(*) FROM pinned_tracks WHERE file_id = ?1",
            params![file_id],
            |r| r.get(0),
        )?;
        Ok(count > 0)
    }

    /// Returns all pinned file_ids.
    pub fn get_pinned_tracks(&self) -> Result<Vec<String>> {
        let mut stmt = self.conn.prepare("SELECT file_id FROM pinned_tracks")?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
        rows.collect()
    }

    /// Stores a persistent key-value configuration pair.
    pub fn set_kv(&self, key: &str, val: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO app_kv (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, val],
        )?;
        Ok(())
    }

    /// Reads a persistent key-value configuration pair.
    pub fn get_kv(&self, key: &str) -> Result<Option<String>> {
        let mut stmt = self.conn.prepare("SELECT value FROM app_kv WHERE key = ?1")?;
        let mut rows = stmt.query_map(params![key], |r| r.get::<_, String>(0))?;
        match rows.next() {
            Some(res) => res.map(Some),
            None => Ok(None),
        }
    }

    /// Deletes a persistent key-value configuration pair.
    pub fn delete_kv(&self, key: &str) -> Result<()> {
        self.conn.execute("DELETE FROM app_kv WHERE key = ?1", params![key])?;
        Ok(())
    }

    /// Lists all key-value configuration pairs starting with a given prefix.
    pub fn list_kv_prefix(&self, prefix: &str) -> Result<Vec<(String, String)>> {
        let pattern = format!("{}%", prefix);
        let mut stmt = self.conn.prepare("SELECT key, value FROM app_kv WHERE key LIKE ?1 ORDER BY key ASC")?;
        let rows = stmt.query_map(params![pattern], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })?;
        let mut result = Vec::new();
        for r in rows {
            result.push(r?);
        }
        Ok(result)
    }

    /// Returns the number of cached chunks for a given file_id.
    pub fn count_cached_chunks_for_file(&self, file_id: &str) -> Result<u32> {
        let count: u32 = self.conn.query_row(
            "SELECT COUNT(*) FROM cached_chunks WHERE file_id = ?1",
            params![file_id],
            |r| r.get(0),
        )?;
        Ok(count)
    }

    /// Aggregates total, pinned, and unpinned cache bytes.
    pub fn get_cache_stats(&self, extra_pinned_ids: &[String]) -> Result<CacheStatsRecord> {
        let mut pinned_set: std::collections::HashSet<String> = self.get_pinned_tracks()?.into_iter().collect();
        for id in extra_pinned_ids {
            pinned_set.insert(id.clone());
        }

        let mut stmt = self.conn.prepare(
            "SELECT file_id, SUM(byte_len), COUNT(*) FROM cached_chunks GROUP BY file_id",
        )?;

        let mut total_bytes = 0u64;
        let mut pinned_bytes = 0u64;
        let mut unpinned_bytes = 0u64;
        let mut chunk_count = 0u32;

        let rows = stmt.query_map([], |r| {
            let file_id: String = r.get(0)?;
            let bytes: i64 = r.get(1)?;
            let count: u32 = r.get(2)?;
            Ok((file_id, bytes.max(0) as u64, count))
        })?;

        for row in rows {
            let (file_id, bytes, count) = row?;
            total_bytes += bytes;
            chunk_count += count;
            if pinned_set.contains(&file_id) {
                pinned_bytes += bytes;
            } else {
                unpinned_bytes += bytes;
            }
        }

        Ok(CacheStatsRecord {
            total_bytes,
            pinned_bytes,
            unpinned_bytes,
            chunk_count,
        })
    }

    /// Prunes least-recently-accessed unpinned chunks until unpinned bytes are at or below `limit_bytes`.
    /// Pinned tracks and the active_file_id are 100% protected and NEVER evicted.
    pub fn prune_lru_chunks(
        &mut self,
        limit_bytes: u64,
        extra_pinned_ids: &[String],
        active_file_id: Option<&str>,
    ) -> Result<Vec<EvictedChunk>> {
        let stats = self.get_cache_stats(extra_pinned_ids)?;
        if stats.unpinned_bytes <= limit_bytes {
            return Ok(Vec::new());
        }

        let mut pinned_set: std::collections::HashSet<String> = self.get_pinned_tracks()?.into_iter().collect();
        for id in extra_pinned_ids {
            pinned_set.insert(id.clone());
        }

        let excess = stats.unpinned_bytes - limit_bytes;
        let cushion = (limit_bytes / 10).min(50 * 1024 * 1024);
        let target_to_free = excess.saturating_add(cushion);

        let mut to_evict = Vec::new();
        {
            let mut stmt = self.conn.prepare(
                "SELECT file_id, chunk_idx, byte_offset, byte_len
                 FROM cached_chunks
                 ORDER BY last_accessed_ts ASC",
            )?;

            let mut freed = 0u64;

            let rows = stmt.query_map([], |r| {
                Ok(EvictedChunk {
                    file_id: r.get(0)?,
                    chunk_idx: r.get(1)?,
                    byte_offset: r.get::<_, i64>(2)? as u64,
                    byte_len: r.get::<_, i64>(3)? as u32,
                })
            })?;

            for item in rows {
                let chunk = item?;
                if pinned_set.contains(&chunk.file_id) {
                    continue;
                }
                if let Some(active) = active_file_id {
                    if chunk.file_id == active {
                        continue;
                    }
                }

                freed += chunk.byte_len as u64;
                to_evict.push(chunk);

                if freed >= target_to_free {
                    break;
                }
            }
        }

        if !to_evict.is_empty() {
            let tx = self.conn.transaction()?;
            {
                let mut del_stmt = tx.prepare_cached(
                    "DELETE FROM cached_chunks WHERE file_id = ?1 AND chunk_idx = ?2",
                )?;
                for chunk in &to_evict {
                    del_stmt.execute(params![&chunk.file_id, chunk.chunk_idx])?;
                }
            }
            tx.commit()?;
        }

        Ok(to_evict)
    }

    pub fn clear(&self) -> Result<()> {
        self.conn.execute("DELETE FROM tracks", [])?;
        self.conn.execute("DELETE FROM albums_summary", [])?;
        self.conn.execute("DELETE FROM cached_chunks", [])?;
        self.conn.execute("DELETE FROM pinned_tracks", [])?;
        self.conn.execute("DELETE FROM app_kv", [])?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sqlite_pragmas_schema_and_fts5_indexing() {
        let mut db = MetadataDb::new_in_memory().expect("in-memory db failed");

        // Insert placeholder tracks
        let placeholders = vec![
            TrackPlaceholder {
                file_id: "id_1".to_string(),
                name: "01 - Waltz for Debby.flac".to_string(),
                folder_path: "Jazz/Bill Evans".to_string(),
                size_bytes: 45_000_000,
            },
            TrackPlaceholder {
                file_id: "id_2".to_string(),
                name: "02 - My Foolish Heart.flac".to_string(),
                folder_path: "Jazz/Bill Evans".to_string(),
                size_bytes: 40_000_000,
            },
            TrackPlaceholder {
                file_id: "id_3".to_string(),
                name: "01 - Kind of Blue.flac".to_string(),
                folder_path: "Jazz/Miles Davis".to_string(),
                size_bytes: 65_000_000,
            },
        ];
        db.batch_insert_placeholders(&placeholders).unwrap();

        let (total, tagged) = db.count().unwrap();
        assert_eq!(total, 3);
        assert_eq!(tagged, 0);

        // Update tags
        let updates = vec![
            TrackTagUpdate {
                file_id: "id_1".to_string(),
                title: "Waltz for Debby".to_string(),
                artist: "Bill Evans Trio".to_string(),
                album: "Waltz for Debby".to_string(),
                album_artist: "Bill Evans".to_string(),
                genre: "Jazz".to_string(),
                year: 1961,
                track_number: 1,
                disc_number: 1,
                duration_ms: 420_000,
                sample_rate: 96000,
                channels: 2,
                bits_per_sample: 24,
                artwork_path: "/tmp/bill_evans.jpg".to_string(),
            },
            TrackTagUpdate {
                file_id: "id_2".to_string(),
                title: "My Foolish Heart".to_string(),
                artist: "Bill Evans Trio".to_string(),
                album: "Waltz for Debby".to_string(),
                album_artist: "Bill Evans".to_string(),
                genre: "Jazz".to_string(),
                year: 1961,
                track_number: 2,
                disc_number: 1,
                duration_ms: 310_000,
                sample_rate: 96000,
                channels: 2,
                bits_per_sample: 24,
                artwork_path: "/tmp/bill_evans.jpg".to_string(),
            },
        ];
        db.batch_update_tags(&updates).unwrap();

        let (total, tagged) = db.count().unwrap();
        assert_eq!(total, 3);
        assert_eq!(tagged, 2);

        // Test Materialized Albums Summary
        let albums = db.list_albums_summary().unwrap();
        assert_eq!(albums.len(), 1);
        assert_eq!(albums[0].album, "Waltz for Debby");
        assert_eq!(albums[0].album_artist, "Bill Evans");
        assert_eq!(albums[0].track_count, 2);
        assert_eq!(albums[0].max_sample_rate, 96000);
        assert_eq!(albums[0].max_bit_depth, 24);

        // Test External Content FTS5 Instant Search
        let search_results = db.search_tracks_fts("waltz debby", 10).unwrap();
        assert_eq!(search_results.len(), 2);
        assert_eq!(search_results[0].title, "Waltz for Debby");

        // Test Prefix search: "bil*" matches "Bill Evans"
        let prefix_results = db.search_tracks_fts("bil", 10).unwrap();
        assert_eq!(prefix_results.len(), 2);

        // Unmatched query returns empty vector without error
        let empty_results = db.search_tracks_fts("beethoven", 10).unwrap();
        assert_eq!(empty_results.len(), 0);
    }

    #[test]
    fn test_overwrite_replacement_and_pruning() {
        let mut db = MetadataDb::new_in_memory().expect("in-memory db failed");

        let p1 = vec![
            TrackPlaceholder {
                file_id: "drive_old_1".to_string(),
                name: "01 - Kid A.flac".to_string(),
                folder_path: "Music / Radiohead / Kid A".to_string(),
                size_bytes: 30_000_000,
            },
            TrackPlaceholder {
                file_id: "drive_file_2".to_string(),
                name: "02 - The National Anthem.flac".to_string(),
                folder_path: "Music / Radiohead / Kid A".to_string(),
                size_bytes: 45_000_000,
            },
        ];
        let replaced = db.batch_insert_placeholders(&p1).unwrap();
        assert!(replaced.is_empty());

        let (total, _) = db.count().unwrap();
        assert_eq!(total, 2);

        // Simulate re-upload: user replaced "01 - Kid A.flac" on Google Drive,
        // which assigned it a new file_id "drive_new_1".
        let p_reupload = vec![TrackPlaceholder {
            file_id: "drive_new_1".to_string(),
            name: "01 - Kid A.flac".to_string(),
            folder_path: "Music / Radiohead / Kid A".to_string(),
            size_bytes: 31_000_000,
        }];
        let replaced2 = db.batch_insert_placeholders(&p_reupload).unwrap();
        assert_eq!(
            replaced2,
            vec![ReplacedFile {
                old_file_id: "drive_old_1".to_string(),
                new_file_id: "drive_new_1".to_string(),
            }]
        );

        // Total count should still be 2, not 3!
        let (total2, _) = db.count().unwrap();
        assert_eq!(total2, 2);

        let tracks = db.list_tracks().unwrap();
        let file_ids: Vec<String> = tracks.into_iter().map(|t| t.file_id).collect();
        assert!(file_ids.contains(&"drive_new_1".to_string()));
        assert!(!file_ids.contains(&"drive_old_1".to_string()));

        // Simulate deletion on Drive: only "drive_new_1" exists now on Drive
        let pruned = db
            .prune_missing_files(
                &["Music / Radiohead / Kid A".to_string()],
                &["drive_new_1".to_string()],
            )
            .unwrap();
        assert_eq!(pruned, vec!["drive_file_2"]);

        let (total3, _) = db.count().unwrap();
        assert_eq!(total3, 1);
    }

    #[test]
    fn test_cached_chunks_crud_and_crc32() {
        let db = MetadataDb::new_in_memory().expect("in-memory db failed");

        let chunk0 = CachedChunkRecord {
            file_id: "flac_track_1".to_string(),
            chunk_idx: 0,
            byte_offset: 0,
            byte_len: 2 * 1024 * 1024,
            crc32: 0x12345678,
            file_mtime: 1700000000,
            last_accessed_ts: 1700000000,
        };
        let chunk1 = CachedChunkRecord {
            file_id: "flac_track_1".to_string(),
            chunk_idx: 1,
            byte_offset: 2 * 1024 * 1024,
            byte_len: 1024 * 1024,
            crc32: 0x87654321,
            file_mtime: 1700000001,
            last_accessed_ts: 1700000001,
        };

        db.record_cached_chunk(&chunk0).unwrap();
        db.record_cached_chunk(&chunk1).unwrap();

        let chunks = db.get_cached_chunks("flac_track_1").unwrap();
        assert_eq!(chunks.len(), 2);
        assert_eq!(chunks[0], chunk0);
        assert_eq!(chunks[1], chunk1);

        assert_eq!(db.total_cached_bytes().unwrap(), 3 * 1024 * 1024);

        // Fetch single chunk
        let single = db.get_cached_chunk("flac_track_1", 0).unwrap().unwrap();
        assert_eq!(single.crc32, 0x12345678);

        // Touch access time
        db.touch_chunk_access("flac_track_1", 0, 1700000050).unwrap();
        let touched = db.get_cached_chunk("flac_track_1", 0).unwrap().unwrap();
        assert_eq!(touched.last_accessed_ts, 1700000050);

        // Delete single chunk
        db.delete_cached_chunk("flac_track_1", 0).unwrap();
        assert_eq!(db.get_cached_chunks("flac_track_1").unwrap().len(), 1);
        assert_eq!(db.total_cached_bytes().unwrap(), 1024 * 1024);

        // Delete all
        db.delete_all_cached_chunks("flac_track_1").unwrap();
        assert_eq!(db.get_cached_chunks("flac_track_1").unwrap().len(), 0);
        assert_eq!(db.total_cached_bytes().unwrap(), 0);
    }

    #[test]
    fn test_lru_cache_pruning_respects_limit_and_protects_pinned() {
        let mut db = MetadataDb::new_in_memory().expect("in-memory db failed");

        // 1. Test KV store for cache limit
        db.set_kv("cache_limit_bytes", "2147483648").unwrap();
        assert_eq!(
            db.get_kv("cache_limit_bytes").unwrap(),
            Some("2147483648".to_string())
        );

        // 2. Test pinned tracks sync and queries
        let pinned_list = vec!["track_pinned_1".to_string(), "track_pinned_2".to_string()];
        db.sync_pinned_tracks(&pinned_list).unwrap();
        assert!(db.is_track_pinned("track_pinned_1").unwrap());
        assert!(db.is_track_pinned("track_pinned_2").unwrap());
        assert!(!db.is_track_pinned("track_unpinned_3").unwrap());
        let all_pinned = db.get_pinned_tracks().unwrap();
        assert_eq!(all_pinned.len(), 2);
        assert!(all_pinned.contains(&"track_pinned_1".to_string()));
        assert!(all_pinned.contains(&"track_pinned_2".to_string()));

        // 3. Insert chunk records across multiple tracks
        // Track A: unpinned, oldest (ts = 100), 2 chunks * 2 MB = 4 MB
        db.record_cached_chunk(&CachedChunkRecord {
            file_id: "track_A".to_string(),
            chunk_idx: 0,
            byte_offset: 0,
            byte_len: 2 * 1024 * 1024,
            crc32: 0x11,
            file_mtime: 100,
            last_accessed_ts: 100,
        }).unwrap();
        db.record_cached_chunk(&CachedChunkRecord {
            file_id: "track_A".to_string(),
            chunk_idx: 1,
            byte_offset: 2 * 1024 * 1024,
            byte_len: 2 * 1024 * 1024,
            crc32: 0x12,
            file_mtime: 100,
            last_accessed_ts: 101,
        }).unwrap();

        // Track B: unpinned, middle (ts = 200), 2 chunks * 2 MB = 4 MB
        db.record_cached_chunk(&CachedChunkRecord {
            file_id: "track_B".to_string(),
            chunk_idx: 0,
            byte_offset: 0,
            byte_len: 2 * 1024 * 1024,
            crc32: 0x21,
            file_mtime: 200,
            last_accessed_ts: 200,
        }).unwrap();
        db.record_cached_chunk(&CachedChunkRecord {
            file_id: "track_B".to_string(),
            chunk_idx: 1,
            byte_offset: 2 * 1024 * 1024,
            byte_len: 2 * 1024 * 1024,
            crc32: 0x22,
            file_mtime: 200,
            last_accessed_ts: 201,
        }).unwrap();

        // Track C: unpinned, newer (ts = 300), 2 chunks * 2 MB = 4 MB
        db.record_cached_chunk(&CachedChunkRecord {
            file_id: "track_C".to_string(),
            chunk_idx: 0,
            byte_offset: 0,
            byte_len: 2 * 1024 * 1024,
            crc32: 0x31,
            file_mtime: 300,
            last_accessed_ts: 300,
        }).unwrap();
        db.record_cached_chunk(&CachedChunkRecord {
            file_id: "track_C".to_string(),
            chunk_idx: 1,
            byte_offset: 2 * 1024 * 1024,
            byte_len: 2 * 1024 * 1024,
            crc32: 0x32,
            file_mtime: 300,
            last_accessed_ts: 301,
        }).unwrap();

        // Track P: pinned (in pinned list), ts = 50 (even older than A!), 2 chunks * 2 MB = 4 MB
        db.record_cached_chunk(&CachedChunkRecord {
            file_id: "track_pinned_1".to_string(),
            chunk_idx: 0,
            byte_offset: 0,
            byte_len: 2 * 1024 * 1024,
            crc32: 0x41,
            file_mtime: 50,
            last_accessed_ts: 50,
        }).unwrap();
        db.record_cached_chunk(&CachedChunkRecord {
            file_id: "track_pinned_1".to_string(),
            chunk_idx: 1,
            byte_offset: 2 * 1024 * 1024,
            byte_len: 2 * 1024 * 1024,
            crc32: 0x42,
            file_mtime: 50,
            last_accessed_ts: 51,
        }).unwrap();

        // Track Active: currently playing, ts = 60, 2 chunks * 2 MB = 4 MB
        db.record_cached_chunk(&CachedChunkRecord {
            file_id: "track_active".to_string(),
            chunk_idx: 0,
            byte_offset: 0,
            byte_len: 2 * 1024 * 1024,
            crc32: 0x51,
            file_mtime: 60,
            last_accessed_ts: 60,
        }).unwrap();
        db.record_cached_chunk(&CachedChunkRecord {
            file_id: "track_active".to_string(),
            chunk_idx: 1,
            byte_offset: 2 * 1024 * 1024,
            byte_len: 2 * 1024 * 1024,
            crc32: 0x52,
            file_mtime: 60,
            last_accessed_ts: 61,
        }).unwrap();

        // Verify total stats before pruning
        let stats = db.get_cache_stats(&["track_pinned_1".to_string()]).unwrap();
        assert_eq!(stats.total_bytes, 20 * 1024 * 1024);
        assert_eq!(stats.pinned_bytes, 4 * 1024 * 1024);
        // Unpinned includes track_A (4M) + track_B (4M) + track_C (4M) + track_active (4M) = 16M
        assert_eq!(stats.unpinned_bytes, 16 * 1024 * 1024);
        assert_eq!(stats.chunk_count, 10);

        // 4. Prune LRU chunks down to limit = 6 MB
        // Unpinned is 16 MB. Excess = 10 MB. With cushion ((6M/10)=600KB), target_to_free = 10.6 MB (6 chunks = 12 MB).
        // Protected: track_pinned_1 (pinned) and track_active (active).
        // Eviction order (last_accessed_ts ASC):
        // track_A (100, 101), track_B (200, 201), track_C (300, 301)
        let evicted = db.prune_lru_chunks(
            6 * 1024 * 1024,
            &["track_pinned_1".to_string()],
            Some("track_active"),
        ).unwrap();

        assert!(!evicted.is_empty());
        // Verify evicted chunks are all from unpinned tracks (A, B, C), and NEVER from track_pinned_1 or track_active
        for c in &evicted {
            assert_ne!(c.file_id, "track_pinned_1", "Pinned tracks must never be evicted");
            assert_ne!(c.file_id, "track_active", "Active track must never be evicted");
        }

        // track_A was oldest unpinned: its chunks must have been evicted first
        assert_eq!(evicted[0].file_id, "track_A");
        assert_eq!(evicted[0].chunk_idx, 0);
        assert_eq!(evicted[1].file_id, "track_A");
        assert_eq!(evicted[1].chunk_idx, 1);

        // Verify track_A chunks are completely gone from DB
        assert_eq!(db.count_cached_chunks_for_file("track_A").unwrap(), 0);

        // Pinned track and active track must still have all chunks intact!
        assert_eq!(db.count_cached_chunks_for_file("track_pinned_1").unwrap(), 2);
        assert_eq!(db.count_cached_chunks_for_file("track_active").unwrap(), 2);

        // Verify stats after pruning: unpinned bytes are at or below limit
        let stats_after = db.get_cache_stats(&["track_pinned_1".to_string()]).unwrap();
        assert!(stats_after.unpinned_bytes <= 6 * 1024 * 1024);
        assert_eq!(stats_after.pinned_bytes, 4 * 1024 * 1024);
    }

    #[test]
    fn test_app_kv_store_operations() {
        let db = MetadataDb::new_in_memory().expect("in-memory db failed");

        // Set and get
        db.set_kv("eq_state", "{\"bypass\":false}").unwrap();
        assert_eq!(
            db.get_kv("eq_state").unwrap(),
            Some("{\"bypass\":false}".to_string())
        );

        // Update existing
        db.set_kv("eq_state", "{\"bypass\":true}").unwrap();
        assert_eq!(
            db.get_kv("eq_state").unwrap(),
            Some("{\"bypass\":true}".to_string())
        );

        // List prefix
        db.set_kv("preset:vocal", "{\"bands\":[]}").unwrap();
        db.set_kv("preset:bass", "{\"bands\":[]}").unwrap();
        db.set_kv("other:foo", "bar").unwrap();

        let presets = db.list_kv_prefix("preset:").unwrap();
        assert_eq!(presets.len(), 2);
        assert_eq!(presets[0].0, "preset:bass");
        assert_eq!(presets[1].0, "preset:vocal");

        // Delete
        db.delete_kv("preset:bass").unwrap();
        assert_eq!(db.get_kv("preset:bass").unwrap(), None);
        assert_eq!(db.list_kv_prefix("preset:").unwrap().len(), 1);
    }
}


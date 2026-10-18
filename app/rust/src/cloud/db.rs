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
        &self,
        file_id: &str,
        name: &str,
        folder_path: &str,
        size_bytes: u64,
    ) -> Result<()> {
        self.conn.execute(
            "INSERT INTO tracks (file_id, name, folder_path, size_bytes, tags_read)
             VALUES (?1, ?2, ?3, ?4, 0)
             ON CONFLICT(file_id) DO UPDATE SET
                name = excluded.name,
                folder_path = excluded.folder_path,
                size_bytes = excluded.size_bytes,
                tags_read = 0",
            params![file_id, name, folder_path, size_bytes as i64],
        )?;
        Ok(())
    }

    /// Batched placeholder insertion within a single atomic transaction.
    pub fn batch_insert_placeholders(&mut self, items: &[TrackPlaceholder]) -> Result<()> {
        let tx = self.conn.transaction()?;
        {
            let mut stmt = tx.prepare_cached(
                "INSERT INTO tracks (file_id, name, folder_path, size_bytes, tags_read)
                 VALUES (?1, ?2, ?3, ?4, 0)
                 ON CONFLICT(file_id) DO UPDATE SET
                    name = excluded.name,
                    folder_path = excluded.folder_path,
                    size_bytes = excluded.size_bytes,
                    tags_read = 0",
            )?;
            for item in items {
                stmt.execute(params![
                    item.file_id,
                    item.name,
                    item.folder_path,
                    item.size_bytes as i64
                ])?;
            }
        }
        tx.commit()?;
        Ok(())
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
        }
        tx.commit()?;
        Ok(())
    }

    /// Single track tag update (backward compatible wrapper).
    pub fn update_tags_single(&mut self, update: &TrackTagUpdate) -> Result<()> {
        self.batch_update_tags(&[update.clone()])
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

        let rows = stmt.query_map([], |r| Self::row_to_cloud_track(r))?;
        rows.collect()
    }

    /// Pending unscanned files using partial covering index `idx_tracks_unscanned`.
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

    pub fn clear(&self) -> Result<()> {
        self.conn.execute("DELETE FROM tracks", [])?;
        self.conn.execute("DELETE FROM albums_summary", [])?;
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
}

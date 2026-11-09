pub mod autoeq_repo;
pub mod cache_repo;
pub mod library_repo;

pub use autoeq_repo::AutoEqRepository;
pub use cache_repo::CacheRepository;
pub use library_repo::LibraryRepository;

use crate::cloud::local_scanner::LocalTrackInfo;
use rusqlite::{Connection, Result};
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

/// Aggregated genre summary row for instant genre list/grid rendering.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GenreSummary {
    pub genre: String,
    pub track_count: u32,
    pub album_count: u32,
    pub artwork_path: String,
}

/// Summary of an immediate subfolder within the hierarchical directory tree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FolderSummary {
    pub folder_id: String,
    pub name: String,
    pub path: String,
    pub track_count: u32,
    pub subfolder_count: u32,
    pub total_size_bytes: u64,
}

/// Record of an old file_id replaced by a newly uploaded file with the same path and name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReplacedFile {
    pub old_file_id: String,
    pub new_file_id: String,
}

/// Individual track stats item for the listening recap.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct RecapTrackItem {
    pub file_id: String,
    pub title: String,
    pub artist: String,
    pub play_count: u32,
    pub total_minutes: u32,
}

/// Individual artist stats item for the listening recap.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct RecapArtistItem {
    pub artist: String,
    pub play_count: u32,
    pub total_minutes: u32,
}

/// Aggregate metrics for the Audiophile Listening Recap.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct ListeningRecap {
    pub total_minutes_listened: u64,
    pub total_plays: u64,
    pub top_tracks: Vec<RecapTrackItem>,
    pub top_artists: Vec<RecapArtistItem>,
    pub top_genre: Option<String>,
    pub lossless_percentage: f64,
    pub hi_res_percentage: f64,
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

/// Chunk selected for eviction during LRU cache pruning.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EvictionCandidate {
    pub file_id: String,
    pub chunk_idx: u32,
    pub byte_offset: u64,
    pub byte_len: u32,
}
pub type EvictedChunk = EvictionCandidate;

/// Cache storage statistics aggregating total, pinned, and unpinned usage.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CacheStatsRecord {
    pub total_bytes: u64,
    pub pinned_bytes: u64,
    pub unpinned_bytes: u64,
    pub chunk_count: u32,
}

/// AutoEQ headphone frequency response compensation profile.
#[derive(Debug, Clone, PartialEq)]
pub struct AutoEqProfileRow {
    pub id: String,
    pub model: String,
    pub brand: String,
    pub source: String,
    pub target: String,
    pub suggested_preamp_db: f64,
    pub bands_json: String,
}

/// Thread-safe database connection pool sharing a serialized `Mutex<Connection>`.
pub struct DbConnectionPool {
    conn: parking_lot::Mutex<Connection>,
}

impl DbConnectionPool {
    pub fn new<P: AsRef<Path>>(path: P) -> Result<Self> {
        let conn = Connection::open(path)?;
        MetadataDb::apply_pragmas(&conn)?;
        let pool = Self {
            conn: parking_lot::Mutex::new(conn),
        };
        MetadataDb::init_schema_on(&pool.conn.lock())?;
        Ok(pool)
    }

    pub fn new_in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory()?;
        MetadataDb::apply_pragmas(&conn)?;
        let pool = Self {
            conn: parking_lot::Mutex::new(conn),
        };
        MetadataDb::init_schema_on(&pool.conn.lock())?;
        Ok(pool)
    }

    pub fn lock(&self) -> parking_lot::MutexGuard<'_, Connection> {
        self.conn.lock()
    }
}

/// Backwards-compatible facade over the decomposed `LibraryRepository`, `CacheRepository`,
/// and `AutoEqRepository` submodules.
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

    pub fn apply_pragmas(conn: &Connection) -> Result<()> {
        let _ = conn.pragma_update(None, "journal_mode", "WAL");
        let _ = conn.pragma_update(None, "synchronous", "NORMAL");
        let _ = conn.pragma_update(None, "mmap_size", 268435456); // 256 MB zero-copy memory-mapped I/O
        let _ = conn.pragma_update(None, "cache_size", -32768); // 32 MB page cache in RAM
        let _ = conn.pragma_update(None, "temp_store", "MEMORY"); // Temp tables strictly in RAM
        let _ = conn.pragma_update(None, "wal_autocheckpoint", 2000);
        let _ = conn.pragma_update(None, "busy_timeout", 5000);
        Ok(())
    }

    pub fn init_schema(&self) -> Result<()> {
        Self::init_schema_on(&self.conn)
    }

    pub fn init_schema_on(conn: &Connection) -> Result<()> {
        // 1. Primary tracks table with explicit rowid primary key for fast joins
        conn.execute(
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
                tags_read        INTEGER NOT NULL DEFAULT 0,
                artwork_checked  INTEGER NOT NULL DEFAULT 0
            )",
            [],
        )?;

        // Non-destructive migrations for legacy tables
        let _ = conn.execute("ALTER TABLE tracks ADD COLUMN artwork_path TEXT", []);
        let _ = conn.execute("ALTER TABLE tracks ADD COLUMN md5_checksum TEXT", []);
        let _ = conn.execute("ALTER TABLE tracks ADD COLUMN picture_offset INTEGER", []);
        let _ = conn.execute("ALTER TABLE tracks ADD COLUMN picture_length INTEGER", []);
        let _ = conn.execute(
            "ALTER TABLE tracks ADD COLUMN artwork_checked INTEGER NOT NULL DEFAULT 0",
            [],
        );

        // 2. Covering indexes for zero-heap UI sorting (<1.5ms at 100k tracks)
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_tracks_album_order
             ON tracks(album, album_artist, disc_number, track_number, title)",
            [],
        )?;
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_tracks_artist_order
             ON tracks(artist, album, disc_number, track_number)",
            [],
        )?;
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_tracks_unscanned
             ON tracks(tags_read, file_id) WHERE tags_read = 0",
            [],
        )?;
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_tracks_folder_name
             ON tracks(folder_path, name)",
            [],
        )?;
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_tracks_genre
             ON tracks(genre)",
            [],
        )?;

        // Normalized genres lookup and multi-genre junction table
        conn.execute(
            "CREATE TABLE IF NOT EXISTS genres (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                name            TEXT NOT NULL UNIQUE,
                normalized_name TEXT NOT NULL UNIQUE,
                track_count     INTEGER NOT NULL DEFAULT 0,
                album_count     INTEGER NOT NULL DEFAULT 0
            )",
            [],
        )?;

        conn.execute(
            "CREATE TABLE IF NOT EXISTS track_genres (
                track_id INTEGER NOT NULL,
                genre_id INTEGER NOT NULL,
                PRIMARY KEY (track_id, genre_id),
                FOREIGN KEY (track_id) REFERENCES tracks(rowid) ON DELETE CASCADE,
                FOREIGN KEY (genre_id) REFERENCES genres(id) ON DELETE CASCADE
            )",
            [],
        )?;

        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_track_genres_genre_id ON track_genres(genre_id)",
            [],
        )?;
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_track_genres_track_id ON track_genres(track_id)",
            [],
        )?;
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_genres_normalized_name ON genres(normalized_name)",
            [],
        )?;

        // 3. Materialized albums summary table (renders 10,000-album grid in <1ms without GROUP BY)
        conn.execute(
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
        conn.execute(
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
        conn.execute(
            "CREATE TRIGGER IF NOT EXISTS trg_tracks_ai AFTER INSERT ON tracks BEGIN
                INSERT INTO tracks_fts(rowid, title, artist, album, album_artist, folder_path, name)
                VALUES (new.rowid, new.title, new.artist, new.album, new.album_artist, new.folder_path, new.name);
            END",
            [],
        )?;

        conn.execute(
            "CREATE TRIGGER IF NOT EXISTS trg_tracks_ad AFTER DELETE ON tracks BEGIN
                INSERT INTO tracks_fts(tracks_fts, rowid, title, artist, album, album_artist, folder_path, name)
                VALUES ('delete', old.rowid, old.title, old.artist, old.album, old.album_artist, old.folder_path, old.name);
            END",
            [],
        )?;

        conn.execute(
            "CREATE TRIGGER IF NOT EXISTS trg_tracks_au AFTER UPDATE OF title, artist, album, album_artist, folder_path, name ON tracks BEGIN
                INSERT INTO tracks_fts(tracks_fts, rowid, title, artist, album, album_artist, folder_path, name)
                VALUES ('delete', old.rowid, old.title, old.artist, old.album, old.album_artist, old.folder_path, old.name);
                INSERT INTO tracks_fts(rowid, title, artist, album, album_artist, folder_path, name)
                VALUES (new.rowid, new.title, new.artist, new.album, new.album_artist, new.folder_path, new.name);
            END",
            [],
        )?;

        // Propagate album artwork to any tracks that lack it (primary: artist::album)
        let _ = conn.execute(
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

        // Secondary propagation by album title
        let _ = conn.execute(
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

        // 6. Cached chunks table for streaming data integrity and CRC32 verification (Phase 5.1)
        conn.execute(
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

        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_cached_chunks_lru
             ON cached_chunks(last_accessed_ts ASC)",
            [],
        )?;

        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_cached_chunks_file
             ON cached_chunks(file_id)",
            [],
        )?;

        // 7. Pinned tracks table for protecting downloaded/pinned audio from LRU eviction (Phase 5.3)
        conn.execute(
            "CREATE TABLE IF NOT EXISTS pinned_tracks (
                file_id TEXT PRIMARY KEY
            )",
            [],
        )?;

        // 8. Key-value table for persistent settings like cache limit
        conn.execute(
            "CREATE TABLE IF NOT EXISTS app_kv (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )",
            [],
        )?;

        // 9. AutoEQ profiles table for headphone/IEM target frequency response curves
        conn.execute(
            "CREATE TABLE IF NOT EXISTS autoeq_profiles (
                id                  TEXT PRIMARY KEY,
                model               TEXT NOT NULL,
                brand               TEXT NOT NULL,
                source              TEXT NOT NULL,
                target              TEXT NOT NULL,
                suggested_preamp_db REAL NOT NULL,
                bands_json          TEXT NOT NULL
            )",
            [],
        )?;

        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_autoeq_model ON autoeq_profiles(model)",
            [],
        )?;

        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_autoeq_brand ON autoeq_profiles(brand)",
            [],
        )?;

        // 10. Time-synced and plain-text lyrics cache (Phase 3.1)
        let has_is_synced: bool = {
            let mut stmt = conn.prepare("PRAGMA table_info(track_lyrics)")?;
            let mut rows = stmt.query([])?;
            let mut found = false;
            while let Some(row) = rows.next()? {
                let name: String = row.get(1)?;
                if name == "is_synced" {
                    found = true;
                    break;
                }
            }
            found
        };
        if !has_is_synced {
            let _ = conn.execute("DROP TABLE IF EXISTS track_lyrics", []);
        }
        conn.execute(
            "CREATE TABLE IF NOT EXISTS track_lyrics (
                file_id          TEXT PRIMARY KEY,
                is_synced        INTEGER NOT NULL DEFAULT 0,
                content          TEXT NOT NULL DEFAULT '',
                source           TEXT NOT NULL DEFAULT 'none',
                updated_at       INTEGER NOT NULL DEFAULT 0
            )",
            [],
        )?;

        // 11. Playback history and listening stats tracking (Phase 3.3)
        conn.execute(
            "CREATE TABLE IF NOT EXISTS playback_history (
                id               INTEGER PRIMARY KEY AUTOINCREMENT,
                file_id          TEXT NOT NULL,
                played_at_ts     INTEGER NOT NULL,
                listened_ms      INTEGER NOT NULL,
                sample_rate      INTEGER,
                bit_depth        INTEGER
            )",
            [],
        )?;

        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_playback_history_file_id ON playback_history(file_id)",
            [],
        )?;

        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_playback_history_played_at ON playback_history(played_at_ts)",
            [],
        )?;

        let autoeq = AutoEqRepository::new(conn);
        autoeq.seed_autoeq_profiles()?;

        let genre_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM genres", [], |r| r.get(0))
            .unwrap_or(0);
        let track_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM tracks", [], |r| r.get(0))
            .unwrap_or(0);
        if genre_count == 0 && track_count > 0 {
            let repo = LibraryRepository::new(conn);
            let _ = repo.rebuild_genres_index();
        }

        Ok(())
    }

    /// Access the underlying `LibraryRepository`.
    #[inline]
    pub fn library(&self) -> LibraryRepository<'_> {
        LibraryRepository::new(&self.conn)
    }

    /// Access the underlying `CacheRepository`.
    #[inline]
    pub fn cache(&self) -> CacheRepository<'_> {
        CacheRepository::new(&self.conn)
    }

    /// Access the underlying `AutoEqRepository`.
    #[inline]
    pub fn autoeq(&self) -> AutoEqRepository<'_> {
        AutoEqRepository::new(&self.conn)
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Facade forwarding methods for 100% backwards compatibility
    // ──────────────────────────────────────────────────────────────────────────

    pub fn insert_placeholder(
        &mut self,
        file_id: &str,
        name: &str,
        folder_path: &str,
        size_bytes: u64,
    ) -> Result<Vec<ReplacedFile>> {
        self.library()
            .insert_placeholder(file_id, name, folder_path, size_bytes)
    }

    pub fn batch_insert_placeholders(
        &mut self,
        items: &[TrackPlaceholder],
    ) -> Result<Vec<ReplacedFile>> {
        self.library().batch_insert_placeholders(items)
    }

    pub fn batch_insert_local_tracks(&mut self, items: &[LocalTrackInfo]) -> Result<()> {
        self.library().batch_insert_local_tracks(items)
    }

    pub fn prune_missing_local_tracks(&mut self, root_label: &str) -> Result<usize> {
        self.library().prune_missing_local_tracks(root_label)
    }

    pub fn batch_update_tags(&mut self, updates: &[TrackTagUpdate]) -> Result<()> {
        self.library().batch_update_tags(updates)
    }

    pub fn update_tags_single(&mut self, update: &TrackTagUpdate) -> Result<()> {
        self.library().update_tags_single(update)
    }

    pub fn set_artwork(&self, file_id: &str, path: &str) -> Result<()> {
        self.library().set_artwork(file_id, path)
    }

    pub fn mark_artwork_checked(&self, file_id: &str) -> Result<()> {
        self.library().mark_artwork_checked(file_id)
    }

    pub fn is_artwork_checked(&self, file_id: &str) -> Result<bool> {
        self.library().is_artwork_checked(file_id)
    }

    pub fn search_tracks_fts(&self, query: &str, limit: u32) -> Result<Vec<CloudTrackRow>> {
        self.library().search_tracks_fts(query, limit)
    }

    pub fn list_albums_summary(&self) -> Result<Vec<AlbumSummaryRow>> {
        self.library().list_albums_summary()
    }

    pub fn list_tracks(&self) -> Result<Vec<CloudTrackRow>> {
        self.library().list_tracks()
    }

    pub fn get_track(&self, file_id: &str) -> Result<Option<CloudTrackRow>> {
        self.library().get_track(file_id)
    }

    pub fn get_genres(&self) -> Result<Vec<GenreSummary>> {
        self.library().get_genres()
    }

    pub fn get_tracks_by_genre(&self, genre: &str) -> Result<Vec<CloudTrackRow>> {
        self.library().get_tracks_by_genre(genre)
    }

    pub fn get_folders(&self, parent_path: Option<&str>) -> Result<Vec<FolderSummary>> {
        self.library().get_folders(parent_path)
    }

    pub fn get_tracks_in_folder(
        &self,
        folder_path: &str,
        recursive: bool,
    ) -> Result<Vec<CloudTrackRow>> {
        self.library().get_tracks_in_folder(folder_path, recursive)
    }

    pub fn pending_tag_reads(&self, limit: u32) -> Result<Vec<String>> {
        self.library().pending_tag_reads(limit)
    }

    pub fn count(&self) -> Result<(u32, u32)> {
        self.library().count()
    }

    pub fn mark_tags_attempted(&self, file_id: &str) -> Result<()> {
        self.library().mark_tags_attempted(file_id)
    }

    pub fn prune_missing_files(
        &mut self,
        folder_prefixes: &[String],
        valid_file_ids: &[String],
    ) -> Result<Vec<String>> {
        self.library()
            .prune_missing_files(folder_prefixes, valid_file_ids)
    }

    pub fn rebuild_albums_summary(&mut self) -> Result<()> {
        self.library().rebuild_albums_summary()
    }

    pub fn rebuild_genres_index(&self) -> Result<()> {
        self.library().rebuild_genres_index()
    }

    pub fn get_lyrics(&self, file_id: &str) -> Result<Option<crate::cloud::lyrics::TrackLyrics>> {
        self.library().get_lyrics(file_id)
    }

    pub fn save_lyrics(
        &self,
        file_id: &str,
        lyrics: &crate::cloud::lyrics::TrackLyrics,
    ) -> Result<()> {
        self.library().save_lyrics(file_id, lyrics)
    }

    pub fn record_playback(
        &self,
        file_id: &str,
        listened_ms: u32,
        sample_rate: Option<u32>,
        bit_depth: Option<u32>,
    ) -> Result<()> {
        self.library()
            .record_playback(file_id, listened_ms, sample_rate, bit_depth)
    }

    pub fn get_listening_recap(&self) -> Result<ListeningRecap> {
        self.library().get_listening_recap()
    }

    pub fn record_cached_chunk(&self, chunk: &CachedChunkRecord) -> Result<()> {
        self.cache().record_cached_chunk(chunk)
    }

    pub fn get_cached_chunks(&self, file_id: &str) -> Result<Vec<CachedChunkRecord>> {
        self.cache().get_cached_chunks(file_id)
    }

    pub fn get_cached_chunk(
        &self,
        file_id: &str,
        chunk_idx: u32,
    ) -> Result<Option<CachedChunkRecord>> {
        self.cache().get_cached_chunk(file_id, chunk_idx)
    }

    pub fn delete_cached_chunk(&self, file_id: &str, chunk_idx: u32) -> Result<()> {
        self.cache().delete_cached_chunk(file_id, chunk_idx)
    }

    pub fn delete_all_cached_chunks(&self, file_id: &str) -> Result<()> {
        self.cache().delete_all_cached_chunks(file_id)
    }

    pub fn touch_chunk_access(&self, file_id: &str, chunk_idx: u32, now_ts: i64) -> Result<()> {
        self.cache().touch_chunk_access(file_id, chunk_idx, now_ts)
    }

    pub fn touch_file_access(&self, file_id: &str, now_ts: i64) -> Result<()> {
        self.cache().touch_file_access(file_id, now_ts)
    }

    pub fn total_cached_bytes(&self) -> Result<u64> {
        self.cache().total_cached_bytes()
    }

    pub fn sync_pinned_tracks(&mut self, pinned_ids: &[String]) -> Result<()> {
        self.cache().sync_pinned_tracks(pinned_ids)
    }

    pub fn is_track_pinned(&self, file_id: &str) -> Result<bool> {
        self.cache().is_track_pinned(file_id)
    }

    pub fn get_pinned_tracks(&self) -> Result<Vec<String>> {
        self.cache().get_pinned_tracks()
    }

    pub fn count_cached_chunks_for_file(&self, file_id: &str) -> Result<u32> {
        self.cache().count_cached_chunks_for_file(file_id)
    }

    pub fn get_cache_stats(&self, extra_pinned_ids: &[String]) -> Result<CacheStatsRecord> {
        self.cache().get_cache_stats(extra_pinned_ids)
    }

    pub fn prune_lru_chunks(
        &mut self,
        limit_bytes: u64,
        extra_pinned_ids: &[String],
        active_file_id: Option<&str>,
    ) -> Result<Vec<EvictionCandidate>> {
        self.cache()
            .prune_lru_chunks(limit_bytes, extra_pinned_ids, active_file_id)
    }

    pub fn set_kv(&self, key: &str, val: &str) -> Result<()> {
        self.autoeq().set_kv(key, val)
    }

    pub fn get_kv(&self, key: &str) -> Result<Option<String>> {
        self.autoeq().get_kv(key)
    }

    pub fn delete_kv(&self, key: &str) -> Result<()> {
        self.autoeq().delete_kv(key)
    }

    pub fn list_kv_prefix(&self, prefix: &str) -> Result<Vec<(String, String)>> {
        self.autoeq().list_kv_prefix(prefix)
    }

    pub fn search_autoeq_profiles(&self, query: &str) -> Result<Vec<AutoEqProfileRow>> {
        self.autoeq().search_autoeq_profiles(query)
    }

    pub fn get_autoeq_profile(&self, id: &str) -> Result<Option<AutoEqProfileRow>> {
        self.autoeq().get_autoeq_profile(id)
    }

    pub fn insert_autoeq_profile(&self, p: &AutoEqProfileRow) -> Result<()> {
        self.autoeq().insert_autoeq_profile(p)
    }

    pub fn seed_autoeq_profiles(&self) -> Result<()> {
        self.autoeq().seed_autoeq_profiles()
    }

    pub fn curated_autoeq_profiles() -> Vec<AutoEqProfileRow> {
        AutoEqRepository::curated_autoeq_profiles()
    }

    pub fn clear(&self) -> Result<()> {
        self.library().clear_library_tables()?;
        self.cache().clear_cache_tables()?;
        self.conn.execute("DELETE FROM app_kv", [])?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_db_connection_pool() {
        let pool = DbConnectionPool::new_in_memory().expect("create pool");
        {
            let conn = pool.lock();
            let repo = LibraryRepository::new(&conn);
            let (scanned, total) = repo.count().unwrap();
            assert_eq!(scanned, 0);
            assert_eq!(total, 0);
        }
    }

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
        db.touch_chunk_access("flac_track_1", 0, 1700000050)
            .unwrap();
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
        })
        .unwrap();
        db.record_cached_chunk(&CachedChunkRecord {
            file_id: "track_A".to_string(),
            chunk_idx: 1,
            byte_offset: 2 * 1024 * 1024,
            byte_len: 2 * 1024 * 1024,
            crc32: 0x12,
            file_mtime: 100,
            last_accessed_ts: 101,
        })
        .unwrap();

        // Track B: unpinned, middle (ts = 200), 2 chunks * 2 MB = 4 MB
        db.record_cached_chunk(&CachedChunkRecord {
            file_id: "track_B".to_string(),
            chunk_idx: 0,
            byte_offset: 0,
            byte_len: 2 * 1024 * 1024,
            crc32: 0x21,
            file_mtime: 200,
            last_accessed_ts: 200,
        })
        .unwrap();
        db.record_cached_chunk(&CachedChunkRecord {
            file_id: "track_B".to_string(),
            chunk_idx: 1,
            byte_offset: 2 * 1024 * 1024,
            byte_len: 2 * 1024 * 1024,
            crc32: 0x22,
            file_mtime: 200,
            last_accessed_ts: 201,
        })
        .unwrap();

        // Track C: unpinned, newer (ts = 300), 2 chunks * 2 MB = 4 MB
        db.record_cached_chunk(&CachedChunkRecord {
            file_id: "track_C".to_string(),
            chunk_idx: 0,
            byte_offset: 0,
            byte_len: 2 * 1024 * 1024,
            crc32: 0x31,
            file_mtime: 300,
            last_accessed_ts: 300,
        })
        .unwrap();
        db.record_cached_chunk(&CachedChunkRecord {
            file_id: "track_C".to_string(),
            chunk_idx: 1,
            byte_offset: 2 * 1024 * 1024,
            byte_len: 2 * 1024 * 1024,
            crc32: 0x32,
            file_mtime: 300,
            last_accessed_ts: 301,
        })
        .unwrap();

        // Track P: pinned (in pinned list), ts = 50 (even older than A!), 2 chunks * 2 MB = 4 MB
        db.record_cached_chunk(&CachedChunkRecord {
            file_id: "track_pinned_1".to_string(),
            chunk_idx: 0,
            byte_offset: 0,
            byte_len: 2 * 1024 * 1024,
            crc32: 0x41,
            file_mtime: 50,
            last_accessed_ts: 50,
        })
        .unwrap();
        db.record_cached_chunk(&CachedChunkRecord {
            file_id: "track_pinned_1".to_string(),
            chunk_idx: 1,
            byte_offset: 2 * 1024 * 1024,
            byte_len: 2 * 1024 * 1024,
            crc32: 0x42,
            file_mtime: 50,
            last_accessed_ts: 51,
        })
        .unwrap();

        // Track Active: currently playing, ts = 60, 2 chunks * 2 MB = 4 MB
        db.record_cached_chunk(&CachedChunkRecord {
            file_id: "track_active".to_string(),
            chunk_idx: 0,
            byte_offset: 0,
            byte_len: 2 * 1024 * 1024,
            crc32: 0x51,
            file_mtime: 60,
            last_accessed_ts: 60,
        })
        .unwrap();
        db.record_cached_chunk(&CachedChunkRecord {
            file_id: "track_active".to_string(),
            chunk_idx: 1,
            byte_offset: 2 * 1024 * 1024,
            byte_len: 2 * 1024 * 1024,
            crc32: 0x52,
            file_mtime: 60,
            last_accessed_ts: 61,
        })
        .unwrap();

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
        let evicted = db
            .prune_lru_chunks(
                6 * 1024 * 1024,
                &["track_pinned_1".to_string()],
                Some("track_active"),
            )
            .unwrap();

        assert!(!evicted.is_empty());
        // Verify evicted chunks are all from unpinned tracks (A, B, C), and NEVER from track_pinned_1 or track_active
        for c in &evicted {
            assert_ne!(
                c.file_id, "track_pinned_1",
                "Pinned tracks must never be evicted"
            );
            assert_ne!(
                c.file_id, "track_active",
                "Active track must never be evicted"
            );
        }

        // track_A was oldest unpinned: its chunks must have been evicted first
        assert_eq!(evicted[0].file_id, "track_A");
        assert_eq!(evicted[0].chunk_idx, 0);
        assert_eq!(evicted[1].file_id, "track_A");
        assert_eq!(evicted[1].chunk_idx, 1);

        // Verify track_A chunks are completely gone from DB
        assert_eq!(db.count_cached_chunks_for_file("track_A").unwrap(), 0);

        // Pinned track and active track must still have all chunks intact!
        assert_eq!(
            db.count_cached_chunks_for_file("track_pinned_1").unwrap(),
            2
        );
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

    #[test]
    fn test_autoeq_database_seeding_and_search() {
        let db = MetadataDb::new_in_memory().expect("in-memory db failed");

        // 1. Initial schema creation seeds 28 curated profiles
        let all_profiles = db.search_autoeq_profiles("").unwrap();
        assert_eq!(
            all_profiles.len(),
            28,
            "Must seed 28 curated audiophile profiles"
        );

        // 2. Search by brand
        let sennheiser = db.search_autoeq_profiles("sennheiser").unwrap();
        assert_eq!(sennheiser.len(), 4, "Must find HD 600, 650, 800 S, 560S");
        for p in &sennheiser {
            assert_eq!(p.brand, "Sennheiser");
        }

        // 3. Search by model substring (case-insensitive)
        let titan = db.search_autoeq_profiles("titan").unwrap();
        assert_eq!(titan.len(), 2, "Must find DUNU Titan X and Titan S");

        // 4. Fetch specific profile by ID
        let titan_x = db
            .get_autoeq_profile("aeq-titanx")
            .unwrap()
            .expect("profile exists");
        assert_eq!(titan_x.model, "DUNU Titan X");
        assert_eq!(titan_x.brand, "DUNU");
        assert_eq!(titan_x.source, "oratory1990");
        assert_eq!(titan_x.target, "Harman In-Ear 2019");
        assert_eq!(titan_x.suggested_preamp_db, -6.2);
        assert!(titan_x.bands_json.contains("lowShelf"));
        assert!(titan_x.bands_json.contains("highShelf"));

        // 5. Insert custom imported profile
        let custom = AutoEqProfileRow {
            id: "custom-user-eq".to_string(),
            model: "Custom Planar Headphone".to_string(),
            brand: "Custom".to_string(),
            source: "Peace GUI".to_string(),
            target: "Flat".to_string(),
            suggested_preamp_db: -3.5,
            bands_json: r#"[{"id":1,"type":"peak","frequencyHz":1000.0,"gainDb":2.0,"q":1.41,"enabled":true}]"#.to_string(),
        };
        db.insert_autoeq_profile(&custom).unwrap();

        let fetched_custom = db
            .get_autoeq_profile("custom-user-eq")
            .unwrap()
            .expect("custom profile exists");
        assert_eq!(fetched_custom.model, "Custom Planar Headphone");
        assert_eq!(fetched_custom.suggested_preamp_db, -3.5);

        // Verify custom profile is searchable
        let search_custom = db.search_autoeq_profiles("Planar").unwrap();
        assert_eq!(search_custom.len(), 1);
        assert_eq!(search_custom[0].id, "custom-user-eq");
    }

    #[test]
    fn test_artwork_negative_caching_lifecycle() {
        let mut db = MetadataDb::new_in_memory().unwrap();

        // 1. Insert placeholders
        let placeholders = vec![
            TrackPlaceholder {
                file_id: "track_with_art".to_string(),
                name: "01. Song A.flac".to_string(),
                folder_path: "Artist/Album".to_string(),
                size_bytes: 10_000_000,
            },
            TrackPlaceholder {
                file_id: "track_no_art".to_string(),
                name: "02. Song B.flac".to_string(),
                folder_path: "Artist/Album".to_string(),
                size_bytes: 12_000_000,
            },
        ];
        db.batch_insert_placeholders(&placeholders).unwrap();

        // Neither should be checked initially
        assert!(!db.is_artwork_checked("track_with_art").unwrap());
        assert!(!db.is_artwork_checked("track_no_art").unwrap());

        // 2. Update track_with_art with artwork path -> artwork_checked should become true
        let updates = vec![TrackTagUpdate {
            file_id: "track_with_art".to_string(),
            title: "Song A".to_string(),
            artist: "Artist".to_string(),
            album: "Album".to_string(),
            album_artist: "Artist".to_string(),
            genre: "Rock".to_string(),
            year: 2024,
            track_number: 1,
            disc_number: 1,
            duration_ms: 200_000,
            sample_rate: 44100,
            channels: 2,
            bits_per_sample: 16,
            artwork_path: "/cache/artwork/album.img".to_string(),
        }];
        db.batch_update_tags(&updates).unwrap();
        assert!(db.is_artwork_checked("track_with_art").unwrap());
        assert!(!db.is_artwork_checked("track_no_art").unwrap());

        // 3. Mark track_no_art as checked (negative cache after online lookup returns None)
        db.mark_artwork_checked("track_no_art").unwrap();
        assert!(db.is_artwork_checked("track_no_art").unwrap());

        // 4. Test set_artwork also sets artwork_checked = 1
        let p3 = vec![TrackPlaceholder {
            file_id: "track_late_art".to_string(),
            name: "03. Song C.flac".to_string(),
            folder_path: "Artist/Album".to_string(),
            size_bytes: 15_000_000,
        }];
        db.batch_insert_placeholders(&p3).unwrap();
        assert!(!db.is_artwork_checked("track_late_art").unwrap());
        db.set_artwork("track_late_art", "/cache/artwork/late.img")
            .unwrap();
        assert!(db.is_artwork_checked("track_late_art").unwrap());
    }

    #[test]
    fn test_get_genres_and_tracks_by_genre() {
        let mut db = MetadataDb::new_in_memory().unwrap();

        let placeholders = vec![
            TrackPlaceholder {
                file_id: "t1".to_string(),
                name: "01. Rock 1.flac".to_string(),
                folder_path: "Music/Rock".to_string(),
                size_bytes: 20_000_000,
            },
            TrackPlaceholder {
                file_id: "t2".to_string(),
                name: "02. Rock 2.flac".to_string(),
                folder_path: "Music/Rock".to_string(),
                size_bytes: 25_000_000,
            },
            TrackPlaceholder {
                file_id: "t3".to_string(),
                name: "01. Jazz 1.flac".to_string(),
                folder_path: "Music/Jazz".to_string(),
                size_bytes: 30_000_000,
            },
            TrackPlaceholder {
                file_id: "t4".to_string(),
                name: "01. Untagged.flac".to_string(),
                folder_path: "Music/Other".to_string(),
                size_bytes: 15_000_000,
            },
        ];
        db.batch_insert_placeholders(&placeholders).unwrap();

        let updates = vec![
            TrackTagUpdate {
                file_id: "t1".to_string(),
                title: "Rock 1".to_string(),
                artist: "Band A".to_string(),
                album: "Album A".to_string(),
                album_artist: "Band A".to_string(),
                genre: "Rock".to_string(),
                year: 2020,
                track_number: 1,
                disc_number: 1,
                duration_ms: 180_000,
                sample_rate: 44100,
                channels: 2,
                bits_per_sample: 16,
                artwork_path: "/cache/artwork/band_a.img".to_string(),
            },
            TrackTagUpdate {
                file_id: "t2".to_string(),
                title: "Rock 2".to_string(),
                artist: "Band B".to_string(),
                album: "Album B".to_string(),
                album_artist: "Band B".to_string(),
                genre: "Rock".to_string(),
                year: 2021,
                track_number: 2,
                disc_number: 1,
                duration_ms: 210_000,
                sample_rate: 44100,
                channels: 2,
                bits_per_sample: 16,
                artwork_path: String::new(),
            },
            TrackTagUpdate {
                file_id: "t3".to_string(),
                title: "Jazz 1".to_string(),
                artist: "Miles Trio".to_string(),
                album: "Blue In Green".to_string(),
                album_artist: "Miles Trio".to_string(),
                genre: "Jazz".to_string(),
                year: 1959,
                track_number: 1,
                disc_number: 1,
                duration_ms: 320_000,
                sample_rate: 96000,
                channels: 2,
                bits_per_sample: 24,
                artwork_path: "/cache/artwork/miles.img".to_string(),
            },
            TrackTagUpdate {
                file_id: "t4".to_string(),
                title: "Untagged".to_string(),
                artist: "Unknown Artist".to_string(),
                album: "Unknown Album".to_string(),
                album_artist: "Unknown Artist".to_string(),
                genre: String::new(),
                year: 0,
                track_number: 1,
                disc_number: 1,
                duration_ms: 120_000,
                sample_rate: 44100,
                channels: 2,
                bits_per_sample: 16,
                artwork_path: String::new(),
            },
        ];
        db.batch_update_tags(&updates).unwrap();

        // 1. Verify get_genres()
        let genres = db.get_genres().unwrap();
        assert_eq!(genres.len(), 3);

        // Alphabetical: Jazz first, then Rock, then Unknown Genre last
        assert_eq!(genres[0].genre, "Jazz");
        assert_eq!(genres[0].track_count, 1);
        assert_eq!(genres[0].artwork_path, "/cache/artwork/miles.img");

        assert_eq!(genres[1].genre, "Rock");
        assert_eq!(genres[1].track_count, 2);
        assert_eq!(genres[1].artwork_path, "/cache/artwork/band_a.img");

        assert_eq!(genres[2].genre, "Unknown Genre");
        assert_eq!(genres[2].track_count, 1);
        assert_eq!(genres[2].artwork_path, "");

        // 2. Verify get_tracks_by_genre()
        let rock_tracks = db.get_tracks_by_genre("Rock").unwrap();
        assert_eq!(rock_tracks.len(), 2);
        assert_eq!(rock_tracks[0].file_id, "t1");
        assert_eq!(rock_tracks[1].file_id, "t2");

        // Case-insensitive lookup
        let rock_tracks_lower = db.get_tracks_by_genre("rock").unwrap();
        assert_eq!(rock_tracks_lower.len(), 2);

        let jazz_tracks = db.get_tracks_by_genre("Jazz").unwrap();
        assert_eq!(jazz_tracks.len(), 1);
        assert_eq!(jazz_tracks[0].file_id, "t3");

        // Unknown Genre lookup
        let unknown_tracks = db.get_tracks_by_genre("Unknown Genre").unwrap();
        assert_eq!(unknown_tracks.len(), 1);
        assert_eq!(unknown_tracks[0].file_id, "t4");

        let empty_genre_tracks = db.get_tracks_by_genre("").unwrap();
        assert_eq!(empty_genre_tracks.len(), 1);
        assert_eq!(empty_genre_tracks[0].file_id, "t4");
    }

    #[test]
    fn test_hierarchical_folders_root_and_subfolder() {
        let mut db = MetadataDb::new_in_memory().unwrap();

        let placeholders = vec![
            TrackPlaceholder {
                file_id: "root_1".to_string(),
                name: "00. Root Intro.flac".to_string(),
                folder_path: "".to_string(),
                size_bytes: 5_000_000,
            },
            TrackPlaceholder {
                file_id: "music_direct".to_string(),
                name: "01. Music Track.flac".to_string(),
                folder_path: "Music".to_string(),
                size_bytes: 15_000_000,
            },
            TrackPlaceholder {
                file_id: "pf_1".to_string(),
                name: "01. Comfortably Numb.flac".to_string(),
                folder_path: "Music/Rock/Pink Floyd".to_string(),
                size_bytes: 10_000_000,
            },
            TrackPlaceholder {
                file_id: "pf_2".to_string(),
                name: "02. Time.flac".to_string(),
                folder_path: "Music/Rock/Pink Floyd".to_string(),
                size_bytes: 10_000_000,
            },
            TrackPlaceholder {
                file_id: "queen_1".to_string(),
                name: "01. Bohemian Rhapsody.flac".to_string(),
                folder_path: "Music/Rock/Queen".to_string(),
                size_bytes: 10_000_000,
            },
            TrackPlaceholder {
                file_id: "jazz_1".to_string(),
                name: "01. So What.flac".to_string(),
                folder_path: "Music/Jazz/Miles Davis".to_string(),
                size_bytes: 30_000_000,
            },
        ];
        db.batch_insert_placeholders(&placeholders).unwrap();

        // 1. Root folder query (parent_path = None, "", or "root")
        let root_folders = db.get_folders(None).unwrap();
        assert_eq!(root_folders.len(), 1);
        assert_eq!(root_folders[0].name, "Music");
        assert_eq!(root_folders[0].path, "Music");
        assert_eq!(root_folders[0].track_count, 5); // 1 direct + 2 pf + 1 queen + 1 jazz
        assert_eq!(root_folders[0].subfolder_count, 2); // Rock, Jazz
        assert_eq!(root_folders[0].total_size_bytes, 75_000_000);

        // 2. Immediate subfolders of "Music"
        let music_folders = db.get_folders(Some("Music")).unwrap();
        assert_eq!(music_folders.len(), 2);
        // Alphabetical: Jazz first, then Rock
        assert_eq!(music_folders[0].name, "Jazz");
        assert_eq!(music_folders[0].path, "Music/Jazz");
        assert_eq!(music_folders[0].track_count, 1);
        assert_eq!(music_folders[0].subfolder_count, 1); // Miles Davis
        assert_eq!(music_folders[0].total_size_bytes, 30_000_000);

        assert_eq!(music_folders[1].name, "Rock");
        assert_eq!(music_folders[1].path, "Music/Rock");
        assert_eq!(music_folders[1].track_count, 3); // 2 pf + 1 queen
        assert_eq!(music_folders[1].subfolder_count, 2); // Pink Floyd, Queen
        assert_eq!(music_folders[1].total_size_bytes, 30_000_000);

        // 3. Immediate subfolders of "Music/Rock"
        let rock_folders = db.get_folders(Some("Music/Rock")).unwrap();
        assert_eq!(rock_folders.len(), 2);
        assert_eq!(rock_folders[0].name, "Pink Floyd");
        assert_eq!(rock_folders[0].path, "Music/Rock/Pink Floyd");
        assert_eq!(rock_folders[0].track_count, 2);
        assert_eq!(rock_folders[0].subfolder_count, 0);

        assert_eq!(rock_folders[1].name, "Queen");
        assert_eq!(rock_folders[1].path, "Music/Rock/Queen");
        assert_eq!(rock_folders[1].track_count, 1);
        assert_eq!(rock_folders[1].subfolder_count, 0);

        // 4. Verify get_tracks_in_folder (non-recursive vs recursive)
        // Direct tracks in "Music" (non-recursive)
        let direct_music_tracks = db.get_tracks_in_folder("Music", false).unwrap();
        assert_eq!(direct_music_tracks.len(), 1);
        assert_eq!(direct_music_tracks[0].file_id, "music_direct");

        // All tracks under "Music" (recursive)
        let all_music_tracks = db.get_tracks_in_folder("Music", true).unwrap();
        assert_eq!(all_music_tracks.len(), 5);

        // Tracks in "Music/Rock/Pink Floyd"
        let pf_tracks = db
            .get_tracks_in_folder("Music/Rock/Pink Floyd", false)
            .unwrap();
        assert_eq!(pf_tracks.len(), 2);

        // Tracks at root
        let root_direct = db.get_tracks_in_folder("", false).unwrap();
        assert_eq!(root_direct.len(), 1);
        assert_eq!(root_direct[0].file_id, "root_1");

        let root_recursive = db.get_tracks_in_folder("", true).unwrap();
        assert_eq!(root_recursive.len(), 6);
    }

    #[test]
    fn test_batch_insert_local_tracks_and_prune() {
        let temp_dir = std::env::temp_dir().join(format!("bitdrop_test_db_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&temp_dir);
        let sub_dir = temp_dir.join("Hi-Res");
        std::fs::create_dir_all(&sub_dir).unwrap();

        let track1_path = sub_dir.join("song1.flac");
        let track2_path = temp_dir.join("song2.wav");
        let fake_path = sub_dir.join("missing.flac");

        std::fs::write(&track1_path, b"dummy audio data 1").unwrap();
        std::fs::write(&track2_path, b"dummy audio data 2").unwrap();

        let mut db = MetadataDb::new_in_memory().unwrap();

        let tracks = vec![
            LocalTrackInfo {
                path: track1_path.to_string_lossy().to_string(),
                name: "song1.flac".to_string(),
                folder_path: "Internal Storage / Hi-Res".to_string(),
                size_bytes: 18,
                title: "Song 1".to_string(),
                artist: "Artist 1".to_string(),
                album: "Album A".to_string(),
                album_artist: "Artist 1".to_string(),
                genre: "Jazz".to_string(),
                year: Some(2023),
                track_number: Some(1),
                disc_number: Some(1),
                duration_ms: 120_000,
                sample_rate: 96000,
                channels: 2,
                bits_per_sample: 24,
                artwork_path: None,
            },
            LocalTrackInfo {
                path: track2_path.to_string_lossy().to_string(),
                name: "song2.wav".to_string(),
                folder_path: "Internal Storage".to_string(),
                size_bytes: 18,
                title: "Song 2".to_string(),
                artist: "Artist 2".to_string(),
                album: "Album B".to_string(),
                album_artist: "Artist 2".to_string(),
                genre: "Classical".to_string(),
                year: Some(2021),
                track_number: Some(1),
                disc_number: Some(1),
                duration_ms: 180_000,
                sample_rate: 192000,
                channels: 2,
                bits_per_sample: 24,
                artwork_path: None,
            },
            LocalTrackInfo {
                path: fake_path.to_string_lossy().to_string(),
                name: "missing.flac".to_string(),
                folder_path: "Internal Storage / Hi-Res".to_string(),
                size_bytes: 100,
                title: "Song 3".to_string(),
                artist: "Artist 1".to_string(),
                album: "Album A".to_string(),
                album_artist: "Artist 1".to_string(),
                genre: "Jazz".to_string(),
                year: Some(2023),
                track_number: Some(2),
                disc_number: Some(1),
                duration_ms: 150_000,
                sample_rate: 96000,
                channels: 2,
                bits_per_sample: 24,
                artwork_path: None,
            },
        ];

        db.batch_insert_local_tracks(&tracks).unwrap();

        // 1. Verify tracks are inserted with tags_read = 1
        let albums = db.list_albums_summary().unwrap();
        assert_eq!(albums.len(), 2);
        let album_a = albums.iter().find(|a| a.album == "Album A").unwrap();
        assert_eq!(album_a.track_count, 2);
        assert_eq!(album_a.max_sample_rate, 96000);

        // 2. Folder queries
        let root_folders = db.get_folders(None).unwrap();
        assert_eq!(root_folders.len(), 1);
        assert_eq!(root_folders[0].name, "Internal Storage");
        assert_eq!(root_folders[0].track_count, 3);
        assert_eq!(root_folders[0].subfolder_count, 1);

        let subfolders = db.get_folders(Some("Internal Storage")).unwrap();
        assert_eq!(subfolders.len(), 1);
        assert_eq!(subfolders[0].name, "Hi-Res");
        assert_eq!(subfolders[0].track_count, 2);

        // 3. Prune missing track (fake_path doesn't exist)
        let pruned = db.prune_missing_local_tracks("Internal Storage").unwrap();
        assert_eq!(pruned, 1);

        // Verify fake_path track is removed
        assert!(db
            .get_track(&fake_path.to_string_lossy())
            .unwrap()
            .is_none());
        assert!(db
            .get_track(&track1_path.to_string_lossy())
            .unwrap()
            .is_some());

        // Verify album A track count updated to 1
        let albums_after = db.list_albums_summary().unwrap();
        let album_a_after = albums_after.iter().find(|a| a.album == "Album A").unwrap();
        assert_eq!(album_a_after.track_count, 1);

        // 4. Delete track1 and prune again
        std::fs::remove_file(&track1_path).unwrap();
        let pruned2 = db.prune_missing_local_tracks("Internal Storage").unwrap();
        assert_eq!(pruned2, 1);
        assert!(db
            .get_track(&track1_path.to_string_lossy())
            .unwrap()
            .is_none());
        assert!(db
            .get_track(&track2_path.to_string_lossy())
            .unwrap()
            .is_some());

        // Now Album A is empty and pruned from albums_summary
        let albums_final = db.list_albums_summary().unwrap();
        assert_eq!(albums_final.len(), 1);
        assert_eq!(albums_final[0].album, "Album B");

        let _ = std::fs::remove_dir_all(&temp_dir);
    }
}

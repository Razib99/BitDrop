use crate::cloud::models::FlacMetadata;
use rusqlite::{params, Connection, Result};
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
    /// False while only the filename is known, i.e. before the tag pass has
    /// reached this row. The UI shimmers these fields rather than hiding them.
    pub tags_read: bool,
}

pub struct MetadataDb {
    conn: Connection,
}

impl MetadataDb {
    pub fn new<P: AsRef<Path>>(path: P) -> Result<Self> {
        let conn = Connection::open(path)?;
        // The scan writes one row per file; WAL keeps reads responsive while
        // that is happening, so the library stays browsable during a scan.
        let _ = conn.pragma_update(None, "journal_mode", "WAL");
        let db = Self { conn };
        db.init_schema()?;
        Ok(db)
    }

    fn init_schema(&self) -> Result<()> {
        self.conn.execute(
            "CREATE TABLE IF NOT EXISTS tracks (
                file_id          TEXT PRIMARY KEY,
                name             TEXT NOT NULL DEFAULT '',
                folder_path      TEXT NOT NULL DEFAULT '',
                title            TEXT,
                artist           TEXT,
                album            TEXT,
                album_artist     TEXT,
                genre            TEXT,
                year             INTEGER,
                track_number     INTEGER,
                disc_number      INTEGER,
                duration_ms      INTEGER,
                sample_rate      INTEGER,
                channels         INTEGER,
                bits_per_sample  INTEGER,
                size_bytes       INTEGER,
                tags_read        INTEGER NOT NULL DEFAULT 0
            )",
            [],
        )?;
        // Album browsing and the artist screen both sort on these.
        self.conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_tracks_album ON tracks(album, disc_number, track_number)",
            [],
        )?;
        self.conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_tracks_artist ON tracks(artist)",
            [],
        )?;
        Ok(())
    }

    /// Records a file before its tags are known.
    ///
    /// The first scan pass does this for every file so the library is
    /// browsable within seconds; the tag pass fills the rest in afterwards.
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
                size_bytes = excluded.size_bytes",
            params![file_id, name, folder_path, size_bytes as i64],
        )?;
        Ok(())
    }

    /// Fills in a row once its FLAC metadata has been read over byte ranges.
    pub fn update_tags(&self, file_id: &str, meta: &FlacMetadata) -> Result<()> {
        // Vorbis comment keys are case-insensitive by spec but written
        // inconsistently in the wild, so look each one up either way.
        let tag = |keys: &[&str]| -> Option<String> {
            for k in keys {
                if let Some(v) = meta.tags.get(*k) {
                    return Some(v.clone());
                }
                if let Some(v) = meta.tags.get(&k.to_lowercase()) {
                    return Some(v.clone());
                }
            }
            None
        };

        // "3/12" means track 3 of 12.
        let number = |s: Option<String>| -> u32 {
            s.and_then(|v| v.split('/').next().and_then(|n| n.trim().parse().ok()))
                .unwrap_or(0)
        };

        let year = tag(&["DATE", "YEAR", "ORIGINALDATE"])
            .and_then(|v| v.get(0..4).and_then(|y| y.parse::<u32>().ok()))
            .unwrap_or(0);

        let si = &meta.stream_info;
        self.conn.execute(
            "UPDATE tracks SET
                title = ?2, artist = ?3, album = ?4, album_artist = ?5,
                genre = ?6, year = ?7, track_number = ?8, disc_number = ?9,
                duration_ms = ?10, sample_rate = ?11, channels = ?12,
                bits_per_sample = ?13, tags_read = 1
             WHERE file_id = ?1",
            params![
                file_id,
                tag(&["TITLE"]),
                tag(&["ARTIST"]),
                tag(&["ALBUM"]),
                tag(&["ALBUMARTIST", "ALBUM ARTIST"]),
                tag(&["GENRE"]),
                year,
                number(tag(&["TRACKNUMBER"])),
                number(tag(&["DISCNUMBER"])).max(1),
                (si.duration_seconds * 1000.0) as u32,
                si.sample_rate,
                si.channels as u32,
                si.bits_per_sample as u32,
            ],
        )?;
        Ok(())
    }

    pub fn list_tracks(&self) -> Result<Vec<CloudTrackRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT file_id, name, folder_path, title, artist, album,
                    album_artist, genre, year, track_number, disc_number,
                    duration_ms, sample_rate, channels, bits_per_sample,
                    size_bytes, tags_read
             FROM tracks
             ORDER BY album, disc_number, track_number, name",
        )?;

        let rows = stmt.query_map([], |r| {
            let name: String = r.get(1)?;
            let title: Option<String> = r.get(3)?;
            Ok(CloudTrackRow {
                file_id: r.get(0)?,
                name: name.clone(),
                folder_path: r.get(2)?,
                // Before the tag pass, the filename stands in for the title.
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
            })
        })?;

        rows.collect()
    }

    /// File ids still awaiting the tag pass, oldest first.
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

    pub fn clear(&self) -> Result<()> {
        self.conn.execute("DELETE FROM tracks", [])?;
        Ok(())
    }
}

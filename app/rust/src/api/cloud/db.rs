use rusqlite::{params, Connection, Result};
use std::path::Path;
use crate::api::cloud::models::FlacMetadata;

pub struct MetadataDb {
    conn: Connection,
}

impl MetadataDb {
    pub fn new<P: AsRef<Path>>(path: P) -> Result<Self> {
        let conn = Connection::open(path)?;
        let db = Self { conn };
        db.init_schema()?;
        Ok(db)
    }

    fn init_schema(&self) -> Result<()> {
        self.conn.execute(
            "CREATE TABLE IF NOT EXISTS tracks (
                id TEXT PRIMARY KEY,
                file_id TEXT NOT NULL,
                title TEXT,
                artist TEXT,
                album TEXT,
                track_number INTEGER,
                duration REAL,
                sample_rate INTEGER,
                channels INTEGER,
                bits_per_sample INTEGER
            )",
            [],
        )?;
        Ok(())
    }

    pub fn insert_track(&self, file_id: &str, meta: &FlacMetadata) -> Result<()> {
        let title = meta.tags.get("TITLE").cloned();
        let artist = meta.tags.get("ARTIST").cloned();
        let album = meta.tags.get("ALBUM").cloned();
        let track_number: Option<u32> = meta.tags.get("TRACKNUMBER").and_then(|s| s.parse().ok());

        self.conn.execute(
            "INSERT OR REPLACE INTO tracks (
                id, file_id, title, artist, album, track_number, 
                duration, sample_rate, channels, bits_per_sample
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![
                file_id, // using file_id as primary key for now
                file_id,
                title,
                artist,
                album,
                track_number,
                meta.stream_info.duration_seconds,
                meta.stream_info.sample_rate,
                meta.stream_info.channels,
                meta.stream_info.bits_per_sample,
            ],
        )?;
        Ok(())
    }
}

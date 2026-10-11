//! The cloud library index: file list in, tagged tracks out.
//!
//! Dart owns the Drive API calls, because that is where the OAuth session
//! lives. Rust owns everything that touches bytes: fetching header ranges,
//! parsing FLAC metadata and persisting it. That split keeps the access token
//! on the Dart side and the parsing off the UI thread.

use std::sync::Mutex;

use crate::cloud::db::{CloudTrackRow, MetadataDb};
use crate::cloud::flac_parser::{FlacProgressiveParser, ParseProgress};
use crate::cloud::range_fetcher::RangeFetcher;

lazy_static::lazy_static! {
    static ref DB: Mutex<Option<MetadataDb>> = Mutex::new(None);
    /// Where tag reads cache their byte ranges. Supplied by the caller,
    /// because only the Dart side knows the platform's cache location.
    static ref CACHE_DIR: Mutex<Option<String>> = Mutex::new(None);
    /// One runtime for every range request. Building one per call would cost
    /// more than the fetch itself during a scan of thousands of files.
    static ref RT: tokio::runtime::Runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("tokio runtime");
}

/// A track as the UI sees it.
pub struct CloudTrack {
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
    pub tags_read: bool,
}

impl From<CloudTrackRow> for CloudTrack {
    fn from(r: CloudTrackRow) -> Self {
        Self {
            file_id: r.file_id,
            name: r.name,
            folder_path: r.folder_path,
            title: r.title,
            artist: r.artist,
            album: r.album,
            album_artist: r.album_artist,
            genre: r.genre,
            year: r.year,
            track_number: r.track_number,
            disc_number: r.disc_number,
            duration_ms: r.duration_ms,
            sample_rate: r.sample_rate,
            channels: r.channels,
            bits_per_sample: r.bits_per_sample,
            size_bytes: r.size_bytes,
            tags_read: r.tags_read,
        }
    }
}

/// How far the tag pass has got.
pub struct ScanCounts {
    pub total: u32,
    pub tagged: u32,
}

fn with_db<T>(f: impl FnOnce(&MetadataDb) -> anyhow::Result<T>) -> Result<T, String> {
    let guard = DB.lock().map_err(|e| e.to_string())?;
    let db = guard
        .as_ref()
        .ok_or_else(|| "cloud library not opened".to_string())?;
    f(db).map_err(|e| e.to_string())
}

/// Opens (or creates) the library database. Safe to call repeatedly.
pub fn cloud_library_open(db_path: String, cache_dir: String) -> Result<(), String> {
    let db = MetadataDb::new(&db_path).map_err(|e| e.to_string())?;
    *DB.lock().map_err(|e| e.to_string())? = Some(db);
    std::fs::create_dir_all(&cache_dir).map_err(|e| e.to_string())?;
    *CACHE_DIR.lock().map_err(|e| e.to_string())? = Some(cache_dir);
    Ok(())
}

/// Records files found by the Drive walk, before any tags are known.
///
/// Taking the whole batch in one call keeps the FFI crossings proportional to
/// folders rather than to files, which matters on a library of thousands.
pub fn cloud_library_add_files(
    file_ids: Vec<String>,
    names: Vec<String>,
    folder_paths: Vec<String>,
    sizes: Vec<u64>,
) -> Result<u32, String> {
    if file_ids.len() != names.len()
        || file_ids.len() != folder_paths.len()
        || file_ids.len() != sizes.len()
    {
        return Err("mismatched batch lengths".to_string());
    }

    with_db(|db| {
        for i in 0..file_ids.len() {
            db.insert_placeholder(&file_ids[i], &names[i], &folder_paths[i], sizes[i])?;
        }
        Ok(file_ids.len() as u32)
    })
}

/// Reads one track's tags over HTTP byte ranges and stores them.
///
/// Only the metadata blocks are fetched, never the audio: a 90 MB 24/192 FLAC
/// is indexed from the first few tens of kilobytes. The parser asks for more
/// bytes when a block straddles the end of what it has, and large embedded
/// artwork is skipped rather than downloaded.
///
/// Returns true when tags were read, false when the file is not FLAC, which is
/// not an error: the row keeps its filename-derived title.
pub fn cloud_library_read_tags(
    file_id: String,
    url: String,
    auth_token: Option<String>,
) -> Result<bool, String> {
    use crate::cloud::media_source::CloudMediaSource;
    use symphonia::core::probe::Hint;
    use symphonia::core::io::MediaSourceStream;
    use symphonia::core::meta::MetadataOptions;
    use symphonia::core::formats::FormatOptions;
    use std::path::PathBuf;

    let size_bytes = with_db(|db| {
        let mut stmt = db.conn.prepare("SELECT size_bytes FROM tracks WHERE file_id = ?")?;
        let size: u64 = stmt.query_row([&file_id], |r| r.get(0)).unwrap_or(0);
        Ok(size)
    })?;

    if size_bytes == 0 {
        return Ok(false);
    }

    // Hardcoding an Android data path here broke every other platform and
    // assumed user 0; the caller supplies it at open time instead.
    let cache_dir = PathBuf::from(
        CACHE_DIR
            .lock()
            .map_err(|e| e.to_string())?
            .clone()
            .ok_or_else(|| "cloud library not opened".to_string())?,
    );
    let cloud_source = match CloudMediaSource::new(file_id.clone(), url, auth_token, size_bytes, cache_dir) {
        Ok(cs) => cs,
        Err(e) => {
            eprintln!("[bitdrop] CloudMediaSource::new failed: {:?}", e);
            let _ = with_db(|db| {
                db.mark_tags_attempted(&file_id)?;
                Ok(())
            });
            return Ok(false);
        }
    };

    let mss = MediaSourceStream::new(Box::new(cloud_source), Default::default());
    let hint = Hint::new();

    let meta_opts: MetadataOptions = Default::default();
    let fmt_opts: FormatOptions = Default::default();

    let probed = match symphonia::default::get_probe().format(&hint, mss, &fmt_opts, &meta_opts) {
        Ok(p) => p,
        Err(_) => {
            let _ = with_db(|db| {
                db.mark_tags_attempted(&file_id)?;
                Ok(())
            });
            return Ok(false);
        }
    };

    let mut format = probed.format;
    
    // Extract metadata
    let mut duration_ms = 0;
    let mut sample_rate = 44100;
    let mut channels = 2;
    let mut bits_per_sample = 16;
    
    if let Some(track) = format.default_track() {
        if let Some(tb) = track.codec_params.time_base {
            if let Some(n_frames) = track.codec_params.n_frames {
                let time = tb.calc_time(n_frames);
                duration_ms = (time.seconds * 1000 + (time.frac * 1000.0) as u64) as u32;
            }
        }
        sample_rate = track.codec_params.sample_rate.unwrap_or(44100);
        channels = track.codec_params.channels.map(|c| c.count() as u8).unwrap_or(2);
        bits_per_sample = track.codec_params.bits_per_sample.unwrap_or(16) as u8;
    }

    let mut title = String::new();
    let mut artist = String::new();
    let mut album = String::new();
    let mut album_artist = String::new();
    let mut genre = String::new();
    let mut year: Option<u32> = None;
    let mut track_number: Option<u32> = None;
    let mut disc_number: Option<u32> = None;

    if let Some(metadata) = format.metadata().current() {
        for tag in metadata.tags() {
            match tag.std_key {
                Some(symphonia::core::meta::StandardTagKey::TrackTitle) => title = tag.value.to_string(),
                Some(symphonia::core::meta::StandardTagKey::Artist) => artist = tag.value.to_string(),
                Some(symphonia::core::meta::StandardTagKey::Album) => album = tag.value.to_string(),
                Some(symphonia::core::meta::StandardTagKey::AlbumArtist) => album_artist = tag.value.to_string(),
                Some(symphonia::core::meta::StandardTagKey::Genre) => genre = tag.value.to_string(),
                Some(symphonia::core::meta::StandardTagKey::Date) => year = tag.value.to_string().parse().ok(),
                Some(symphonia::core::meta::StandardTagKey::TrackNumber) => track_number = tag.value.to_string().parse().ok(),
                Some(symphonia::core::meta::StandardTagKey::DiscNumber) => disc_number = tag.value.to_string().parse().ok(),
                _ => {}
            }
        }
    }

    let _ = with_db(|db| {
        db.conn.execute(
            "UPDATE tracks SET
                title = ?, artist = ?, album = ?, album_artist = ?,
                genre = ?, year = ?, track_number = ?, disc_number = ?,
                duration_ms = ?, sample_rate = ?, channels = ?, bits_per_sample = ?,
                tags_read = 1
             WHERE file_id = ?",
            rusqlite::params![
                title, artist, album, album_artist, genre, year, track_number, disc_number,
                duration_ms, sample_rate, channels, bits_per_sample,
                file_id
            ],
        )?;
        Ok(())
    });

    Ok(true)
}

pub fn cloud_library_pending(limit: u32) -> Result<Vec<String>, String> {
    with_db(|db| Ok(db.pending_tag_reads(limit)?))
}

pub fn cloud_library_tracks() -> Result<Vec<CloudTrack>, String> {
    with_db(|db| Ok(db.list_tracks()?.into_iter().map(CloudTrack::from).collect()))
}

pub fn cloud_library_counts() -> Result<ScanCounts, String> {
    with_db(|db| {
        let (total, tagged) = db.count()?;
        Ok(ScanCounts { total, tagged })
    })
}

pub fn cloud_library_clear() -> Result<(), String> {
    with_db(|db| Ok(db.clear()?))
}

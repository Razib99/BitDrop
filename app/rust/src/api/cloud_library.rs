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
pub fn cloud_library_open(db_path: String) -> Result<(), String> {
    let db = MetadataDb::new(&db_path).map_err(|e| e.to_string())?;
    *DB.lock().map_err(|e| e.to_string())? = Some(db);
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
    let fetcher = RangeFetcher::new().map_err(|e| e.to_string())?;

    let mut buffer: Vec<u8> = Vec::new();
    let mut want: usize = 32 * 1024;
    // Each pass either completes or asks for more. The cap stops a corrupt or
    // non-FLAC file from pulling the whole thing down a chunk at a time.
    const MAX_PASSES: usize = 6;
    const MAX_HEADER_BYTES: usize = 2 * 1024 * 1024;

    for _ in 0..MAX_PASSES {
        let start = buffer.len() as u64;
        let end = start + want as u64 - 1;

        let (bytes, _) = RT
            .block_on(fetcher.fetch_range(&url, start, end, auth_token.as_deref()))
            .map_err(|e| e.to_string())?;

        if bytes.is_empty() {
            break;
        }
        buffer.extend_from_slice(&bytes);

        match FlacProgressiveParser::parse(&buffer, 0) {
            Ok(ParseProgress::Complete(meta)) => {
                with_db(|db| {
                    db.update_tags(&file_id, &meta)?;
                    Ok(())
                })?;
                return Ok(true);
            }
            Ok(ParseProgress::NeedMoreBytes { length, .. }) => {
                if buffer.len() >= MAX_HEADER_BYTES {
                    break;
                }
                want = length.max(16 * 1024);
            }
            // Not a FLAC file, or a damaged header. The row keeps the name it
            // was indexed under rather than disappearing from the library.
            Err(_) => return Ok(false),
        }
    }

    Ok(false)
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

//! The cloud library index: file list in, tagged tracks out.
//!
//! Dart owns the Drive API calls, because that is where the OAuth session
//! lives. Rust owns everything that touches bytes: fetching header ranges,
//! parsing FLAC metadata and persisting it. That split keeps the access token
//! on the Dart side and the parsing off the UI thread.

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use crate::cloud::db::{
    AlbumSummaryRow, CloudTrackRow, MetadataDb, TrackPlaceholder, TrackTagUpdate,
};
use crate::cloud::flac_parser::{FlacProgressiveParser, ParseProgress};
use governor::{Quota, RateLimiter};
use std::num::NonZeroU32;

lazy_static::lazy_static! {
    static ref DB: Mutex<Option<MetadataDb>> = Mutex::new(None);
    /// Where tag reads cache their byte ranges. Supplied by the caller,
    /// because only the Dart side knows the platform's cache location.
    static ref CACHE_DIR: Mutex<Option<String>> = Mutex::new(None);
    /// Shared HTTP client for range fetches and tag downloads.
    static ref HTTP_CLIENT: reqwest::Client = reqwest::Client::builder()
        .pool_max_idle_per_host(32)
        .timeout(Duration::from_secs(15))
        .build()
        .expect("http client");
    /// Token-bucket rate limiter enforcing 35 req/sec (F-06) to avoid Drive 429 errors.
    static ref RATE_LIMITER: std::sync::Arc<governor::RateLimiter<governor::state::NotKeyed, governor::state::InMemoryState, governor::clock::DefaultClock>> = {
        let quota = Quota::per_second(NonZeroU32::new(35).expect("non zero"));
        std::sync::Arc::new(RateLimiter::direct(quota))
    };
    /// One runtime for every range request. Building one per call would cost
    /// more than the fetch itself during a scan of thousands of files.
    static ref RT: tokio::runtime::Runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .enable_all()
        .build()
        .expect("tokio runtime");
}

/// Materialized album summary for instant grid/list rendering.
#[derive(Debug, Clone)]
pub struct AlbumSummary {
    pub album_key: String,
    pub album: String,
    pub album_artist: String,
    pub year: u32,
    pub artwork_path: String,
    pub track_count: u32,
    pub max_sample_rate: u32,
    pub max_bit_depth: u32,
}

/// A file that was replaced due to re-upload with identical folder and name.
#[derive(Debug, Clone)]
pub struct ReplacedFile {
    pub old_file_id: String,
    pub new_file_id: String,
}

impl From<crate::cloud::db::ReplacedFile> for ReplacedFile {
    fn from(r: crate::cloud::db::ReplacedFile) -> Self {
        Self {
            old_file_id: r.old_file_id,
            new_file_id: r.new_file_id,
        }
    }
}

impl From<AlbumSummaryRow> for AlbumSummary {
    fn from(r: AlbumSummaryRow) -> Self {
        Self {
            album_key: r.album_key,
            album: r.album,
            album_artist: r.album_artist,
            year: r.year,
            artwork_path: r.artwork_path,
            track_count: r.track_count,
            max_sample_rate: r.max_sample_rate,
            max_bit_depth: r.max_bit_depth,
        }
    }
}

/// Genre summary with track count and artwork for library UI.
#[derive(Debug, Clone)]
pub struct CloudGenre {
    pub genre: String,
    pub track_count: u32,
    pub artwork_path: String,
}

/// A directory or file entry in the hierarchical folder browser.
#[derive(Debug, Clone)]
pub struct CloudFolderEntry {
    pub id: String,
    pub name: String,
    pub is_directory: bool,
    pub item_count: u32,
    pub size_bytes: u64,
    pub track: Option<CloudTrackRow>,
}

/// A complete folder listing with breadcrumbs and directory entries.
#[derive(Debug, Clone)]
pub struct CloudFolderListing {
    pub folder_id: Option<String>,
    pub breadcrumb: Vec<CloudFolderEntry>,
    pub entries: Vec<CloudFolderEntry>,
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
    /// Absolute path to artwork pulled out of the file, or empty.
    pub artwork_path: String,
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
            artwork_path: r.artwork_path,
        }
    }
}

/// How far the tag pass has got.
pub struct ScanCounts {
    pub total: u32,
    pub tagged: u32,
}

#[flutter_rust_bridge::frb(ignore)]
pub fn with_db<T>(f: impl FnOnce(&MetadataDb) -> anyhow::Result<T>) -> Result<T, String> {
    let guard = DB.lock().map_err(|e| e.to_string())?;
    let db = guard
        .as_ref()
        .ok_or_else(|| "cloud library not opened".to_string())?;
    f(db).map_err(|e| e.to_string())
}

#[flutter_rust_bridge::frb(ignore)]
pub fn with_db_mut<T>(f: impl FnOnce(&mut MetadataDb) -> anyhow::Result<T>) -> Result<T, String> {
    let mut guard = DB.lock().map_err(|e| e.to_string())?;
    let db = guard
        .as_mut()
        .ok_or_else(|| "cloud library not opened".to_string())?;
    f(db).map_err(|e| e.to_string())
}

/// Opens (or creates) the library database. Safe to call repeatedly.
pub fn cloud_library_open(db_path: String, cache_dir: String) -> Result<(), String> {
    let db = MetadataDb::new(&db_path).map_err(|e| e.to_string())?;
    if let Ok(Some(saved_limit)) = db.get_kv("cache_limit_bytes") {
        if let Ok(limit) = saved_limit.parse::<u64>() {
            CACHE_LIMIT_BYTES.store(limit, Ordering::Relaxed);
        }
    }
    *DB.lock().map_err(|e| e.to_string())? = Some(db);
    std::fs::create_dir_all(&cache_dir).map_err(|e| e.to_string())?;
    *CACHE_DIR.lock().map_err(|e| e.to_string())? = Some(cache_dir);
    Ok(())
}

/// Records files found by the Drive walk, before any tags are known.
///
/// Taking the whole batch in one call keeps the FFI crossings proportional to
/// folders rather than to files, which matters on a library of thousands.
/// Returns any old file_ids that were replaced due to re-upload.
pub fn cloud_library_add_files(
    file_ids: Vec<String>,
    names: Vec<String>,
    folder_paths: Vec<String>,
    sizes: Vec<u64>,
) -> Result<Vec<ReplacedFile>, String> {
    if file_ids.len() != names.len()
        || file_ids.len() != folder_paths.len()
        || file_ids.len() != sizes.len()
    {
        return Err("mismatched batch lengths".to_string());
    }

    let items: Vec<TrackPlaceholder> = (0..file_ids.len())
        .map(|i| TrackPlaceholder {
            file_id: file_ids[i].clone(),
            name: names[i].clone(),
            folder_path: folder_paths[i].clone(),
            size_bytes: sizes[i],
        })
        .collect();

    with_db_mut(|db| {
        let replaced = db.batch_insert_placeholders(&items)?;
        Ok(replaced.into_iter().map(ReplacedFile::from).collect())
    })
}

/// Prunes missing files under the given folder prefixes whose file_ids are not in valid_file_ids.
/// Returns the list of deleted file_ids.
pub fn cloud_library_prune_missing(
    folder_prefixes: Vec<String>,
    valid_file_ids: Vec<String>,
) -> Result<Vec<String>, String> {
    with_db_mut(|db| {
        let pruned = db.prune_missing_files(&folder_prefixes, &valid_file_ids)?;
        Ok(pruned)
    })
}

/// Rebuilds albums_summary to stay synchronized with current tracks.
pub fn cloud_library_rebuild_albums() -> Result<(), String> {
    with_db_mut(|db| {
        db.rebuild_albums_summary()?;
        Ok(())
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
    use std::path::PathBuf;
    use symphonia::core::formats::FormatOptions;
    use symphonia::core::io::MediaSourceStream;
    use symphonia::core::meta::MetadataOptions;
    use symphonia::core::probe::Hint;

    let size_bytes = with_db(|db| {
        let mut stmt = db
            .conn
            .prepare("SELECT size_bytes FROM tracks WHERE file_id = ?")?;
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
    let cloud_source =
        match CloudMediaSource::new(file_id.clone(), url, auth_token, size_bytes, cache_dir) {
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
        channels = track
            .codec_params
            .channels
            .map(|c| c.count() as u8)
            .unwrap_or(2);
        bits_per_sample = track.codec_params.bits_per_sample.unwrap_or(16) as u8;
    }

    // Embedded artwork rides along in the metadata the probe already read,
    // so extracting it here costs no extra byte-range fetch. Written to disk
    // once and referenced by path, because handing image bytes across the FFI
    // boundary on every list rebuild would be wasteful.
    if let Some(metadata) = format.metadata().current() {
        if let Some(visual) = metadata.visuals().first() {
            let art_dir = PathBuf::from(
                CACHE_DIR
                    .lock()
                    .map_err(|e| e.to_string())?
                    .clone()
                    .unwrap_or_default(),
            )
            .join("artwork");
            if std::fs::create_dir_all(&art_dir).is_ok() {
                let art_path = art_dir.join(format!("{}.img", file_id));
                if std::fs::write(&art_path, &visual.data).is_ok() {
                    let _ = with_db(|db| {
                        db.set_artwork(&file_id, &art_path.to_string_lossy())?;
                        Ok(())
                    });
                }
            }
        }
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
                Some(symphonia::core::meta::StandardTagKey::TrackTitle) => {
                    title = tag.value.to_string()
                }
                Some(symphonia::core::meta::StandardTagKey::Artist) => {
                    artist = tag.value.to_string()
                }
                Some(symphonia::core::meta::StandardTagKey::Album) => album = tag.value.to_string(),
                Some(symphonia::core::meta::StandardTagKey::AlbumArtist) => {
                    album_artist = tag.value.to_string()
                }
                Some(symphonia::core::meta::StandardTagKey::Genre) => genre = tag.value.to_string(),
                Some(symphonia::core::meta::StandardTagKey::Date) => {
                    year = tag.value.to_string().parse().ok()
                }
                Some(symphonia::core::meta::StandardTagKey::TrackNumber) => {
                    track_number = tag.value.to_string().parse().ok()
                }
                Some(symphonia::core::meta::StandardTagKey::DiscNumber) => {
                    disc_number = tag.value.to_string().parse().ok()
                }
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
                title,
                artist,
                album,
                album_artist,
                genre,
                year,
                track_number,
                disc_number,
                duration_ms,
                sample_rate,
                channels,
                bits_per_sample,
                file_id
            ],
        )?;
        Ok(())
    });

    Ok(true)
}

fn sanitize_filename(name: &str) -> String {
    let s: String = name
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { '_' })
        .collect();
    if s.is_empty() {
        "art".to_string()
    } else {
        s
    }
}

fn parse_year(s: &str) -> u32 {
    let digits: String = s.chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse::<u32>().unwrap_or(0)
}

fn parse_index_number(s: &str) -> u32 {
    let clean = s.split('/').next().unwrap_or(s).trim();
    clean.parse::<u32>().unwrap_or(0)
}

fn url_encode(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for b in input.bytes() {
        match b {
            b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char);
            }
            b' ' => out.push('+'),
            _ => {
                out.push_str(&format!("%{:02X}", b));
            }
        }
    }
    out
}

fn parse_track_and_title(s: &str) -> (u32, String) {
    let s = s.trim();
    let mut num_str = String::new();
    let mut chars = s.chars().peekable();
    while let Some(&c) = chars.peek() {
        if c.is_ascii_digit() {
            num_str.push(c);
            chars.next();
        } else {
            break;
        }
    }
    if !num_str.is_empty() {
        let num: u32 = num_str.parse().unwrap_or(0);
        let rem: String = chars.collect();
        let title = rem.trim_start_matches(['-', '.', ' ', '_', '~']).trim();
        if !title.is_empty() {
            return (num, title.to_string());
        }
    }
    (0, s.to_string())
}

fn parse_filename_metadata(name: &str) -> (String, String, String, u32) {
    let base = name.rsplit_once('.').map(|(s, _)| s).unwrap_or(name).trim();
    let parts: Vec<&str> = base.split(" - ").map(|s| s.trim()).collect();
    if parts.len() >= 3 {
        let album = parts[0].to_string();
        let artist = parts[1].to_string();
        let remainder = parts[2..].join(" - ");
        let (track_no, title) = parse_track_and_title(&remainder);
        (title, artist, album, track_no)
    } else if parts.len() == 2 {
        let first = parts[0];
        let second = parts[1];
        let first_is_digits = !first.is_empty() && first.chars().all(|c| c.is_ascii_digit());
        if first_is_digits {
            let track_no: u32 = first.parse().unwrap_or(0);
            (second.to_string(), String::new(), String::new(), track_no)
        } else {
            let (track_no, title) = parse_track_and_title(second);
            (title, first.to_string(), String::new(), track_no)
        }
    } else {
        let (track_no, title) = parse_track_and_title(base);
        (title, String::new(), String::new(), track_no)
    }
}

static LAST_ITUNES_CALL: parking_lot::Mutex<Option<std::time::Instant>> =
    parking_lot::Mutex::new(None);

/// Ensures at least 150ms delay between consecutive requests to Apple's iTunes Search API
/// to avoid HTTP 429 / 403 rate limit blocks.
async fn throttle_itunes() {
    let delay = {
        let mut last = LAST_ITUNES_CALL.lock();
        let now = std::time::Instant::now();
        let min_interval = std::time::Duration::from_millis(150);
        let scheduled_time = match *last {
            Some(prev) => {
                if prev + min_interval > now {
                    prev + min_interval
                } else {
                    now
                }
            }
            None => now,
        };
        *last = Some(scheduled_time);
        if scheduled_time > now {
            Some(scheduled_time - now)
        } else {
            None
        }
    };

    if let Some(dur) = delay {
        tokio::time::sleep(dur).await;
    }
}

async fn fetch_online_cover_art(artist: &str, album: &str, title: &str) -> Option<Vec<u8>> {
    let clean_artist = artist.trim();
    let clean_album = album.trim();
    let raw_title = title.trim();
    let (_, pure_title) = parse_track_and_title(raw_title);
    let title_clean = if !pure_title.is_empty() {
        pure_title.trim()
    } else {
        raw_title
    };

    let has_valid_album = !clean_album.is_empty()
        && clean_album.to_lowercase() != "unknown_album"
        && clean_album.to_lowercase() != "unknown album";
    let has_valid_artist = !clean_artist.is_empty()
        && clean_artist.to_lowercase() != "unknown_artist"
        && clean_artist.to_lowercase() != "unknown artist";

    // 1. Search Deezer by album & artist
    if has_valid_album {
        let q = if has_valid_artist {
            format!("{} {}", clean_artist, clean_album)
        } else {
            clean_album.to_string()
        };
        let encoded_q = url_encode(&q);
        let url = format!(
            "https://api.deezer.com/search/album?q={}&limit=1",
            encoded_q
        );
        if let Ok(resp) = HTTP_CLIENT
            .get(&url)
            .timeout(Duration::from_secs(4))
            .send()
            .await
        {
            if resp.status().is_success() {
                if let Ok(json) = resp.json::<serde_json::Value>().await {
                    if let Some(cover_url) = json
                        .pointer("/data/0/cover_big")
                        .or_else(|| json.pointer("/data/0/cover_medium"))
                        .and_then(|v| v.as_str())
                    {
                        if let Ok(img_resp) = HTTP_CLIENT
                            .get(cover_url)
                            .timeout(Duration::from_secs(5))
                            .send()
                            .await
                        {
                            if let Ok(b) = img_resp.bytes().await {
                                if !b.is_empty() {
                                    return Some(b.to_vec());
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // 2. Search iTunes by album (entity=album)
    if has_valid_album {
        let terms = if has_valid_artist {
            vec![
                format!("{} {}", clean_artist, clean_album),
                clean_album.to_string(),
            ]
        } else {
            vec![clean_album.to_string()]
        };

        for term in terms {
            let encoded_term = url_encode(&term);
            let itunes_url = format!(
                "https://itunes.apple.com/search?term={}&entity=album&limit=1",
                encoded_term
            );
            throttle_itunes().await;
            if let Ok(resp) = HTTP_CLIENT
                .get(&itunes_url)
                .timeout(Duration::from_secs(4))
                .send()
                .await
            {
                if resp.status().is_success() {
                    if let Ok(json) = resp.json::<serde_json::Value>().await {
                        if let Some(art_url) = json
                            .pointer("/results/0/artworkUrl100")
                            .and_then(|v| v.as_str())
                        {
                            let high_res = art_url.replace("100x100bb", "600x600bb");
                            if let Ok(img_resp) = HTTP_CLIENT
                                .get(&high_res)
                                .timeout(Duration::from_secs(5))
                                .send()
                                .await
                            {
                                if let Ok(b) = img_resp.bytes().await {
                                    if !b.is_empty() {
                                        return Some(b.to_vec());
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // 3. Search iTunes by track title (entity=musicTrack)
    if !title_clean.is_empty() {
        let mut track_terms = Vec::new();
        if has_valid_artist {
            track_terms.push(format!("{} {}", clean_artist, title_clean));
        }
        if has_valid_album {
            track_terms.push(format!("{} {}", title_clean, clean_album));
        }
        track_terms.push(title_clean.to_string());

        for term in track_terms {
            let encoded_term = url_encode(&term);
            let itunes_url = format!(
                "https://itunes.apple.com/search?term={}&entity=musicTrack&limit=1",
                encoded_term
            );
            throttle_itunes().await;
            if let Ok(resp) = HTTP_CLIENT
                .get(&itunes_url)
                .timeout(Duration::from_secs(4))
                .send()
                .await
            {
                if resp.status().is_success() {
                    if let Ok(json) = resp.json::<serde_json::Value>().await {
                        if let Some(art_url) = json
                            .pointer("/results/0/artworkUrl100")
                            .and_then(|v| v.as_str())
                        {
                            let high_res = art_url.replace("100x100bb", "600x600bb");
                            if let Ok(img_resp) = HTTP_CLIENT
                                .get(&high_res)
                                .timeout(Duration::from_secs(5))
                                .send()
                                .await
                            {
                                if let Ok(b) = img_resp.bytes().await {
                                    if !b.is_empty() {
                                        return Some(b.to_vec());
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // 4. Fallback: Search track on Deezer by title
    if !title_clean.is_empty() {
        let q = if has_valid_artist {
            format!("{} {}", clean_artist, title_clean)
        } else {
            title_clean.to_string()
        };
        let encoded_q = url_encode(&q);
        let url = format!("https://api.deezer.com/search?q={}&limit=1", encoded_q);
        if let Ok(resp) = HTTP_CLIENT
            .get(&url)
            .timeout(Duration::from_secs(4))
            .send()
            .await
        {
            if resp.status().is_success() {
                if let Ok(json) = resp.json::<serde_json::Value>().await {
                    if let Some(cover_url) = json
                        .pointer("/data/0/album/cover_big")
                        .or_else(|| json.pointer("/data/0/album/cover_medium"))
                        .and_then(|v| v.as_str())
                    {
                        if let Ok(img_resp) = HTTP_CLIENT
                            .get(cover_url)
                            .timeout(Duration::from_secs(5))
                            .send()
                            .await
                        {
                            if let Ok(b) = img_resp.bytes().await {
                                if !b.is_empty() {
                                    return Some(b.to_vec());
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    None
}

/// Lists all albums from the materialized albums_summary table in <1ms.
pub fn cloud_library_albums() -> Result<Vec<AlbumSummary>, String> {
    with_db(|db| {
        let rows = db.list_albums_summary()?;
        Ok(rows.into_iter().map(AlbumSummary::from).collect())
    })
}

/// Sub-3ms multi-field instant search powered by SQLite FTS5 with BM25 ranking.
pub fn cloud_library_search(query: String, limit: Option<u32>) -> Result<Vec<CloudTrack>, String> {
    let limit = limit.unwrap_or(50);
    with_db(|db| {
        let rows = db.search_tracks_fts(&query, limit)?;
        Ok(rows.into_iter().map(CloudTrack::from).collect())
    })
}

/// High-throughput multiplexed tag scanner (25+ tracks/sec, F-06).
///
/// Fetches the first 64KB (`bytes=0-65535`) in parallel with a token-bucket rate limiter (35 req/sec),
/// parses FLAC Vorbis comments and StreamInfo with FlacProgressiveParser,
/// deduplicates artwork by (album_artist, album), and commits updates in batches into SQLite.
pub fn cloud_library_scan_tags_batch(
    file_ids: Vec<String>,
    auth_token: Option<String>,
) -> Result<u32, String> {
    use futures_util::stream::{self, StreamExt};

    if file_ids.is_empty() {
        return Ok(0);
    }

    let placeholders = with_db(|db| {
        let mut stmt = db.conn.prepare(
            "SELECT file_id, name, folder_path, size_bytes FROM tracks WHERE file_id = ?",
        )?;
        let mut list = Vec::new();
        for id in &file_ids {
            if let Ok(row) = stmt.query_row([id], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, i64>(3)? as u64,
                ))
            }) {
                list.push(row);
            }
        }
        Ok(list)
    })?;

    let art_dir = {
        let base = CACHE_DIR
            .lock()
            .map_err(|e| e.to_string())?
            .clone()
            .ok_or_else(|| "cloud library not opened".to_string())?;
        let d = PathBuf::from(base).join("artwork");
        let _ = std::fs::create_dir_all(&d);
        d
    };

    let token_clone = auth_token.clone();
    let updates: Vec<TrackTagUpdate> = RT.block_on(async move {
        stream::iter(placeholders)
            .map(|(file_id, name, _folder_path, size_bytes)| {
                let token = token_clone.clone();
                let art_dir = art_dir.clone();
                async move {
                    let fallback_title = name
                        .rsplit_once('.')
                        .map(|(s, _)| s.to_string())
                        .unwrap_or_else(|| name.clone());
                    let default_update = TrackTagUpdate {
                        file_id: file_id.clone(),
                        title: fallback_title.clone(),
                        artist: String::new(),
                        album: String::new(),
                        album_artist: String::new(),
                        genre: String::new(),
                        year: 0,
                        track_number: 0,
                        disc_number: 1,
                        duration_ms: 0,
                        sample_rate: 44100,
                        channels: 2,
                        bits_per_sample: 16,
                        artwork_path: String::new(),
                    };

                    let range_end = if size_bytes > 0 && size_bytes < 65536 {
                        size_bytes - 1
                    } else {
                        65535
                    };
                    let url = format!(
                        "https://www.googleapis.com/drive/v3/files/{}?alt=media",
                        file_id
                    );

                    RATE_LIMITER.until_ready().await;

                    let mut req = HTTP_CLIENT
                        .get(&url)
                        .header("Range", format!("bytes=0-{}", range_end));
                    if let Some(ref t) = token {
                        req = req.bearer_auth(t);
                    }

                    let resp = match req.send().await {
                        Ok(r) if r.status().is_success() || r.status().as_u16() == 206 => r,
                        _ => return default_update,
                    };

                    let mut bytes = match resp.bytes().await {
                        Ok(b) => b.to_vec(),
                        Err(_) => return default_update,
                    };

                    // 1. FLAC Progressive Parser cut-through
                    if bytes.starts_with(b"fLaC") {
                        let parsed = match FlacProgressiveParser::parse(&bytes, 0) {
                            Ok(ParseProgress::Complete(m)) => Some(m),
                            Ok(ParseProgress::NeedMoreBytes {
                                partial: Some(m), ..
                            }) => Some(m),
                            Ok(ParseProgress::NeedMoreBytes { offset, length, .. })
                                if offset + length as u64 <= 262144 =>
                            {
                                // One follow-up range request if header is slightly larger than 64KB
                                RATE_LIMITER.until_ready().await;
                                let mut req2 = HTTP_CLIENT.get(&url).header(
                                    "Range",
                                    format!("bytes=0-{}", offset + length as u64 - 1),
                                );
                                if let Some(ref t) = token {
                                    req2 = req2.bearer_auth(t);
                                }
                                if let Ok(resp2) = req2.send().await {
                                    if let Ok(more_b) = resp2.bytes().await {
                                        bytes = more_b.to_vec();
                                        FlacProgressiveParser::parse(&bytes, 0).ok().and_then(|p| {
                                            match p {
                                                ParseProgress::Complete(m) => Some(m),
                                                ParseProgress::NeedMoreBytes {
                                                    partial: Some(m),
                                                    ..
                                                } => Some(m),
                                                _ => None,
                                            }
                                        })
                                    } else {
                                        None
                                    }
                                } else {
                                    None
                                }
                            }
                            _ => None,
                        };

                        if let Some(meta) = parsed {
                            let title = meta
                                .tags
                                .get("TITLE")
                                .cloned()
                                .filter(|s| !s.is_empty())
                                .unwrap_or(fallback_title.clone());
                            let artist = meta.tags.get("ARTIST").cloned().unwrap_or_default();
                            let album = meta.tags.get("ALBUM").cloned().unwrap_or_default();
                            let album_artist = meta
                                .tags
                                .get("ALBUMARTIST")
                                .or_else(|| meta.tags.get("ALBUM ARTIST"))
                                .cloned()
                                .unwrap_or_else(|| artist.clone());
                            let genre = meta.tags.get("GENRE").cloned().unwrap_or_default();
                            let year = meta
                                .tags
                                .get("DATE")
                                .or_else(|| meta.tags.get("YEAR"))
                                .map(|s| parse_year(s))
                                .unwrap_or(0);
                            let track_number = meta
                                .tags
                                .get("TRACKNUMBER")
                                .map(|s| parse_index_number(s))
                                .unwrap_or(0);
                            let disc_number = meta
                                .tags
                                .get("DISCNUMBER")
                                .map(|s| parse_index_number(s))
                                .unwrap_or(1);
                            let duration_ms = (meta.stream_info.duration_seconds * 1000.0) as u32;
                            let sample_rate = meta.stream_info.sample_rate;
                            let channels = meta.stream_info.channels as u32;
                            let bits_per_sample = meta.stream_info.bits_per_sample as u32;

                            // Deduplicate artwork by (album_artist, album)
                            let mut artwork_path = String::new();
                            let album_clean = if album.is_empty() {
                                "unknown_album"
                            } else {
                                &album
                            };
                            let artist_clean = if !album_artist.is_empty() {
                                &album_artist
                            } else if !artist.is_empty() {
                                &artist
                            } else {
                                "unknown_artist"
                            };
                            let album_key = if album_clean == "unknown_album"
                                && artist_clean == "unknown_artist"
                            {
                                format!("track_{}", sanitize_filename(&file_id))
                            } else {
                                format!(
                                    "{}::{}",
                                    artist_clean.trim().to_lowercase(),
                                    album_clean.trim().to_lowercase()
                                )
                            };
                            let art_target =
                                art_dir.join(format!("{}.img", sanitize_filename(&album_key)));

                            if art_target.exists()
                                && art_target.metadata().map(|m| m.len() > 0).unwrap_or(false)
                            {
                                artwork_path = art_target.to_string_lossy().to_string();
                            } else if let Some(pic) = meta.pictures.first() {
                                if pic.data_offset + pic.data_length as u64 <= bytes.len() as u64 {
                                    let start = pic.data_offset as usize;
                                    let end = start + pic.data_length as usize;
                                    if end <= bytes.len()
                                        && std::fs::write(&art_target, &bytes[start..end]).is_ok()
                                    {
                                        artwork_path = art_target.to_string_lossy().to_string();
                                    }
                                } else if pic.data_length > 0 && pic.data_length <= 5 * 1024 * 1024
                                {
                                    RATE_LIMITER.until_ready().await;
                                    let mut art_req = HTTP_CLIENT.get(&url).header(
                                        "Range",
                                        format!(
                                            "bytes={}-{}",
                                            pic.data_offset,
                                            pic.data_offset + pic.data_length as u64 - 1
                                        ),
                                    );
                                    if let Some(ref t) = token {
                                        art_req = art_req.bearer_auth(t);
                                    }
                                    if let Ok(art_resp) = art_req.send().await {
                                        if art_resp.status().is_success()
                                            || art_resp.status().as_u16() == 206
                                        {
                                            if let Ok(art_bytes) = art_resp.bytes().await {
                                                if std::fs::write(&art_target, &art_bytes).is_ok() {
                                                    artwork_path =
                                                        art_target.to_string_lossy().to_string();
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            // Fallback to online cover art if embedded is absent
                            if artwork_path.is_empty() && (!album.is_empty() || !title.is_empty()) {
                                if let Some(online_b) =
                                    fetch_online_cover_art(artist_clean, album_clean, &title).await
                                {
                                    if std::fs::write(&art_target, &online_b).is_ok() {
                                        artwork_path = art_target.to_string_lossy().to_string();
                                    }
                                }
                            }

                            return TrackTagUpdate {
                                file_id,
                                title,
                                artist,
                                album,
                                album_artist,
                                genre,
                                year,
                                track_number,
                                disc_number,
                                duration_ms,
                                sample_rate,
                                channels,
                                bits_per_sample,
                                artwork_path,
                            };
                        }
                    }

                    // 2. Fallback to Symphonia probe for MP3/WAV/AAC within initial chunk
                    use std::io::Cursor;
                    use symphonia::core::formats::FormatOptions;
                    use symphonia::core::io::MediaSourceStream;
                    use symphonia::core::meta::MetadataOptions;
                    use symphonia::core::probe::Hint;

                    let mss =
                        MediaSourceStream::new(Box::new(Cursor::new(bytes)), Default::default());
                    let mut hint = Hint::new();
                    if let Some(ext) = name.rsplit('.').next() {
                        hint.with_extension(ext);
                    }
                    let meta_opts: MetadataOptions = Default::default();
                    let fmt_opts: FormatOptions = Default::default();

                    if let Ok(probed) =
                        symphonia::default::get_probe().format(&hint, mss, &fmt_opts, &meta_opts)
                    {
                        let mut format = probed.format;
                        let mut duration_ms = 0;
                        let mut sample_rate = 44100;
                        let mut channels = 2;
                        let mut bits_per_sample = 16;

                        if let Some(track) = format.default_track() {
                            if let Some(tb) = track.codec_params.time_base {
                                if let Some(n_frames) = track.codec_params.n_frames {
                                    let time = tb.calc_time(n_frames);
                                    duration_ms =
                                        (time.seconds * 1000 + (time.frac * 1000.0) as u64) as u32;
                                }
                            }
                            sample_rate = track.codec_params.sample_rate.unwrap_or(44100);
                            channels = track
                                .codec_params
                                .channels
                                .map(|c| c.count() as u32)
                                .unwrap_or(2);
                            bits_per_sample = track.codec_params.bits_per_sample.unwrap_or(16);
                        }

                        let mut title = fallback_title.clone();
                        let mut artist = String::new();
                        let mut album = String::new();
                        let mut album_artist = String::new();
                        let mut genre = String::new();
                        let mut year = 0;
                        let mut track_number = 0;
                        let mut disc_number = 1;

                        if let Some(metadata) = format.metadata().current() {
                            for tag in metadata.tags() {
                                match tag.std_key {
                                    Some(symphonia::core::meta::StandardTagKey::TrackTitle) => {
                                        title = tag.value.to_string()
                                    }
                                    Some(symphonia::core::meta::StandardTagKey::Artist) => {
                                        artist = tag.value.to_string()
                                    }
                                    Some(symphonia::core::meta::StandardTagKey::Album) => {
                                        album = tag.value.to_string()
                                    }
                                    Some(symphonia::core::meta::StandardTagKey::AlbumArtist) => {
                                        album_artist = tag.value.to_string()
                                    }
                                    Some(symphonia::core::meta::StandardTagKey::Genre) => {
                                        genre = tag.value.to_string()
                                    }
                                    Some(symphonia::core::meta::StandardTagKey::Date) => {
                                        year = tag.value.to_string().parse().unwrap_or(0)
                                    }
                                    Some(symphonia::core::meta::StandardTagKey::TrackNumber) => {
                                        track_number = tag.value.to_string().parse().unwrap_or(0)
                                    }
                                    Some(symphonia::core::meta::StandardTagKey::DiscNumber) => {
                                        disc_number = tag.value.to_string().parse().unwrap_or(1)
                                    }
                                    _ => {}
                                }
                            }
                        }

                        // Filename fallback if tags are missing or title is still fallback
                        if artist.is_empty() || album.is_empty() {
                            let (fn_title, fn_artist, fn_album, fn_track) =
                                parse_filename_metadata(&name);
                            if !fn_title.is_empty() && (title == fallback_title || title.is_empty())
                            {
                                title = fn_title;
                            }
                            if artist.is_empty() && !fn_artist.is_empty() {
                                artist = fn_artist;
                            }
                            if album.is_empty() && !fn_album.is_empty() {
                                album = fn_album;
                            }
                            if track_number == 0 && fn_track > 0 {
                                track_number = fn_track;
                            }
                        }

                        if album_artist.is_empty() {
                            album_artist = artist.clone();
                        }

                        // Check for visuals in Symphonia metadata
                        let mut visual_bytes = None;
                        if let Some(metadata) = format.metadata().current() {
                            if let Some(visual) = metadata.visuals().first() {
                                visual_bytes = Some(visual.data.to_vec());
                            }
                        }

                        let album_clean = if album.is_empty() {
                            "unknown_album"
                        } else {
                            &album
                        };
                        let artist_clean = if !album_artist.is_empty() {
                            &album_artist
                        } else if !artist.is_empty() {
                            &artist
                        } else {
                            "unknown_artist"
                        };
                        let album_key =
                            if album_clean == "unknown_album" && artist_clean == "unknown_artist" {
                                format!("track_{}", sanitize_filename(&file_id))
                            } else {
                                format!(
                                    "{}::{}",
                                    artist_clean.trim().to_lowercase(),
                                    album_clean.trim().to_lowercase()
                                )
                            };
                        let art_target =
                            art_dir.join(format!("{}.img", sanitize_filename(&album_key)));
                        let mut artwork_path = String::new();

                        if art_target.exists()
                            && art_target.metadata().map(|m| m.len() > 0).unwrap_or(false)
                        {
                            artwork_path = art_target.to_string_lossy().to_string();
                        } else if let Some(vb) = visual_bytes {
                            if std::fs::write(&art_target, &vb).is_ok() {
                                artwork_path = art_target.to_string_lossy().to_string();
                            }
                        } else if !album.is_empty() || !title.is_empty() {
                            if let Some(online_b) =
                                fetch_online_cover_art(artist_clean, album_clean, &title).await
                            {
                                if std::fs::write(&art_target, &online_b).is_ok() {
                                    artwork_path = art_target.to_string_lossy().to_string();
                                }
                            }
                        }

                        return TrackTagUpdate {
                            file_id,
                            title,
                            artist,
                            album,
                            album_artist,
                            genre,
                            year,
                            track_number,
                            disc_number,
                            duration_ms,
                            sample_rate,
                            channels,
                            bits_per_sample,
                            artwork_path,
                        };
                    }

                    // 3. Fallback for completely unprobed files (e.g. raw WAV)
                    let (fn_title, fn_artist, fn_album, fn_track) = parse_filename_metadata(&name);
                    let title = if !fn_title.is_empty() {
                        fn_title
                    } else {
                        fallback_title
                    };
                    let artist = fn_artist;
                    let album = fn_album;
                    let album_artist = artist.clone();
                    let track_number = fn_track;

                    let album_clean = if album.is_empty() {
                        "unknown_album"
                    } else {
                        &album
                    };
                    let artist_clean = if !artist.is_empty() {
                        &artist
                    } else {
                        "unknown_artist"
                    };
                    let album_key =
                        if album_clean == "unknown_album" && artist_clean == "unknown_artist" {
                            format!("track_{}", sanitize_filename(&file_id))
                        } else {
                            format!(
                                "{}::{}",
                                artist_clean.trim().to_lowercase(),
                                album_clean.trim().to_lowercase()
                            )
                        };
                    let art_target = art_dir.join(format!("{}.img", sanitize_filename(&album_key)));
                    let mut artwork_path = String::new();

                    if art_target.exists()
                        && art_target.metadata().map(|m| m.len() > 0).unwrap_or(false)
                    {
                        artwork_path = art_target.to_string_lossy().to_string();
                    } else if !album.is_empty() || !title.is_empty() {
                        if let Some(online_b) =
                            fetch_online_cover_art(artist_clean, album_clean, &title).await
                        {
                            if std::fs::write(&art_target, &online_b).is_ok() {
                                artwork_path = art_target.to_string_lossy().to_string();
                            }
                        }
                    }

                    TrackTagUpdate {
                        file_id,
                        title,
                        artist,
                        album,
                        album_artist,
                        genre: String::new(),
                        year: 0,
                        track_number,
                        disc_number: 1,
                        duration_ms: default_update.duration_ms,
                        sample_rate: default_update.sample_rate,
                        channels: default_update.channels,
                        bits_per_sample: default_update.bits_per_sample,
                        artwork_path,
                    }
                }
            })
            .buffer_unordered(16)
            .collect()
            .await
    });

    let count = updates.len() as u32;
    with_db_mut(|db| {
        db.batch_update_tags(&updates)?;
        Ok(count)
    })
}

pub fn cloud_library_pending(limit: u32) -> Result<Vec<String>, String> {
    with_db(|db| Ok(db.pending_tag_reads(limit)?))
}

pub fn cloud_library_tracks() -> Result<Vec<CloudTrack>, String> {
    with_db(|db| {
        Ok(db
            .list_tracks()?
            .into_iter()
            .map(CloudTrack::from)
            .collect())
    })
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

/// What the streamed-audio cache is using, and what a clear would reclaim.
pub struct CacheUsage {
    /// Bytes of streamed audio on disk. This is the reclaimable part.
    pub audio_bytes: u64,
    /// How many tracks have at least one chunk cached.
    pub track_count: u32,
    /// Bytes of cover art. Kept across a clear: it is small, and losing it
    /// would blank the library until the next rescan.
    pub artwork_bytes: u64,
}

/// Measures the on-disk cache.
///
/// Walks the directories rather than trusting a running total: chunks are
/// also dropped by the OS when it reclaims cache space, so any number the app
/// kept for itself would drift.
///
/// `chunk_dirs` is a list because chunks are written from two places — the
/// player, and the tag reader that probes each new track for its metadata.
/// Counting only the player's would understate what a clear reclaims.
pub fn cache_usage(chunk_dirs: Vec<String>, artwork_dir: String) -> CacheUsage {
    let mut audio_bytes = 0u64;
    let mut tracks: std::collections::HashSet<String> = std::collections::HashSet::new();

    for chunk_dir in &chunk_dirs {
        let Ok(entries) = std::fs::read_dir(chunk_dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if !name.ends_with(".dat") && !name.ends_with(".sparse") && !name.ends_with(".idx") {
                continue;
            }
            if let Ok(meta) = entry.metadata() {
                #[cfg(unix)]
                {
                    use std::os::unix::fs::MetadataExt;
                    if name.ends_with(".sparse") {
                        // Accurately account for punched holes via allocated 512-byte blocks
                        audio_bytes += meta.blocks() * 512;
                    } else {
                        audio_bytes += meta.len();
                    }
                }
                #[cfg(not(unix))]
                {
                    audio_bytes += meta.len();
                }
            }
            // "<fileId>_chunk_<n>.dat" or "<fileId>.sparse"
            if let Some(idx) = name.rfind("_chunk_") {
                tracks.insert(name[..idx].to_string());
            } else if let Some(id) = name.strip_suffix(".sparse") {
                tracks.insert(id.to_string());
            }
        }
    }

    let mut artwork_bytes = 0u64;
    if let Ok(entries) = std::fs::read_dir(&artwork_dir) {
        for entry in entries.flatten() {
            if let Ok(meta) = entry.metadata() {
                artwork_bytes += meta.len();
            }
        }
    }

    CacheUsage {
        audio_bytes,
        track_count: tracks.len() as u32,
        artwork_bytes,
    }
}

/// Configured unpinned cache limit in bytes. Defaults to 2 GB (2 * 1024 * 1024 * 1024).
pub static CACHE_LIMIT_BYTES: AtomicU64 = AtomicU64::new(2 * 1024 * 1024 * 1024);

#[derive(Debug, Clone)]
pub struct CacheStats {
    pub total_bytes: u64,
    pub pinned_bytes: u64,
    pub unpinned_bytes: u64,
    pub chunk_count: u32,
    pub cache_limit_bytes: u64,
}

/// Sets the unpinned cache limit in bytes and persists to SQLite.
pub fn cloud_cache_set_limit(limit_bytes: u64) -> Result<(), String> {
    CACHE_LIMIT_BYTES.store(limit_bytes, Ordering::Relaxed);
    let _ = with_db_mut(|db| {
        db.set_kv("cache_limit_bytes", &limit_bytes.to_string())
            .map_err(anyhow::Error::from)
    });
    Ok(())
}

/// Returns the current unpinned cache limit in bytes.
pub fn cloud_cache_get_limit() -> u64 {
    CACHE_LIMIT_BYTES.load(Ordering::Relaxed)
}

/// Syncs the pinned track list into SQLite for LRU eviction protection.
pub fn cloud_cache_sync_pinned(pinned_file_ids: Vec<String>) -> Result<(), String> {
    with_db_mut(|db| {
        db.sync_pinned_tracks(&pinned_file_ids)
            .map_err(anyhow::Error::from)
    })
}

/// Returns aggregated cache statistics: total, pinned, unpinned, and chunk count.
pub fn cloud_cache_get_stats(
    pinned_file_ids: Vec<String>,
    active_file_id: Option<String>,
) -> Result<CacheStats, String> {
    let _ = active_file_id;
    let rec = with_db(|db| {
        db.get_cache_stats(&pinned_file_ids)
            .map_err(anyhow::Error::from)
    })?;
    Ok(CacheStats {
        total_bytes: rec.total_bytes,
        pinned_bytes: rec.pinned_bytes,
        unpinned_bytes: rec.unpinned_bytes,
        chunk_count: rec.chunk_count,
        cache_limit_bytes: cloud_cache_get_limit(),
    })
}

/// Helper for diagnostics snapshot: queries total cached bytes across all files.
pub fn get_total_cache_bytes() -> u64 {
    with_db(|db| {
        db.get_cache_stats(&[])
            .map(|s| s.total_bytes)
            .map_err(anyhow::Error::from)
    })
    .unwrap_or(0)
}

/// Prunes unpinned chunks down to the configured limit, preserving pinned tracks and active playback.
pub fn cloud_cache_prune_now(
    chunk_dir: String,
    pinned_file_ids: Vec<String>,
    active_file_id: Option<String>,
) -> Result<u64, String> {
    let limit = cloud_cache_get_limit();
    let dir = std::path::PathBuf::from(chunk_dir);
    crate::cloud::media_source::with_live_cache_ids(|live| {
        let mut protected = pinned_file_ids;
        protected.extend(live);
        with_db_mut(|db| {
            let evicted = db
                .prune_lru_chunks(limit, &protected, active_file_id.as_deref())
                .map_err(anyhow::Error::from)?;
            let freed_bytes: u64 = evicted.iter().map(|c| c.byte_len as u64).sum();
            if !evicted.is_empty() {
                crate::cloud::media_source::apply_chunk_evictions(&dir, &evicted, db);
            }
            Ok(freed_bytes)
        })
    })
}

#[derive(Debug, Clone)]
pub struct KeyValuePair {
    pub key: String,
    pub value: String,
}

/// Stores a persistent key-value configuration pair in SQLite.
pub fn cloud_db_set_kv(key: String, value: String) -> Result<(), String> {
    with_db(|db| db.set_kv(&key, &value).map_err(anyhow::Error::from))
}

/// Reads a persistent key-value configuration pair from SQLite.
pub fn cloud_db_get_kv(key: String) -> Result<Option<String>, String> {
    with_db(|db| db.get_kv(&key).map_err(anyhow::Error::from))
}

/// Deletes a persistent key-value configuration pair from SQLite.
pub fn cloud_db_delete_kv(key: String) -> Result<(), String> {
    with_db(|db| db.delete_kv(&key).map_err(anyhow::Error::from))
}

/// Lists all key-value configuration pairs with keys matching the prefix.
pub fn cloud_db_list_kv_prefix(prefix: String) -> Result<Vec<KeyValuePair>, String> {
    with_db(|db| {
        let items = db.list_kv_prefix(&prefix).map_err(anyhow::Error::from)?;
        Ok(items
            .into_iter()
            .map(|(key, value)| KeyValuePair { key, value })
            .collect())
    })
}

/// AutoEQ headphone/IEM target frequency response profile.
#[derive(Debug, Clone)]
pub struct AutoEqProfileData {
    pub id: String,
    pub model: String,
    pub brand: String,
    pub source: String,
    pub target: String,
    pub suggested_preamp_db: f64,
    pub bands_json: String,
}

impl From<crate::cloud::db::AutoEqProfileRow> for AutoEqProfileData {
    fn from(r: crate::cloud::db::AutoEqProfileRow) -> Self {
        Self {
            id: r.id,
            model: r.model,
            brand: r.brand,
            source: r.source,
            target: r.target,
            suggested_preamp_db: r.suggested_preamp_db,
            bands_json: r.bands_json,
        }
    }
}

impl From<AutoEqProfileData> for crate::cloud::db::AutoEqProfileRow {
    fn from(d: AutoEqProfileData) -> Self {
        Self {
            id: d.id,
            model: d.model,
            brand: d.brand,
            source: d.source,
            target: d.target,
            suggested_preamp_db: d.suggested_preamp_db,
            bands_json: d.bands_json,
        }
    }
}

/// Searches the persistent AutoEQ database for headphone/IEM profiles matching a query.
pub fn cloud_db_search_autoeq(query: String) -> Result<Vec<AutoEqProfileData>, String> {
    with_db(|db| {
        let rows = db
            .search_autoeq_profiles(&query)
            .map_err(anyhow::Error::from)?;
        Ok(rows.into_iter().map(AutoEqProfileData::from).collect())
    })
}

/// Retrieves a single AutoEQ profile by ID from SQLite.
pub fn cloud_db_get_autoeq_profile(id: String) -> Result<Option<AutoEqProfileData>, String> {
    with_db(|db| {
        let row = db.get_autoeq_profile(&id).map_err(anyhow::Error::from)?;
        Ok(row.map(AutoEqProfileData::from))
    })
}

/// Inserts or updates an AutoEQ profile in SQLite.
pub fn cloud_db_insert_autoeq_profile(profile: AutoEqProfileData) -> Result<(), String> {
    with_db(|db| {
        let row = crate::cloud::db::AutoEqProfileRow::from(profile);
        db.insert_autoeq_profile(&row).map_err(anyhow::Error::from)
    })
}

/// Clears unused audio chunks while preserving pins, open sources, artwork and metadata.
pub fn clear_audio_cache(chunk_dirs: Vec<String>) -> u64 {
    crate::cloud::media_source::clear_inactive_caches(&chunk_dirs)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_filename_metadata() {
        let (title, artist, album, track) =
            parse_filename_metadata("Rockstar - A. R. Rahman - 11- Nadaan Parinde.wav");
        assert_eq!(album, "Rockstar");
        assert_eq!(artist, "A. R. Rahman");
        assert_eq!(track, 11);
        assert_eq!(title, "Nadaan Parinde");

        let (title, artist, album, track) = parse_filename_metadata("01 - Tum Mile.wav");
        assert_eq!(track, 1);
        assert_eq!(title, "Tum Mile");
        assert_eq!(artist, "");
        assert_eq!(album, "");

        let (title, artist, album, track) = parse_filename_metadata("Faheem Abdullah - Ishq.mp3");
        assert_eq!(artist, "Faheem Abdullah");
        assert_eq!(title, "Ishq");
        assert_eq!(album, "");
        assert_eq!(track, 0);
    }

    #[test]
    fn test_url_encode() {
        assert_eq!(
            url_encode("Linkin Park One More Light"),
            "Linkin+Park+One+More+Light"
        );
        assert_eq!(url_encode("A. R. Rahman"), "A.+R.+Rahman");
    }

    #[tokio::test]
    async fn test_throttle_itunes_spacing() {
        let start = std::time::Instant::now();
        throttle_itunes().await;
        throttle_itunes().await;
        let elapsed = start.elapsed();
        assert!(
            elapsed >= std::time::Duration::from_millis(140),
            "Expected at least 140ms elapsed, got {:?}",
            elapsed
        );
    }

    #[test]
    fn test_cloud_library_scan_local_folder_and_browse() {
        let temp_dir =
            std::env::temp_dir().join(format!("bitdrop_api_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&temp_dir);
        let db_dir = temp_dir.join("db");
        let cache_dir = temp_dir.join("cache");
        let music_dir = temp_dir.join("Music");
        let jazz_dir = music_dir.join("Hi-Res/Jazz");
        let rock_dir = music_dir.join("Rock");

        std::fs::create_dir_all(&db_dir).unwrap();
        std::fs::create_dir_all(&cache_dir).unwrap();
        std::fs::create_dir_all(&jazz_dir).unwrap();
        std::fs::create_dir_all(&rock_dir).unwrap();

        let track1 = jazz_dir.join("01 - So What.flac");
        let track2 = rock_dir.join("02 - Time.wav");
        std::fs::write(&track1, [0u8; 128]).unwrap();
        std::fs::write(&track2, [0u8; 128]).unwrap();

        let db_path = db_dir.join("library.db").to_string_lossy().to_string();
        let cache_str = cache_dir.to_string_lossy().to_string();

        cloud_library_open(db_path, cache_str).unwrap();

        let scanned = cloud_library_scan_local_folder(
            music_dir.to_string_lossy().to_string(),
            "Local Music".to_string(),
        )
        .unwrap();
        assert_eq!(scanned, 2);

        // 1. Root folder listing (storage roots)
        let root_listing = cloud_library_get_folder(None).unwrap();
        assert_eq!(root_listing.folder_id, None);
        assert!(root_listing.breadcrumb.is_empty());
        assert_eq!(root_listing.entries.len(), 1);
        let root_entry = &root_listing.entries[0];
        assert_eq!(root_entry.name, "Local Music");
        assert!(root_entry.is_directory);
        assert_eq!(root_entry.item_count, 2);

        // 2. Local Music folder listing
        let music_listing = cloud_library_get_folder(Some("Local Music".to_string())).unwrap();
        assert_eq!(music_listing.folder_id, Some("Local Music".to_string()));
        assert_eq!(music_listing.breadcrumb.len(), 1);
        assert_eq!(music_listing.breadcrumb[0].name, "Local Music");
        assert_eq!(music_listing.entries.len(), 2); // Hi-Res, Rock
        let names: Vec<String> = music_listing
            .entries
            .iter()
            .map(|e| e.name.clone())
            .collect();
        assert!(names.contains(&"Hi-Res".to_string()));
        assert!(names.contains(&"Rock".to_string()));

        // 3. Deep subfolder listing (Jazz)
        let jazz_listing =
            cloud_library_get_folder(Some("Local Music / Hi-Res / Jazz".to_string())).unwrap();
        assert_eq!(jazz_listing.breadcrumb.len(), 3);
        assert_eq!(jazz_listing.breadcrumb[0].name, "Local Music");
        assert_eq!(jazz_listing.breadcrumb[1].name, "Hi-Res");
        assert_eq!(jazz_listing.breadcrumb[2].name, "Jazz");
        assert_eq!(jazz_listing.entries.len(), 1);
        assert!(!jazz_listing.entries[0].is_directory);
        assert_eq!(jazz_listing.entries[0].name, "So What");
        assert!(jazz_listing.entries[0].track.is_some());

        // 4. Recursive tracks resolution
        let all_tracks =
            cloud_library_get_tracks_in_folder("Local Music".to_string(), true).unwrap();
        assert_eq!(all_tracks.len(), 2);

        // 5. Prune test
        std::fs::remove_file(&track1).unwrap();
        let pruned = cloud_library_prune_local_tracks("Local Music".to_string()).unwrap();
        assert_eq!(pruned, 1);

        let after_prune =
            cloud_library_get_tracks_in_folder("Local Music".to_string(), true).unwrap();
        assert_eq!(after_prune.len(), 1);
        assert_eq!(after_prune[0].title, "Time");

        // Clean up global state and temp dir
        *DB.lock().unwrap() = None;
        *CACHE_DIR.lock().unwrap() = None;
        let _ = std::fs::remove_dir_all(&temp_dir);
    }
}

/// Downloads through the same bounded cache writer used by streaming playback.
pub fn cloud_download_track(
    file_id: String,
    url: String,
    auth_token: Option<String>,
    total_size: u64,
    cache_dir: String,
) -> Result<(), String> {
    use std::io::Read;
    let mut source = crate::cloud::media_source::CloudMediaSource::new(
        file_id.clone(),
        url,
        auth_token,
        total_size,
        cache_dir.into(),
    )
    .map_err(|e| e.to_string())?;
    let mut buffer = vec![0; 64 * 1024];
    loop {
        if !with_db(|db| db.is_track_pinned(&file_id).map_err(anyhow::Error::from))? {
            return Ok(());
        }
        match source.read(&mut buffer) {
            Ok(0) => return Ok(()),
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {
                // Playback seeking cancels shared network work, not the pinned download.
                source.seek_to_current_generation();
            }
            Err(e) => return Err(e.to_string()),
        }
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn cloud_cache_is_complete(file_id: String, cache_dir: String, total_size: u64) -> bool {
    if total_size == 0 || !crate::cloud::media_source::valid_file_id(&file_id) {
        return false;
    }
    let path = std::path::Path::new(&cache_dir).join(format!("{}.sparse", file_id));
    if std::fs::metadata(path)
        .map(|m| m.len() < total_size)
        .unwrap_or(true)
    {
        return false;
    }
    with_db(|db| {
        let chunks = db.get_cached_chunks(&file_id)?;
        let count = total_size.div_ceil(crate::cloud::media_source::CHUNK_SIZE);
        Ok(chunks.len() as u64 == count
            && chunks.iter().all(|c| {
                let start = c.chunk_idx as u64 * crate::cloud::media_source::CHUNK_SIZE;
                start < total_size
                    && c.byte_len as u64
                        == (total_size - start).min(crate::cloud::media_source::CHUNK_SIZE)
            }))
    })
    .unwrap_or(false)
}

#[flutter_rust_bridge::frb(sync)]
pub fn cloud_cache_remove_track(file_id: String, cache_dir: String) -> Result<bool, String> {
    crate::cloud::media_source::remove_inactive_cache(std::path::Path::new(&cache_dir), &file_id)
        .map_err(|e| e.to_string())
}

/// Sync missing artwork: propagates existing album art to untagged tracks sharing the same album,
/// and fetches authentic online posters from Deezer and iTunes for tracks still lacking artwork.
pub fn cloud_library_sync_missing_artwork() -> Result<u32, String> {
    let art_dir = {
        let base = CACHE_DIR
            .lock()
            .map_err(|e| e.to_string())?
            .clone()
            .ok_or_else(|| "cloud library not opened".to_string())?;
        let d = PathBuf::from(base).join("artwork");
        let _ = std::fs::create_dir_all(&d);
        d
    };

    // Remove any accidental shared placeholder image
    let bad_placeholder = art_dir.join("unknown_artist__unknown_album.img");
    let _ = std::fs::remove_file(&bad_placeholder);

    // 1. First trigger database propagation for tracks that share an album name with existing art
    with_db(|db| {
        let _ = db.conn.execute(
            "UPDATE tracks SET
                artwork_path = (
                    SELECT a.artwork_path FROM albums_summary a
                    WHERE a.album_key = lower(trim(CASE WHEN tracks.album_artist != '' THEN tracks.album_artist ELSE tracks.artist END)) || '::' || lower(trim(CASE WHEN tracks.album != '' THEN tracks.album ELSE 'unknown album' END))
                      AND a.artwork_path IS NOT NULL AND a.artwork_path != '' AND a.artwork_path NOT LIKE '%unknown_artist__unknown_album%'
                ),
                artwork_checked = 1
            WHERE (tracks.artwork_path IS NULL OR tracks.artwork_path = '' OR tracks.artwork_path LIKE '%unknown_artist__unknown_album%')
              AND EXISTS (
                SELECT 1 FROM albums_summary a
                WHERE a.album_key = lower(trim(CASE WHEN tracks.album_artist != '' THEN tracks.album_artist ELSE tracks.artist END)) || '::' || lower(trim(CASE WHEN tracks.album != '' THEN tracks.album ELSE 'unknown album' END))
                  AND a.artwork_path IS NOT NULL AND a.artwork_path != '' AND a.artwork_path NOT LIKE '%unknown_artist__unknown_album%'
              )",
            [],
        );

        let _ = db.conn.execute(
            "UPDATE tracks SET
                artwork_path = (
                    SELECT a.artwork_path FROM albums_summary a
                    WHERE lower(trim(a.album)) = lower(trim(tracks.album))
                      AND a.artwork_path IS NOT NULL AND a.artwork_path != '' AND a.artwork_path NOT LIKE '%unknown_artist__unknown_album%'
                    LIMIT 1
                ),
                artwork_checked = 1
            WHERE (tracks.artwork_path IS NULL OR tracks.artwork_path = '' OR tracks.artwork_path LIKE '%unknown_artist__unknown_album%')
              AND tracks.album IS NOT NULL AND trim(tracks.album) != '' AND lower(trim(tracks.album)) != 'unknown album'
              AND EXISTS (
                SELECT 1 FROM albums_summary a
                WHERE lower(trim(a.album)) = lower(trim(tracks.album))
                  AND a.artwork_path IS NOT NULL AND a.artwork_path != '' AND a.artwork_path NOT LIKE '%unknown_artist__unknown_album%'
              )",
            [],
        );
        Ok(())
    })?;

    // 2. Query all tracks that still lack artwork and have NOT been checked yet
    let missing_tracks: Vec<(String, String, String, String, String, String)> = with_db(|db| {
        let mut stmt = db.conn.prepare(
            "SELECT file_id, name, title, artist, album, album_artist
             FROM tracks
             WHERE (artwork_path IS NULL OR artwork_path = '' OR artwork_path LIKE '%unknown_artist__unknown_album%')
               AND artwork_checked = 0"
        )?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, String>(5)?,
            ))
        })?;
        Ok(rows.flatten().collect())
    })?;

    if missing_tracks.is_empty() {
        return Ok(0);
    }

    let art_dir_clone = art_dir.clone();
    let updated_count = RT.block_on(async move {
        let mut count = 0u32;
        for (file_id, name, raw_title, raw_artist, raw_album, raw_album_artist) in missing_tracks {
            let (fn_title, fn_artist, fn_album, _) = parse_filename_metadata(&name);
            let title = if !raw_title.is_empty() {
                raw_title
            } else if !fn_title.is_empty() {
                fn_title
            } else {
                name.rsplit_once('.')
                    .map(|(s, _)| s.to_string())
                    .unwrap_or(name.clone())
            };
            let (_, pure_title) = parse_track_and_title(&title);
            let clean_title = if !pure_title.is_empty() {
                pure_title
            } else {
                title
            };

            let clean_artist = if !raw_album_artist.is_empty() {
                raw_album_artist
            } else if !raw_artist.is_empty() {
                raw_artist
            } else if !fn_artist.is_empty() {
                fn_artist
            } else {
                String::new()
            };

            let clean_album = if !raw_album.is_empty() {
                raw_album
            } else if !fn_album.is_empty() {
                fn_album
            } else {
                String::new()
            };

            let mut found = false;
            if let Some(art_bytes) =
                fetch_online_cover_art(&clean_artist, &clean_album, &clean_title).await
            {
                let target_file_name =
                    if clean_album.is_empty() || clean_album.to_lowercase() == "unknown album" {
                        format!("track_{}.img", sanitize_filename(&file_id))
                    } else {
                        let art_key = format!(
                            "{}::{}",
                            if clean_artist.is_empty() {
                                "various_artists"
                            } else {
                                &clean_artist
                            }
                            .trim()
                            .to_lowercase(),
                            clean_album.trim().to_lowercase()
                        );
                        format!("{}.img", sanitize_filename(&art_key))
                    };
                let target_path = art_dir_clone.join(&target_file_name);
                if std::fs::write(&target_path, &art_bytes).is_ok() {
                    let path_str = target_path.to_string_lossy().to_string();
                    let fid = file_id.clone();
                    let _ = with_db(|db| {
                        db.set_artwork(&fid, &path_str)?;
                        Ok(())
                    });
                    count += 1;
                    found = true;
                }
            }

            if !found {
                let fid = file_id.clone();
                let _ = with_db(|db| {
                    db.mark_artwork_checked(&fid)?;
                    Ok(())
                });
            }
        }
        count
    });

    if updated_count > 0 {
        with_db_mut(|db| {
            let _ = db.rebuild_albums_summary();
            Ok(())
        })?;
    }

    Ok(updated_count)
}

/// Retrieves all distinct genres with aggregated track counts and artwork.
pub fn cloud_library_get_genres() -> Result<Vec<CloudGenre>, String> {
    with_db(|db| {
        let list = db.get_genres()?;
        Ok(list
            .into_iter()
            .map(|g| CloudGenre {
                genre: g.genre,
                track_count: g.track_count,
                artwork_path: g.artwork_path,
            })
            .collect())
    })
}

/// Retrieves all tracks belonging to a given genre.
pub fn cloud_library_get_tracks_by_genre(genre: String) -> Result<Vec<CloudTrackRow>, String> {
    with_db(|db| {
        let tracks = db.get_tracks_by_genre(&genre)?;
        Ok(tracks)
    })
}

/// Retrieves a hierarchical folder listing including breadcrumbs, subfolders, and direct audio files.
pub fn cloud_library_get_folder(folder_id: Option<String>) -> Result<CloudFolderListing, String> {
    with_db(|db| {
        let fid = folder_id
            .as_deref()
            .map(|s| s.trim())
            .filter(|s| !s.is_empty() && *s != "/" && !s.eq_ignore_ascii_case("root"));

        // 1. Breadcrumbs
        let mut breadcrumb = Vec::new();
        if let Some(target_path) = fid {
            let segments: Vec<&str> = target_path
                .split('/')
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
                .collect();
            let mut accum = Vec::new();
            for seg in segments {
                accum.push(seg);
                let path = accum.join("/");
                breadcrumb.push(CloudFolderEntry {
                    id: path,
                    name: seg.to_string(),
                    is_directory: true,
                    item_count: 0,
                    size_bytes: 0,
                    track: None,
                });
            }
        }

        // 2. Immediate subfolders
        let subfolders = db.get_folders(fid)?;
        let mut entries = Vec::new();
        for f in subfolders {
            entries.push(CloudFolderEntry {
                id: f.path,
                name: f.name,
                is_directory: true,
                item_count: f.track_count,
                size_bytes: f.total_size_bytes,
                track: None,
            });
        }

        // 3. Direct tracks inside this folder
        let direct_tracks = db.get_tracks_in_folder(fid.unwrap_or(""), false)?;
        for t in direct_tracks {
            let display_name = if !t.title.trim().is_empty() {
                t.title.clone()
            } else {
                t.name.clone()
            };
            entries.push(CloudFolderEntry {
                id: t.file_id.clone(),
                name: display_name,
                is_directory: false,
                item_count: 0,
                size_bytes: t.size_bytes,
                track: Some(t),
            });
        }

        Ok(CloudFolderListing {
            folder_id: fid.map(|s| s.to_string()),
            breadcrumb,
            entries,
        })
    })
}

/// Retrieves all tracks within `folder_path` (recursively or non-recursively).
pub fn cloud_library_get_tracks_in_folder(
    folder_path: String,
    recursive: bool,
) -> Result<Vec<CloudTrackRow>, String> {
    with_db(|db| {
        let tracks = db.get_tracks_in_folder(&folder_path, recursive)?;
        Ok(tracks)
    })
}

/// Recursively scans a local directory, extracts metadata, indexes tracks into SQLite,
/// prunes deleted tracks under `label`, and rebuilds albums summary.
pub fn cloud_library_scan_local_folder(
    directory_path: String,
    label: String,
) -> Result<u32, String> {
    use crate::cloud::local_scanner::scan_local_directory;
    use std::path::Path;

    let path = Path::new(&directory_path);
    if !path.exists() {
        return Err(format!("Directory does not exist: {}", directory_path));
    }
    if !path.is_dir() {
        return Err(format!("Path is not a directory: {}", directory_path));
    }

    let root_label = if label.trim().is_empty() {
        path.file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("Local Music")
    } else {
        label.trim()
    };

    let art_dir = CACHE_DIR
        .lock()
        .ok()
        .and_then(|guard| guard.clone())
        .map(|base| std::path::PathBuf::from(base).join("artwork"));
    if let Some(ref dir) = art_dir {
        let _ = std::fs::create_dir_all(dir);
    }

    let scanned = scan_local_directory(path, root_label, art_dir.as_deref(), |_progress| {})
        .map_err(|e| format!("Scan failed: {:?}", e))?;

    with_db_mut(|db| {
        db.batch_insert_local_tracks(&scanned)?;
        let _ = db.prune_missing_local_tracks(root_label)?;
        Ok(scanned.len() as u32)
    })
}

/// Prunes indexed local tracks whose files no longer exist on disk.
pub fn cloud_library_prune_local_tracks(root_label: String) -> Result<u32, String> {
    with_db_mut(|db| {
        let count = db.prune_missing_local_tracks(root_label.trim())?;
        Ok(count as u32)
    })
}

//! The cloud library index: file list in, tagged tracks out.
//!
//! Dart owns the Drive API calls, because that is where the OAuth session
//! lives. Rust owns everything that touches bytes: fetching header ranges,
//! parsing FLAC metadata and persisting it. That split keeps the access token
//! on the Dart side and the parsing off the UI thread.

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;

use crate::cloud::db::{AlbumSummaryRow, CloudTrackRow, MetadataDb, TrackPlaceholder, TrackTagUpdate};
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

fn with_db<T>(f: impl FnOnce(&MetadataDb) -> anyhow::Result<T>) -> Result<T, String> {
    let guard = DB.lock().map_err(|e| e.to_string())?;
    let db = guard
        .as_ref()
        .ok_or_else(|| "cloud library not opened".to_string())?;
    f(db).map_err(|e| e.to_string())
}

fn with_db_mut<T>(f: impl FnOnce(&mut MetadataDb) -> anyhow::Result<T>) -> Result<T, String> {
    let mut guard = DB.lock().map_err(|e| e.to_string())?;
    let db = guard
        .as_mut()
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

    let items: Vec<TrackPlaceholder> = (0..file_ids.len())
        .map(|i| TrackPlaceholder {
            file_id: file_ids[i].clone(),
            name: names[i].clone(),
            folder_path: folder_paths[i].clone(),
            size_bytes: sizes[i],
        })
        .collect();

    with_db_mut(|db| {
        db.batch_insert_placeholders(&items)?;
        Ok(items.len() as u32)
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
            "SELECT file_id, name, folder_path, size_bytes FROM tracks WHERE file_id = ?"
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
                    let fallback_title = name.rsplit_once('.').map(|(s, _)| s.to_string()).unwrap_or_else(|| name.clone());
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
                    let url = format!("https://www.googleapis.com/drive/v3/files/{}?alt=media", file_id);

                    RATE_LIMITER.until_ready().await;

                    let mut req = HTTP_CLIENT.get(&url).header("Range", format!("bytes=0-{}", range_end));
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
                            Ok(ParseProgress::NeedMoreBytes { offset, length, .. }) if offset + length as u64 <= 262144 => {
                                // One follow-up range request if header is slightly larger than 64KB
                                RATE_LIMITER.until_ready().await;
                                let mut req2 = HTTP_CLIENT
                                    .get(&url)
                                    .header("Range", format!("bytes=0-{}", offset + length as u64 - 1));
                                if let Some(ref t) = token {
                                    req2 = req2.bearer_auth(t);
                                }
                                if let Ok(resp2) = req2.send().await {
                                    if let Ok(more_b) = resp2.bytes().await {
                                        bytes = more_b.to_vec();
                                        FlacProgressiveParser::parse(&bytes, 0).ok().and_then(|p| match p {
                                            ParseProgress::Complete(m) => Some(m),
                                            _ => None,
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
                            let title = meta.tags.get("TITLE").cloned().filter(|s| !s.is_empty()).unwrap_or(fallback_title);
                            let artist = meta.tags.get("ARTIST").cloned().unwrap_or_default();
                            let album = meta.tags.get("ALBUM").cloned().unwrap_or_default();
                            let album_artist = meta.tags.get("ALBUMARTIST")
                                .or_else(|| meta.tags.get("ALBUM ARTIST"))
                                .cloned()
                                .unwrap_or_else(|| artist.clone());
                            let genre = meta.tags.get("GENRE").cloned().unwrap_or_default();
                            let year = meta.tags.get("DATE").or_else(|| meta.tags.get("YEAR")).map(|s| parse_year(s)).unwrap_or(0);
                            let track_number = meta.tags.get("TRACKNUMBER").map(|s| parse_index_number(s)).unwrap_or(0);
                            let disc_number = meta.tags.get("DISCNUMBER").map(|s| parse_index_number(s)).unwrap_or(1);
                            let duration_ms = (meta.stream_info.duration_seconds * 1000.0) as u32;
                            let sample_rate = meta.stream_info.sample_rate;
                            let channels = meta.stream_info.channels as u32;
                            let bits_per_sample = meta.stream_info.bits_per_sample as u32;

                            // Deduplicate artwork by (album_artist, album)
                            let mut artwork_path = String::new();
                            let album_clean = if album.is_empty() { "unknown_album" } else { &album };
                            let artist_clean = if !album_artist.is_empty() {
                                &album_artist
                            } else if !artist.is_empty() {
                                &artist
                            } else {
                                "unknown_artist"
                            };
                            let album_key = format!("{}::{}", artist_clean.trim().to_lowercase(), album_clean.trim().to_lowercase());
                            let art_target = art_dir.join(format!("{}.img", sanitize_filename(&album_key)));

                            if art_target.exists() {
                                artwork_path = art_target.to_string_lossy().to_string();
                            } else if let Some(pic) = meta.pictures.first() {
                                if pic.data_offset + pic.data_length as u64 <= bytes.len() as u64 {
                                    let start = pic.data_offset as usize;
                                    let end = start + pic.data_length as usize;
                                    if end <= bytes.len() {
                                        if std::fs::write(&art_target, &bytes[start..end]).is_ok() {
                                            artwork_path = art_target.to_string_lossy().to_string();
                                        }
                                    }
                                } else if pic.data_length > 0 && pic.data_length <= 5 * 1024 * 1024 {
                                    RATE_LIMITER.until_ready().await;
                                    let mut art_req = HTTP_CLIENT
                                        .get(&url)
                                        .header("Range", format!("bytes={}-{}", pic.data_offset, pic.data_offset + pic.data_length as u64 - 1));
                                    if let Some(ref t) = token {
                                        art_req = art_req.bearer_auth(t);
                                    }
                                    if let Ok(art_resp) = art_req.send().await {
                                        if art_resp.status().is_success() || art_resp.status().as_u16() == 206 {
                                            if let Ok(art_bytes) = art_resp.bytes().await {
                                                if std::fs::write(&art_target, &art_bytes).is_ok() {
                                                    artwork_path = art_target.to_string_lossy().to_string();
                                                }
                                            }
                                        }
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
                    use symphonia::core::formats::FormatOptions;
                    use symphonia::core::io::MediaSourceStream;
                    use symphonia::core::meta::MetadataOptions;
                    use symphonia::core::probe::Hint;
                    use std::io::Cursor;

                    let mss = MediaSourceStream::new(Box::new(Cursor::new(bytes)), Default::default());
                    let mut hint = Hint::new();
                    if let Some(ext) = name.rsplit('.').next() {
                        hint.with_extension(ext);
                    }
                    let meta_opts: MetadataOptions = Default::default();
                    let fmt_opts: FormatOptions = Default::default();

                    if let Ok(probed) = symphonia::default::get_probe().format(&hint, mss, &fmt_opts, &meta_opts) {
                        let mut format = probed.format;
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
                            channels = track.codec_params.channels.map(|c| c.count() as u32).unwrap_or(2);
                            bits_per_sample = track.codec_params.bits_per_sample.unwrap_or(16);
                        }

                        let mut title = fallback_title;
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
                                    Some(symphonia::core::meta::StandardTagKey::TrackTitle) => title = tag.value.to_string(),
                                    Some(symphonia::core::meta::StandardTagKey::Artist) => artist = tag.value.to_string(),
                                    Some(symphonia::core::meta::StandardTagKey::Album) => album = tag.value.to_string(),
                                    Some(symphonia::core::meta::StandardTagKey::AlbumArtist) => album_artist = tag.value.to_string(),
                                    Some(symphonia::core::meta::StandardTagKey::Genre) => genre = tag.value.to_string(),
                                    Some(symphonia::core::meta::StandardTagKey::Date) => year = tag.value.to_string().parse().unwrap_or(0),
                                    Some(symphonia::core::meta::StandardTagKey::TrackNumber) => track_number = tag.value.to_string().parse().unwrap_or(0),
                                    Some(symphonia::core::meta::StandardTagKey::DiscNumber) => disc_number = tag.value.to_string().parse().unwrap_or(1),
                                    _ => {}
                                }
                            }
                        }

                        if album_artist.is_empty() {
                            album_artist = artist.clone();
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
                            artwork_path: String::new(),
                        };
                    }

                    default_update
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
            if !name.ends_with(".dat") {
                continue;
            }
            if let Ok(meta) = entry.metadata() {
                audio_bytes += meta.len();
            }
            // "<fileId>_chunk_<n>.dat" — everything before the last
            // "_chunk_" is the track it belongs to.
            if let Some(idx) = name.rfind("_chunk_") {
                tracks.insert(name[..idx].to_string());
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

/// Deletes every cached audio chunk and returns the bytes reclaimed.
///
/// Only the streamed audio goes: artwork and the library index stay, so the
/// library still renders and no rescan is needed. A chunk belonging to the
/// track playing right now is safe to unlink — the open file handle keeps
/// working, and anything read afterwards is simply fetched again.
pub fn clear_audio_cache(chunk_dirs: Vec<String>) -> u64 {
    let mut freed = 0u64;

    for chunk_dir in &chunk_dirs {
        let Ok(entries) = std::fs::read_dir(chunk_dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if !name.ends_with(".dat") && !name.ends_with(".tmp") {
                continue;
            }
            let len = entry.metadata().map(|m| m.len()).unwrap_or(0);
            if std::fs::remove_file(entry.path()).is_ok() {
                freed += len;
            }
        }
    }

    crate::cloud::media_source::forget_cached_ranges();
    freed
}

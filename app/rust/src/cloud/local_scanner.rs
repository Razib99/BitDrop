use std::collections::{HashMap, HashSet, VecDeque};
use std::fs::{self, File};
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

use crate::dsd::dsf::DsfReader;

/// Supported audio container and codec extensions recognized by the scanner.
pub const SUPPORTED_AUDIO_EXTENSIONS: &[&str] = &[
    "flac", "wav", "alac", "m4a", "aac", "mp4", "mp3", "opus", "ogg", "aiff", "aif", "dsf", "dff",
];

/// Progress report emitted during local directory scanning.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalScanProgress {
    pub files_found: u32,
    pub folders_visited: u32,
    pub current_folder: String,
}

/// Extracted metadata and file properties for a local audio track.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct LocalTrackInfo {
    pub path: String,
    pub name: String,
    pub folder_path: String,
    pub size_bytes: u64,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_artist: String,
    pub genre: String,
    pub year: Option<u32>,
    pub track_number: Option<u32>,
    pub disc_number: Option<u32>,
    pub duration_ms: u32,
    pub sample_rate: u32,
    pub channels: u8,
    pub bits_per_sample: u8,
    pub artwork_path: Option<String>,
    pub replay_gain_track_gain: Option<f64>,
    pub replay_gain_album_gain: Option<f64>,
    pub replay_gain_track_peak: Option<f64>,
    pub replay_gain_album_peak: Option<f64>,
    pub codec: String,
    pub mtime_secs: i64,
}

/// Result of an incremental local directory scan.
#[derive(Debug, Clone, Default)]
pub struct IncrementalLocalScanResult {
    /// Newly added or modified tracks that need DB upsert.
    pub new_or_updated: Vec<LocalTrackInfo>,
    /// Total valid audio files present on disk (new/updated + unchanged).
    pub total_found: u32,
    /// Unchanged files fast-skipped via `(size_bytes, folder_path)` match.
    pub skipped_unchanged: u32,
}

/// Errors encountered during local directory scanning.
#[derive(Debug)]
pub enum LocalScanError {
    Io(std::io::Error),
    DirectoryNotFound(String),
    NotADirectory(String),
    PermissionDenied(String),
    ScanFailed(String),
}

impl std::fmt::Display for LocalScanError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(e) => write!(f, "I/O error during scan: {}", e),
            Self::DirectoryNotFound(p) => write!(f, "Directory not found: {}", p),
            Self::NotADirectory(p) => write!(f, "Path is not a directory: {}", p),
            Self::PermissionDenied(p) => write!(f, "Permission denied reading directory: {}", p),
            Self::ScanFailed(msg) => write!(f, "Local scan failed: {}", msg),
        }
    }
}

impl std::error::Error for LocalScanError {}

impl From<std::io::Error> for LocalScanError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e)
    }
}

/// Returns true if the file extension matches a supported audio format.
pub fn is_audio_file(path: &Path) -> bool {
    path.extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| {
            let lower = ext.to_lowercase();
            SUPPORTED_AUDIO_EXTENSIONS.contains(&lower.as_str())
        })
        .unwrap_or(false)
}

/// Normalizes a relative directory path with a root label into the standard
/// hierarchical format (e.g. `"Internal Storage / Hi-Res / Jazz"` or `"Internal Storage"`).
pub fn normalize_folder_path(root_label: &str, relative_dir: &Path) -> String {
    let clean_label = root_label.trim();
    let segments: Vec<String> = relative_dir
        .components()
        .filter_map(|c| match c {
            std::path::Component::Normal(p) => p.to_str().map(|s| s.trim().to_string()),
            _ => None,
        })
        .filter(|s| !s.is_empty() && s != ".")
        .collect();

    if segments.is_empty() {
        clean_label.to_string()
    } else {
        format!("{} / {}", clean_label, segments.join(" / "))
    }
}

/// Parses an optional integer tag (e.g. "03" or "3/12").
fn parse_number_tag(s: &str) -> Option<u32> {
    let s = s.trim();
    if let Some((first, _)) = s.split_once('/') {
        first.trim().parse::<u32>().ok()
    } else {
        s.parse::<u32>().ok()
    }
}

/// Parses a year tag from a string (e.g. "2023-11-06" or "2023").
fn parse_year_tag(s: &str) -> Option<u32> {
    let s = s.trim();
    if s.len() >= 4 {
        s[0..4].parse::<u32>().ok()
    } else {
        s.parse::<u32>().ok()
    }
}

/// Parses filename fallback (e.g. "01 - Tum Mile.flac" -> (1, "Tum Mile")).
fn parse_track_and_title(s: &str) -> (Option<u32>, String) {
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
            return (if num > 0 { Some(num) } else { None }, title.to_string());
        }
    }
    (None, s.to_string())
}

/// Maps a Symphonia `CodecType` (with file extension tie-breaker for raw PCM
/// containers) to a canonical codec label stored in SQLite.
///
/// This distinguishes AAC vs ALAC inside `.m4a`/`.mp4` containers instead of
/// guessing from the filename extension.
pub fn codec_label_from_symphonia(codec: symphonia::core::codecs::CodecType, ext: &str) -> String {
    use symphonia::core::codecs::*;
    match codec {
        CODEC_TYPE_FLAC => "FLAC".to_string(),
        CODEC_TYPE_ALAC => "ALAC".to_string(),
        CODEC_TYPE_AAC => "AAC".to_string(),
        CODEC_TYPE_MP1 | CODEC_TYPE_MP2 | CODEC_TYPE_MP3 => "MP3".to_string(),
        CODEC_TYPE_VORBIS => "OGG".to_string(),
        CODEC_TYPE_OPUS => "OPUS".to_string(),
        c if c == CODEC_TYPE_PCM_S16LE
            || c == CODEC_TYPE_PCM_S16BE
            || c == CODEC_TYPE_PCM_S24LE
            || c == CODEC_TYPE_PCM_S24BE
            || c == CODEC_TYPE_PCM_S32LE
            || c == CODEC_TYPE_PCM_S32BE
            || c == CODEC_TYPE_PCM_F32LE
            || c == CODEC_TYPE_PCM_F32BE
            || c == CODEC_TYPE_PCM_F64LE
            || c == CODEC_TYPE_PCM_F64BE
            || c == CODEC_TYPE_PCM_U8
            || c == CODEC_TYPE_PCM_S8 =>
        {
            if ext.eq_ignore_ascii_case("aif") || ext.eq_ignore_ascii_case("aiff") {
                "AIFF".to_string()
            } else {
                "WAV".to_string()
            }
        }
        _ => match ext.to_lowercase().as_str() {
            "flac" => "FLAC".to_string(),
            "alac" => "ALAC".to_string(),
            "wav" | "wave" => "WAV".to_string(),
            "aif" | "aiff" => "AIFF".to_string(),
            "mp3" => "MP3".to_string(),
            "aac" | "m4a" | "mp4" => "AAC".to_string(),
            "ogg" => "OGG".to_string(),
            "opus" => "OPUS".to_string(),
            "dsf" => "DSF".to_string(),
            "dff" => "DFF".to_string(),
            other => other.to_uppercase(),
        },
    }
}

#[derive(Default)]
struct DsfId3Tags {
    title: String,
    artist: String,
    album: String,
    album_artist: String,
    genre: String,
    year: Option<u32>,
    track_number: Option<u32>,
    disc_number: Option<u32>,
    artwork_path: Option<String>,
}

fn decode_id3_text(data: &[u8]) -> String {
    if data.is_empty() {
        return String::new();
    }
    let encoding = data[0];
    let payload = &data[1..];
    match encoding {
        0 => payload
            .iter()
            .take_while(|&&b| b != 0)
            .map(|&b| b as char)
            .collect::<String>()
            .trim()
            .to_string(),
        1 | 2 => {
            let (be, slice) = if encoding == 1 && payload.len() >= 2 {
                if payload[0] == 0xFE && payload[1] == 0xFF {
                    (true, &payload[2..])
                } else if payload[0] == 0xFF && payload[1] == 0xFE {
                    (false, &payload[2..])
                } else {
                    (false, payload)
                }
            } else {
                (true, payload)
            };
            let mut units = Vec::with_capacity(slice.len() / 2);
            for &[b0, b1] in slice.as_chunks::<2>().0 {
                let u = if be {
                    u16::from_be_bytes([b0, b1])
                } else {
                    u16::from_le_bytes([b0, b1])
                };
                if u == 0 {
                    break;
                }
                units.push(u);
            }
            String::from_utf16_lossy(&units).trim().to_string()
        }
        3 => {
            let end = payload
                .iter()
                .position(|&b| b == 0)
                .unwrap_or(payload.len());
            String::from_utf8_lossy(&payload[..end]).trim().to_string()
        }
        _ => String::from_utf8_lossy(payload).trim().to_string(),
    }
}

fn parse_dsf_id3v2_tags(file: &mut File, offset: u64, art_dir: Option<&Path>) -> DsfId3Tags {
    use std::io::{Read, Seek, SeekFrom};

    let mut out = DsfId3Tags::default();
    if offset == 0 || file.seek(SeekFrom::Start(offset)).is_err() {
        return out;
    }
    let mut hdr = [0u8; 10];
    if file.read_exact(&mut hdr).is_err() || &hdr[0..3] != b"ID3" {
        return out;
    }
    let major = hdr[3];
    if major != 3 && major != 4 {
        return out;
    }
    let tag_size = (((hdr[6] & 0x7F) as usize) << 21)
        | (((hdr[7] & 0x7F) as usize) << 14)
        | (((hdr[8] & 0x7F) as usize) << 7)
        | ((hdr[9] & 0x7F) as usize);
    let capped_size = tag_size.min(4 * 1024 * 1024);
    let mut body = vec![0u8; capped_size];
    if file.read_exact(&mut body).is_err() {
        return out;
    }

    let mut pos = 0usize;
    while pos + 10 <= body.len() {
        let frame_id = &body[pos..pos + 4];
        if frame_id[0] == 0 {
            break;
        }
        let frame_size = if major == 4 {
            (((body[pos + 4] & 0x7F) as usize) << 21)
                | (((body[pos + 5] & 0x7F) as usize) << 14)
                | (((body[pos + 6] & 0x7F) as usize) << 7)
                | ((body[pos + 7] & 0x7F) as usize)
        } else {
            u32::from_be_bytes([body[pos + 4], body[pos + 5], body[pos + 6], body[pos + 7]])
                as usize
        };
        pos += 10;
        if frame_size == 0 || pos + frame_size > body.len() {
            break;
        }
        let data = &body[pos..pos + frame_size];
        pos += frame_size;

        match frame_id {
            b"TIT2" => out.title = decode_id3_text(data),
            b"TPE1" => out.artist = decode_id3_text(data),
            b"TALB" => out.album = decode_id3_text(data),
            b"TPE2" => out.album_artist = decode_id3_text(data),
            b"TCON" => {
                let raw = decode_id3_text(data);
                let parsed = crate::cloud::tag_parser::parse_multi_value_tag(&raw);
                if !parsed.is_empty() {
                    out.genre = parsed.join("; ");
                }
            }
            b"TYER" | b"TDRC" => {
                if out.year.is_none() {
                    out.year = parse_year_tag(&decode_id3_text(data));
                }
            }
            b"TRCK" => out.track_number = parse_number_tag(&decode_id3_text(data)),
            b"TPOS" => out.disc_number = parse_number_tag(&decode_id3_text(data)),
            b"APIC" if out.artwork_path.is_none() => {
                if let Some(dir) = art_dir {
                    if data.len() > 4 {
                        let enc = data[0];
                        if let Some(mime_end) = data[1..].iter().position(|&b| b == 0) {
                            let after_mime = 1 + mime_end + 1;
                            if after_mime + 1 < data.len() {
                                let desc_start = after_mime + 1; // skip picture type byte
                                let img_start = if enc == 1 || enc == 2 {
                                    data[desc_start..]
                                        .as_chunks::<2>()
                                        .0
                                        .iter()
                                        .position(|&c| c == [0, 0])
                                        .map(|i| desc_start + i * 2 + 2)
                                } else {
                                    data[desc_start..]
                                        .iter()
                                        .position(|&b| b == 0)
                                        .map(|i| desc_start + i + 1)
                                };
                                if let Some(start) = img_start {
                                    let img_bytes = &data[start..];
                                    if !img_bytes.is_empty() {
                                        let _ = fs::create_dir_all(dir);
                                        let mut hasher = sha2::Sha256::default();
                                        sha2::Digest::update(&mut hasher, img_bytes);
                                        let hash = format!("{:x}", sha2::Digest::finalize(hasher));
                                        let art_file = dir.join(format!("art_{}.img", &hash[..16]));
                                        if !art_file.exists() {
                                            let _ = fs::write(&art_file, img_bytes);
                                        }
                                        out.artwork_path =
                                            Some(art_file.to_string_lossy().to_string());
                                    }
                                }
                            }
                        }
                    }
                }
            }
            _ => {}
        }
    }
    out
}

/// Extracts metadata from a local audio file on disk.
///
/// Supports native DSD (.dsf) container inspection and Symphonia format probing for
/// PCM/compressed streams (FLAC, WAV, ALAC, MP3, AAC, OGG Vorbis, AIFF).
pub fn extract_local_metadata(
    path: &Path,
    file_size: u64,
    folder_path: &str,
    art_dir: Option<&Path>,
) -> Result<LocalTrackInfo, LocalScanError> {
    let mtime_secs = fs::metadata(path)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let file_name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown")
        .to_string();

    let file_stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or(&file_name);

    let (fallback_track, fallback_title) = parse_track_and_title(file_stem);

    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_lowercase())
        .unwrap_or_default();

    // 1. Native DSF / DSD files
    if ext == "dsf" {
        let mut file = File::open(path)?;
        match DsfReader::open(&mut file) {
            Ok(dsf) => {
                let hdr = *dsf.header();
                let dsd_codec = match hdr.sample_rate {
                    5_644_800 => "DSD128",
                    11_289_600 => "DSD256",
                    22_579_200 => "DSD512",
                    _ => "DSD64",
                };
                let id3 = parse_dsf_id3v2_tags(&mut file, hdr.metadata_offset, art_dir);
                let title = if id3.title.is_empty() {
                    fallback_title
                } else {
                    id3.title
                };
                let artist = if id3.artist.is_empty() {
                    "Unknown Artist".to_string()
                } else {
                    id3.artist
                };
                let album = if id3.album.is_empty() {
                    "Unknown Album".to_string()
                } else {
                    id3.album
                };
                let album_artist = if id3.album_artist.is_empty() {
                    artist.clone()
                } else {
                    id3.album_artist
                };
                let genre = if id3.genre.is_empty() {
                    "DSD".to_string()
                } else {
                    id3.genre
                };
                return Ok(LocalTrackInfo {
                    path: path.to_string_lossy().to_string(),
                    name: file_name,
                    folder_path: folder_path.to_string(),
                    size_bytes: file_size,
                    title,
                    artist,
                    album,
                    album_artist,
                    genre,
                    year: id3.year,
                    track_number: id3.track_number.or(fallback_track),
                    disc_number: id3.disc_number.or(Some(1)),
                    duration_ms: hdr.duration_ms,
                    sample_rate: hdr.sample_rate,
                    channels: (hdr.channel_num as u8).max(1),
                    bits_per_sample: 1,
                    artwork_path: id3.artwork_path,
                    codec: dsd_codec.to_string(),
                    mtime_secs,
                    ..Default::default()
                });
            }
            Err(e) => {
                // If DSF header corrupt, return basic info with 0 duration rather than failing scan
                eprintln!("[local_scanner] DSF probe error on {:?}: {:?}", path, e);
                return Ok(LocalTrackInfo {
                    path: path.to_string_lossy().to_string(),
                    name: file_name,
                    folder_path: folder_path.to_string(),
                    size_bytes: file_size,
                    title: fallback_title,
                    artist: "Unknown Artist".to_string(),
                    album: "Unknown Album".to_string(),
                    album_artist: "Unknown Artist".to_string(),
                    genre: "DSD".to_string(),
                    year: None,
                    track_number: fallback_track,
                    disc_number: Some(1),
                    duration_ms: 0,
                    sample_rate: 2822400,
                    channels: 2,
                    bits_per_sample: 1,
                    artwork_path: None,
                    codec: "DSF".to_string(),
                    mtime_secs,
                    ..Default::default()
                });
            }
        }
    }

    // 2. Symphonia-supported formats (FLAC, WAV, ALAC, MP3, AAC, Opus, AIFF)
    let file = File::open(path)?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());

    let mut hint = Hint::new();
    if !ext.is_empty() {
        hint.with_extension(&ext);
    }

    let fmt_opts: FormatOptions = Default::default();
    let meta_opts: MetadataOptions = Default::default();

    let mut probed = match symphonia::default::get_probe().format(&hint, mss, &fmt_opts, &meta_opts)
    {
        Ok(p) => p,
        Err(_) => {
            // Unparseable header, return fallback entry
            return Ok(LocalTrackInfo {
                path: path.to_string_lossy().to_string(),
                name: file_name,
                folder_path: folder_path.to_string(),
                size_bytes: file_size,
                title: fallback_title,
                artist: "Unknown Artist".to_string(),
                album: "Unknown Album".to_string(),
                album_artist: "Unknown Artist".to_string(),
                genre: String::new(),
                year: None,
                track_number: fallback_track,
                disc_number: Some(1),
                duration_ms: 0,
                sample_rate: 44100,
                channels: 2,
                bits_per_sample: 16,
                artwork_path: None,
                codec: ext.to_uppercase(),
                mtime_secs,
                ..Default::default()
            });
        }
    };

    let mut duration_ms = 0;
    let mut sample_rate = 44100;
    let mut channels = 2;
    let mut bits_per_sample = 16;
    let mut codec = ext.to_uppercase();

    if let Some(track) = probed.format.default_track() {
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
        codec = codec_label_from_symphonia(track.codec_params.codec, &ext);
    }

    // Uncompressed PCM duration fallback if n_frames was missing
    if duration_ms == 0
        && sample_rate > 0
        && channels > 0
        && bits_per_sample > 0
        && (ext == "wav" || ext == "aiff" || ext == "aif")
    {
        let bytes_per_sec =
            (sample_rate as u64) * (channels as u64) * (bits_per_sample as u64).div_ceil(8);
        if let Some(d) = (file_size * 1000).checked_div(bytes_per_sec) {
            duration_ms = d as u32;
        }
    }

    let mut title = String::new();
    let mut artist = String::new();
    let mut album = String::new();
    let mut album_artist = String::new();
    let mut genre = String::new();
    let mut year: Option<u32> = None;
    let mut track_number = fallback_track;
    let mut disc_number: Option<u32> = Some(1);
    let mut artwork_path = None;
    let mut replay_gain = crate::cloud::tag_parser::ReplayGainTags::default();

    // Helper to ingest one Symphonia metadata revision (handles both container
    // metadata like Vorbis/MP4 atoms and prepended ID3v2 headers in probed.metadata).
    let mut ingest_revision = |metadata: &symphonia::core::meta::MetadataRevision| {
        if artwork_path.is_none() {
            if let Some(visual) = metadata.visuals().first() {
                if let Some(art_dir) = art_dir {
                    let _ = fs::create_dir_all(art_dir);
                    let mut hasher = sha2::Sha256::default();
                    sha2::Digest::update(&mut hasher, &visual.data);
                    let hash = format!("{:x}", sha2::Digest::finalize(hasher));
                    let art_file = art_dir.join(format!("art_{}.img", &hash[..16]));
                    if !art_file.exists() {
                        let _ = fs::write(&art_file, &visual.data);
                    }
                    artwork_path = Some(art_file.to_string_lossy().to_string());
                }
            }
        }

        for tag in metadata.tags() {
            replay_gain.ingest_tag(&tag.key, &tag.value.to_string());
            match tag.std_key {
                Some(symphonia::core::meta::StandardTagKey::TrackTitle) if title.is_empty() => {
                    title = tag.value.to_string().trim().to_string();
                }
                Some(symphonia::core::meta::StandardTagKey::Artist) if artist.is_empty() => {
                    artist = tag.value.to_string().trim().to_string();
                }
                Some(symphonia::core::meta::StandardTagKey::Album) if album.is_empty() => {
                    album = tag.value.to_string().trim().to_string();
                }
                Some(symphonia::core::meta::StandardTagKey::AlbumArtist)
                    if album_artist.is_empty() =>
                {
                    album_artist = tag.value.to_string().trim().to_string();
                }
                Some(symphonia::core::meta::StandardTagKey::Genre) => {
                    let val = tag.value.to_string();
                    let parsed = crate::cloud::tag_parser::parse_multi_value_tag(&val);
                    for p in parsed {
                        if !genre
                            .split(';')
                            .any(|existing| existing.trim().eq_ignore_ascii_case(&p))
                        {
                            if !genre.is_empty() {
                                genre.push_str("; ");
                            }
                            genre.push_str(&p);
                        }
                    }
                }
                Some(symphonia::core::meta::StandardTagKey::Date) if year.is_none() => {
                    year = parse_year_tag(&tag.value.to_string());
                }
                Some(symphonia::core::meta::StandardTagKey::TrackNumber) => {
                    if let Some(num) = parse_number_tag(&tag.value.to_string()) {
                        track_number = Some(num);
                    }
                }
                Some(symphonia::core::meta::StandardTagKey::DiscNumber) => {
                    if let Some(num) = parse_number_tag(&tag.value.to_string()) {
                        disc_number = Some(num);
                    }
                }
                _ => {}
            }
        }
    };

    if let Some(metadata) = probed.format.metadata().current() {
        ingest_revision(metadata);
    }
    if let Some(probed_meta) = probed.metadata.get() {
        if let Some(metadata) = probed_meta.current() {
            ingest_revision(metadata);
        }
    }

    if title.is_empty() {
        title = fallback_title;
    }
    if artist.is_empty() {
        artist = "Unknown Artist".to_string();
    }
    if album.is_empty() {
        album = "Unknown Album".to_string();
    }
    if album_artist.is_empty() {
        album_artist = artist.clone();
    }

    Ok(LocalTrackInfo {
        path: path.to_string_lossy().to_string(),
        name: file_name,
        folder_path: folder_path.to_string(),
        size_bytes: file_size,
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
        replay_gain_track_gain: replay_gain.track_gain_db,
        replay_gain_album_gain: replay_gain.album_gain_db,
        replay_gain_track_peak: replay_gain.track_peak,
        replay_gain_album_peak: replay_gain.album_peak,
        codec,
        mtime_secs,
    })
}

/// Recursively scans `root_path` on the local file system for audio files.
///
/// Features:
/// - Skips hidden directories (`.`) and system caches (`Android/data`, `lost+found`).
/// - Protects against symlink loops with visited canonical path tracking.
/// - Generates standardized hierarchical folder paths (`format!("{} / {}", root_label, relative)`).
/// - Extracts metadata via Symphonia and `DsfReader`.
/// - Reports live progress via `on_progress`.
pub fn scan_local_directory<F>(
    root_path: &Path,
    root_label: &str,
    art_dir: Option<&Path>,
    on_progress: F,
) -> Result<Vec<LocalTrackInfo>, LocalScanError>
where
    F: FnMut(&LocalScanProgress),
{
    let empty_index: HashMap<String, (u64, i64, String)> = HashMap::new();
    let res = scan_local_directory_incremental(
        root_path,
        root_label,
        art_dir,
        &empty_index,
        on_progress,
    )?;
    Ok(res.new_or_updated)
}

/// Recursively scans `root_path` incrementally, skipping Symphonia metadata
/// probing for already-indexed files whose `(size_bytes, mtime_secs, folder_path)`
/// have not changed since the last scan.
pub fn scan_local_directory_incremental<F>(
    root_path: &Path,
    root_label: &str,
    art_dir: Option<&Path>,
    existing_index: &HashMap<String, (u64, i64, String)>,
    mut on_progress: F,
) -> Result<IncrementalLocalScanResult, LocalScanError>
where
    F: FnMut(&LocalScanProgress),
{
    if !root_path.exists() {
        return Err(LocalScanError::DirectoryNotFound(
            root_path.display().to_string(),
        ));
    }
    if !root_path.is_dir() {
        return Err(LocalScanError::NotADirectory(
            root_path.display().to_string(),
        ));
    }

    let root_canonical = fs::canonicalize(root_path).unwrap_or_else(|_| root_path.to_path_buf());

    // Fail fast with an actionable PermissionDenied error if the root directory
    // itself cannot be read (e.g. Android READ_MEDIA_AUDIO not granted).
    if let Err(e) = fs::read_dir(&root_canonical) {
        if e.kind() == ErrorKind::PermissionDenied {
            return Err(LocalScanError::PermissionDenied(
                root_path.display().to_string(),
            ));
        }
        return Err(LocalScanError::Io(e));
    }

    let mut visited_dirs: HashSet<PathBuf> = HashSet::new();
    let mut queue: VecDeque<PathBuf> = VecDeque::new();
    queue.push_back(root_canonical.clone());

    let mut files_found: u32 = 0;
    let mut skipped_unchanged: u32 = 0;
    let mut folders_visited: u32 = 0;
    let mut results: Vec<LocalTrackInfo> = Vec::new();

    while let Some(current_dir) = queue.pop_front() {
        let canonical_dir = fs::canonicalize(&current_dir).unwrap_or_else(|_| current_dir.clone());
        if !visited_dirs.insert(canonical_dir.clone()) {
            continue; // Cycle detection
        }

        folders_visited += 1;

        // Compute relative path from scan root
        let rel_path = current_dir
            .strip_prefix(&root_canonical)
            .unwrap_or(Path::new(""));

        let folder_path = normalize_folder_path(root_label, rel_path);

        on_progress(&LocalScanProgress {
            files_found,
            folders_visited,
            current_folder: folder_path.clone(),
        });

        let entries = match fs::read_dir(&current_dir) {
            Ok(rd) => rd,
            Err(e) => {
                eprintln!(
                    "[local_scanner] could not read directory {:?}: {:?}",
                    current_dir, e
                );
                continue;
            }
        };

        for entry_res in entries {
            let entry = match entry_res {
                Ok(e) => e,
                Err(_) => continue,
            };

            let file_name = entry.file_name();
            let name_str = file_name.to_string_lossy();

            // Skip hidden files/directories (e.g. .git, .thumbnails)
            if name_str.starts_with('.') {
                continue;
            }

            let path = entry.path();
            let file_type = match entry.file_type() {
                Ok(ft) => ft,
                Err(_) => continue,
            };

            let is_dir = file_type.is_dir() || (file_type.is_symlink() && path.is_dir());
            let is_file = file_type.is_file() || (file_type.is_symlink() && path.is_file());

            if is_dir {
                // Ignore Android root system directories (never skip a music subfolder named "data")
                let lower_name = name_str.to_lowercase();
                if lower_name == "lost+found"
                    || (current_dir == root_canonical && lower_name == "android")
                {
                    continue;
                }
                queue.push_back(path);
            } else if is_file && is_audio_file(&path) {
                let metadata = match fs::metadata(&path) {
                    Ok(m) => m,
                    Err(_) => continue,
                };
                let size_bytes = metadata.len();
                if size_bytes == 0 {
                    continue; // Skip 0-byte corrupt files
                }
                let mtime_secs = metadata
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs() as i64)
                    .unwrap_or(0);

                let path_str = path.to_string_lossy();
                if let Some((indexed_size, indexed_mtime, indexed_folder)) =
                    existing_index.get(path_str.as_ref())
                {
                    if *indexed_size == size_bytes
                        && *indexed_mtime == mtime_secs
                        && indexed_folder == &folder_path
                    {
                        skipped_unchanged += 1;
                        files_found += 1;
                        continue;
                    }
                }

                match extract_local_metadata(&path, size_bytes, &folder_path, art_dir) {
                    Ok(track) => {
                        results.push(track);
                        files_found += 1;
                    }
                    Err(e) => {
                        eprintln!(
                            "[local_scanner] error extracting metadata for {:?}: {:?}",
                            path, e
                        );
                    }
                }

                if files_found.is_multiple_of(25) {
                    on_progress(&LocalScanProgress {
                        files_found,
                        folders_visited,
                        current_folder: folder_path.clone(),
                    });
                }
            }
        }
    }

    on_progress(&LocalScanProgress {
        files_found,
        folders_visited,
        current_folder: root_label.to_string(),
    });

    Ok(IncrementalLocalScanResult {
        new_or_updated: results,
        total_found: files_found,
        skipped_unchanged,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn test_local_scanner_supported_audio_extensions() {
        assert!(is_audio_file(Path::new("song.flac")));
        assert!(is_audio_file(Path::new("song.WAV")));
        assert!(is_audio_file(Path::new("song.m4a")));
        assert!(is_audio_file(Path::new("song.mp3")));
        assert!(is_audio_file(Path::new("song.dsf")));
        assert!(is_audio_file(Path::new("song.opus")));
        assert!(!is_audio_file(Path::new("song.txt")));
        assert!(!is_audio_file(Path::new("image.jpg")));
        assert!(!is_audio_file(Path::new(".flac"))); // hidden dotfile without stem
    }

    #[test]
    fn test_local_scanner_folder_path_normalization() {
        assert_eq!(
            normalize_folder_path("Internal Storage", Path::new("")),
            "Internal Storage"
        );
        assert_eq!(
            normalize_folder_path("Internal Storage", Path::new("Music")),
            "Internal Storage / Music"
        );
        assert_eq!(
            normalize_folder_path("Internal Storage", Path::new("Music/Hi-Res/Rock")),
            "Internal Storage / Music / Hi-Res / Rock"
        );
        assert_eq!(
            normalize_folder_path("SD Card", Path::new("Lossless/Miles Davis")),
            "SD Card / Lossless / Miles Davis"
        );
    }

    #[test]
    fn test_local_scanner_tag_parsing() {
        assert_eq!(parse_number_tag("03"), Some(3));
        assert_eq!(parse_number_tag("5/12"), Some(5));
        assert_eq!(parse_number_tag("invalid"), None);

        assert_eq!(parse_year_tag("2023-11-06"), Some(2023));
        assert_eq!(parse_year_tag("1994"), Some(1994));
        assert_eq!(parse_year_tag("94"), Some(94));

        let (track, title) = parse_track_and_title("01 - Tum Mile");
        assert_eq!(track, Some(1));
        assert_eq!(title, "Tum Mile");

        let (track2, title2) = parse_track_and_title("So What");
        assert_eq!(track2, None);
        assert_eq!(title2, "So What");
    }

    #[test]
    fn test_local_scanner_synthetic_directory_traversal() {
        let temp_dir = std::env::temp_dir().join("bitdrop_scanner_test");
        let _ = fs::remove_dir_all(&temp_dir);
        fs::create_dir_all(temp_dir.join("Music/Jazz")).unwrap();
        fs::create_dir_all(temp_dir.join("Music/Rock")).unwrap();

        // Create empty non-audio file
        File::create(temp_dir.join("readme.txt"))
            .unwrap()
            .write_all(b"Hello")
            .unwrap();

        // Create dummy audio files with non-zero bytes
        File::create(temp_dir.join("Music/Jazz/01 - So What.flac"))
            .unwrap()
            .write_all(&[0u8; 128])
            .unwrap();
        File::create(temp_dir.join("Music/Rock/02 - Time.wav"))
            .unwrap()
            .write_all(&[0u8; 128])
            .unwrap();

        let mut progress_events = Vec::new();
        let scanned = scan_local_directory(&temp_dir, "Local Storage", None, |p| {
            progress_events.push(p.clone())
        })
        .unwrap();

        assert_eq!(scanned.len(), 2);
        assert!(!progress_events.is_empty());

        let jazz_track = scanned.iter().find(|t| t.name.contains("So What")).unwrap();
        assert_eq!(jazz_track.folder_path, "Local Storage / Music / Jazz");
        assert_eq!(jazz_track.title, "So What");
        assert_eq!(jazz_track.track_number, Some(1));

        let rock_track = scanned.iter().find(|t| t.name.contains("Time")).unwrap();
        assert_eq!(rock_track.folder_path, "Local Storage / Music / Rock");
        assert_eq!(rock_track.title, "Time");
        assert_eq!(rock_track.track_number, Some(2));

        let _ = fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn test_local_scanner_synthetic_dsf_metadata() {
        let temp_dir = std::env::temp_dir().join("bitdrop_dsf_scan_test");
        let _ = fs::remove_dir_all(&temp_dir);
        fs::create_dir_all(&temp_dir).unwrap();

        // Create a valid synthetic DSF container
        let block_size: u32 = 4096;
        let sample_count: u64 = 2822400 * 2; // 2 seconds
        let data_size: u64 = (sample_count / 8) * 2;
        let file_size: u64 = 28 + 52 + 12 + data_size;

        let mut dsf_bytes = Vec::new();
        // 1. DSD chunk (28 bytes)
        dsf_bytes.extend_from_slice(b"DSD ");
        dsf_bytes.extend_from_slice(&28u64.to_le_bytes());
        dsf_bytes.extend_from_slice(&file_size.to_le_bytes());
        dsf_bytes.extend_from_slice(&0u64.to_le_bytes()); // metadata_offset

        // 2. fmt chunk (52 bytes)
        dsf_bytes.extend_from_slice(b"fmt ");
        dsf_bytes.extend_from_slice(&52u64.to_le_bytes());
        dsf_bytes.extend_from_slice(&1u32.to_le_bytes()); // format version
        dsf_bytes.extend_from_slice(&0u32.to_le_bytes()); // format id
        dsf_bytes.extend_from_slice(&2u32.to_le_bytes()); // channel type (stereo)
        dsf_bytes.extend_from_slice(&2u32.to_le_bytes()); // channel count
        dsf_bytes.extend_from_slice(&2822400u32.to_le_bytes()); // sample rate
        dsf_bytes.extend_from_slice(&1u32.to_le_bytes()); // bits per sample
        dsf_bytes.extend_from_slice(&sample_count.to_le_bytes());
        dsf_bytes.extend_from_slice(&block_size.to_le_bytes());
        dsf_bytes.extend_from_slice(&0u32.to_le_bytes()); // reserved

        // 3. data chunk (12 bytes header + data_size bytes)
        dsf_bytes.extend_from_slice(b"data");
        dsf_bytes.extend_from_slice(&(12 + data_size).to_le_bytes());
        dsf_bytes.resize(file_size as usize, 0x55);

        let dsf_path = temp_dir.join("04 - Test DSD Track.dsf");
        File::create(&dsf_path)
            .unwrap()
            .write_all(&dsf_bytes)
            .unwrap();

        let track = extract_local_metadata(&dsf_path, file_size, "Local / DSD", None).unwrap();

        assert_eq!(track.title, "Test DSD Track");
        assert_eq!(track.track_number, Some(4));
        assert_eq!(track.sample_rate, 2822400);
        assert_eq!(track.bits_per_sample, 1);
        assert_eq!(track.channels, 2);
        assert_eq!(track.duration_ms, 2000);
        assert_eq!(track.folder_path, "Local / DSD");

        let _ = fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn test_local_scanner_incremental_skip_and_data_subfolder() {
        let temp_dir = std::env::temp_dir().join("bitdrop_incremental_scan_test");
        let _ = fs::remove_dir_all(&temp_dir);
        let data_album = temp_dir.join("Data");
        fs::create_dir_all(&data_album).unwrap();

        let track_a = temp_dir.join("01 - Alpha.flac");
        let track_b = data_album.join("02 - Beta.flac");
        fs::write(&track_a, b"synthetic flac bytes A").unwrap();
        fs::write(&track_b, b"synthetic flac bytes B").unwrap();

        let empty = HashMap::new();
        let first = scan_local_directory_incremental(&temp_dir, "Music", None, &empty, |_| {})
            .expect("first incremental scan");
        assert_eq!(first.total_found, 2);
        assert_eq!(first.skipped_unchanged, 0);
        assert_eq!(first.new_or_updated.len(), 2);
        assert!(first
            .new_or_updated
            .iter()
            .any(|t| t.folder_path == "Music / Data"));

        // Second pass with unchanged sizes & mtimes must fast-skip all files.
        let mut index = HashMap::new();
        for t in &first.new_or_updated {
            index.insert(
                t.path.clone(),
                (t.size_bytes, t.mtime_secs, t.folder_path.clone()),
            );
        }
        let second = scan_local_directory_incremental(&temp_dir, "Music", None, &index, |_| {})
            .expect("second incremental scan");
        assert_eq!(second.total_found, 2);
        assert_eq!(second.skipped_unchanged, 2);
        assert!(second.new_or_updated.is_empty());

        // Simulate an in-place tag edit where size is unchanged but mtime differs.
        let mut stale_mtime_index = index.clone();
        if let Some(entry) = stale_mtime_index.get_mut(&first.new_or_updated[0].path) {
            entry.1 = entry.1.saturating_sub(10);
        }
        let mtime_rescan =
            scan_local_directory_incremental(&temp_dir, "Music", None, &stale_mtime_index, |_| {})
                .expect("mtime rescan");
        assert_eq!(mtime_rescan.total_found, 2);
        assert_eq!(mtime_rescan.skipped_unchanged, 1);
        assert_eq!(mtime_rescan.new_or_updated.len(), 1);

        // Modify track_a size and add track_c; only those two should re-probe.
        fs::write(&track_a, b"synthetic flac bytes A - modified longer").unwrap();
        let track_c = temp_dir.join("03 - Gamma.mp3");
        fs::write(&track_c, b"synthetic mp3 bytes C").unwrap();

        let third = scan_local_directory_incremental(&temp_dir, "Music", None, &index, |_| {})
            .expect("third incremental scan");
        assert_eq!(third.total_found, 3);
        assert_eq!(third.skipped_unchanged, 1);
        assert_eq!(third.new_or_updated.len(), 2);

        let _ = fs::remove_dir_all(&temp_dir);
    }

    #[cfg(unix)]
    #[test]
    fn test_local_scanner_root_permission_denied() {
        use std::os::unix::fs::PermissionsExt;

        let temp_dir = std::env::temp_dir().join("bitdrop_perm_denied_scan_test");
        let _ = fs::remove_dir_all(&temp_dir);
        fs::create_dir_all(&temp_dir).unwrap();
        fs::set_permissions(&temp_dir, fs::Permissions::from_mode(0o000)).unwrap();

        let res =
            scan_local_directory_incremental(&temp_dir, "Locked", None, &HashMap::new(), |_| {});
        // Restore permissions before asserting so cleanup always succeeds.
        let _ = fs::set_permissions(&temp_dir, fs::Permissions::from_mode(0o755));
        let _ = fs::remove_dir_all(&temp_dir);

        // When running as root (uid 0), chmod 000 is still readable; otherwise must error.
        if let Err(err) = res {
            assert!(matches!(err, LocalScanError::PermissionDenied(_)));
        }
    }
}

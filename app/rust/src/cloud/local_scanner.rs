use std::collections::{HashSet, VecDeque};
use std::fs::{self, File};
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
}

/// Errors encountered during local directory scanning.
#[derive(Debug)]
pub enum LocalScanError {
    Io(std::io::Error),
    DirectoryNotFound(String),
    NotADirectory(String),
    ScanFailed(String),
}

impl std::fmt::Display for LocalScanError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(e) => write!(f, "I/O error during scan: {}", e),
            Self::DirectoryNotFound(p) => write!(f, "Directory not found: {}", p),
            Self::NotADirectory(p) => write!(f, "Path is not a directory: {}", p),
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

/// Extracts metadata from a local audio file on disk.
///
/// Supports native DSD (.dsf) container inspection and Symphonia format probing for
/// PCM/compressed streams (FLAC, WAV, ALAC, MP3, AAC, Opus, AIFF).
pub fn extract_local_metadata(
    path: &Path,
    file_size: u64,
    folder_path: &str,
    art_dir: Option<&Path>,
) -> Result<LocalTrackInfo, LocalScanError> {
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
                let hdr = dsf.header();
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
                    duration_ms: hdr.duration_ms,
                    sample_rate: hdr.sample_rate,
                    channels: (hdr.channel_num as u8).max(1),
                    bits_per_sample: 1,
                    artwork_path: None,
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
                ..Default::default()
            });
        }
    };

    let mut duration_ms = 0;
    let mut sample_rate = 44100;
    let mut channels = 2;
    let mut bits_per_sample = 16;

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

    // Check embedded artwork
    if let Some(metadata) = probed.format.metadata().current() {
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

        for tag in metadata.tags() {
            replay_gain.ingest_tag(&tag.key, &tag.value.to_string());
            match tag.std_key {
                Some(symphonia::core::meta::StandardTagKey::TrackTitle) => {
                    title = tag.value.to_string().trim().to_string();
                }
                Some(symphonia::core::meta::StandardTagKey::Artist) => {
                    artist = tag.value.to_string().trim().to_string();
                }
                Some(symphonia::core::meta::StandardTagKey::Album) => {
                    album = tag.value.to_string().trim().to_string();
                }
                Some(symphonia::core::meta::StandardTagKey::AlbumArtist) => {
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
                Some(symphonia::core::meta::StandardTagKey::Date) => {
                    year = parse_year_tag(&tag.value.to_string());
                }
                Some(symphonia::core::meta::StandardTagKey::TrackNumber) => {
                    if let Some(num) = parse_number_tag(&tag.value.to_string()) {
                        track_number = Some(num);
                    }
                }
                Some(symphonia::core::meta::StandardTagKey::DiscNumber) => {
                    disc_number = parse_number_tag(&tag.value.to_string());
                }
                _ => {}
            }
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
    mut on_progress: F,
) -> Result<Vec<LocalTrackInfo>, LocalScanError>
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

    let mut visited_dirs: HashSet<PathBuf> = HashSet::new();
    let mut queue: VecDeque<PathBuf> = VecDeque::new();
    queue.push_back(root_canonical.clone());

    let mut files_found: u32 = 0;
    let mut folders_visited: u32 = 0;
    let mut results: Vec<LocalTrackInfo> = Vec::new();

    while let Some(current_dir) = queue.pop_front() {
        if !visited_dirs.insert(current_dir.clone()) {
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

            if file_type.is_dir() {
                // Ignore Android system directories
                let lower_name = name_str.to_lowercase();
                if lower_name == "android" || lower_name == "lost+found" || lower_name == "data" {
                    continue;
                }
                queue.push_back(path);
            } else if file_type.is_file() && is_audio_file(&path) {
                let metadata = match entry.metadata() {
                    Ok(m) => m,
                    Err(_) => continue,
                };
                let size_bytes = metadata.len();
                if size_bytes == 0 {
                    continue; // Skip 0-byte corrupt files
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

    Ok(results)
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
}

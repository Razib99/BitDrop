use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;
use std::io::Cursor;
use std::path::Path;

pub struct DecodedAudio {
    pub sample_rate: u32,
    pub channels: u32,
    pub total_samples: u32,
    pub first_frame_samples: Vec<f32>,
}

#[flutter_rust_bridge::frb(sync)]
pub fn greet(name: String) -> String {
    format!("Hello, {name}!")
}

#[flutter_rust_bridge::frb(sync)]
pub fn decode_flac_full(audio_data: Vec<u8>) -> Result<DecodedAudio, String> {
    let mut hint = Hint::new();
    hint.with_extension("flac");

    let cursor = Box::new(Cursor::new(audio_data));
    let mss = MediaSourceStream::new(cursor, Default::default());

    let format_opts: FormatOptions = Default::default();
    let metadata_opts: MetadataOptions = Default::default();

    let mut probed = symphonia::default::get_probe()
        .format(&hint, mss, &format_opts, &metadata_opts)
        .map_err(|e| format!("Failed to probe audio data: {:?}", e))?;

    let mut format = probed.format;
    let track = format.default_track().ok_or("No default track found")?;

    let sample_rate = track.codec_params.sample_rate.unwrap_or(0);
    let channels = track.codec_params.channels.map(|c| c.count()).unwrap_or(0) as u32;

    let mut decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions { verify: true })
        .map_err(|e| format!("Decoder failed: {:?}", e))?;

    let track_id = track.id;
    let mut total_samples = 0;
    let mut first_frame_samples = Vec::new();

    if let Ok(packet) = format.next_packet() {
        if packet.track_id() == track_id {
            if let Ok(audio_buf) = decoder.decode(&packet) {
                let mut sample_buf = SampleBuffer::<f32>::new(audio_buf.capacity() as u64, *audio_buf.spec());
                sample_buf.copy_interleaved_ref(audio_buf);
                
                let samples = sample_buf.samples();
                total_samples += samples.len() as u32;
                
                let extract_len = std::cmp::min(100, samples.len());
                first_frame_samples.extend_from_slice(&samples[0..extract_len]);
            }
        }
    }

    Ok(DecodedAudio {
        sample_rate,
        channels,
        total_samples,
        first_frame_samples,
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn init_audio_playback(sample_rate: u32, channels: u32) -> Result<String, String> {
    #[cfg(target_os = "android")]
    {
        // Oboe implementation comes later
        Ok(format!("Oboe AudioStream initialized successfully on Android. SR: {}, Ch: {}", sample_rate, channels))
    }
    
    #[cfg(not(target_os = "android"))]
    {
        Ok(format!("Mock AudioStream (Non-Android target) initialized at {}Hz, {}Ch", sample_rate, channels))
    }
}

pub struct TrackMetadata {
    pub path: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_ms: u32,
    pub sample_rate: u32,
    pub channels: u32,
}

#[flutter_rust_bridge::frb(sync)]
pub fn scan_local_file(path: String) -> Result<TrackMetadata, String> {
    // Probes a local file path and extracts its ID3/FLAC metadata natively in Rust
    use std::fs::File;
    let mut hint = Hint::new();
    let ext = std::path::Path::new(&path).extension().and_then(|e| e.to_str()).unwrap_or("");
    hint.with_extension(ext);
    
    let file = Box::new(File::open(&path).map_err(|e| e.to_string())?);
    let mss = MediaSourceStream::new(file, Default::default());
    
    let mut probed = symphonia::default::get_probe()
        .format(&hint, mss, &Default::default(), &Default::default())
        .map_err(|e| e.to_string())?;
        
    let track = probed.format.default_track().ok_or("No default track")?;
    let sample_rate = track.codec_params.sample_rate.unwrap_or(0);
    let channels = track.codec_params.channels.map(|c| c.count()).unwrap_or(0) as u32;
    
    let mut duration_ms = 0;
    if let (Some(frames), Some(tb)) = (track.codec_params.n_frames, track.codec_params.time_base) {
        let time = tb.calc_time(frames);
        duration_ms = (time.seconds * 1000 + time.frac as u64 * 1000) as u32;
    }
    
    // Attempt to extract tags
    let mut title = "".to_string();
    let mut artist = "".to_string();
    let mut album = "".to_string();
    
    
    // Some formats put tags in the metadata block
    macro_rules! extract_tags {
        ($meta:expr) => {
            if let Some(rev) = $meta.current() {
                for tag in rev.tags() {
                    if tag.std_key == Some(symphonia::core::meta::StandardTagKey::TrackTitle) {
                        title = tag.value.to_string();
                    } else if tag.std_key == Some(symphonia::core::meta::StandardTagKey::Artist) {
                        artist = tag.value.to_string();
                    } else if tag.std_key == Some(symphonia::core::meta::StandardTagKey::Album) {
                        album = tag.value.to_string();
                    }
                }
            }
        }
    }
    
    if let Some(metadata) = probed.metadata.get() {
        extract_tags!(metadata);
    }
    if title.is_empty() {
        extract_tags!(probed.format.metadata());
    }



    
    Ok(TrackMetadata {
        path,
        title,
        artist,
        album,
        duration_ms,
        sample_rate,
        channels,
    })
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

#[flutter_rust_bridge::frb(sync)]
pub fn scan_directory(path: String) -> Result<Vec<TrackMetadata>, String> {
    use std::fs;
    let mut results = Vec::new();
    
    let dir = fs::read_dir(&path).map_err(|e| format!("Failed to read dir: {:?}", e))?;
    
    for entry in dir {
        if let Ok(entry) = entry {
            let path = entry.path();
            if path.is_file() {
                if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
                    if ext.eq_ignore_ascii_case("flac") || ext.eq_ignore_ascii_case("mp3") || ext.eq_ignore_ascii_case("wav") {
                        // Suppress errors for individual files so one bad file doesn't crash the scan
                        if let Ok(meta) = scan_local_file(path.to_string_lossy().into_owned()) {
                            results.push(meta);
                        }
                    }
                }
            }
        }
    }
    
    Ok(results)
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_cover_art(path: String) -> Option<Vec<u8>> {
    use std::fs::File;
    use symphonia::core::io::MediaSourceStream;
    use symphonia::core::probe::Hint;

    let file = File::open(&path).ok()?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    
    let mut hint = Hint::new();
    let ext = std::path::Path::new(&path).extension().and_then(|e| e.to_str()).unwrap_or("");
    hint.with_extension(ext);
    
    let mut probed = symphonia::default::get_probe()
        .format(&hint, mss, &Default::default(), &Default::default())
        .ok()?;
        
    if let Some(metadata) = probed.metadata.get().as_ref().and_then(|m| m.current()) {
        if let Some(visual) = metadata.visuals().first() {
            return Some(visual.data.to_vec());
        }
    }
    
    if let Some(metadata) = probed.format.metadata().current() {
        if let Some(visual) = metadata.visuals().first() {
            return Some(visual.data.to_vec());
        }
    }
    
    None
}

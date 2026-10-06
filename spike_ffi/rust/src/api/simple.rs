#[flutter_rust_bridge::frb(sync)] // Synchronous mode for simplicity of the demo
pub fn greet(name: String) -> String {
    format!("Hello from Rust, {name}! FFI Bridge is working.")
}

pub struct AudioDevice {
    pub name: String,
    pub bit_perfect_capable: bool,
    pub max_sample_rate: u32,
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_dummy_audio_device() -> AudioDevice {
    AudioDevice {
        name: "DUNU Titan X".to_string(),
        bit_perfect_capable: true,
        max_sample_rate: 192000,
    }
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

use symphonia::core::io::MediaSourceStream;
use symphonia::core::probe::Hint;
use symphonia::core::formats::FormatOptions;
use symphonia::core::meta::MetadataOptions;
use std::io::Cursor;

pub struct AudioMetadata {
    pub sample_rate: u32,
    pub channels: u32,
    pub bit_depth: u32,
    // Note: symphonia might not give duration directly without parsing the stream, 
    // but we can extract sample rate and channels easily.
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_flac_metadata(audio_data: Vec<u8>) -> Result<AudioMetadata, String> {
    // Create a hint to help the format registry guess what format reader is appropriate.
    let mut hint = Hint::new();
    hint.with_extension("flac");

    // Use a Cursor to provide the byte array to the MediaSourceStream
    let cursor = Box::new(Cursor::new(audio_data));
    let mss = MediaSourceStream::new(cursor, Default::default());

    // Use the default options for metadata and format readers.
    let format_opts: FormatOptions = Default::default();
    let metadata_opts: MetadataOptions = Default::default();

    // Probe the media source.
    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &format_opts, &metadata_opts)
        .map_err(|e| format!("Failed to probe audio data: {:?}", e))?;

    let format = probed.format;
    
    // Find the first audio track
    let track = format.tracks().iter().find(|t| t.codec_params.codec != symphonia::core::codecs::CODEC_TYPE_NULL)
        .ok_or("No audio track found")?;

    let sample_rate = track.codec_params.sample_rate.unwrap_or(0);
    let channels = track.codec_params.channels.map(|c| c.count()).unwrap_or(0) as u32;
    let bit_depth = track.codec_params.bits_per_sample.unwrap_or(0) as u32;

    Ok(AudioMetadata {
        sample_rate,
        channels,
        bit_depth,
    })
}

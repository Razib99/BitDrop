use std::collections::HashMap;
use std::time::Duration;

#[allow(dead_code)]
#[derive(Debug, Clone)]
pub struct StreamInfo {
    pub min_block_size: u16,
    pub max_block_size: u16,
    pub min_frame_size: u32,
    pub max_frame_size: u32,
    pub sample_rate: u32,
    pub channels: u8,
    pub bits_per_sample: u8,
    pub total_samples: u64,
    pub md5: [u8; 16],
    pub duration_seconds: f64,
}

#[allow(dead_code)]
#[derive(Debug, Clone)]
pub struct PictureBlockInfo {
    pub picture_type: u32,
    pub mime_type: String,
    pub description: String,
    pub width: u32,
    pub height: u32,
    pub data_offset: u64,
    pub data_length: u32,
}

#[allow(dead_code)]
#[derive(Debug, Clone)]
pub struct FlacMetadata {
    pub stream_info: StreamInfo,
    pub tags: HashMap<String, String>,
    pub vendor_string: String,
    pub pictures: Vec<PictureBlockInfo>,
    pub audio_data_start_offset: u64,
    pub bytes_inspected: usize,
}

#[allow(dead_code)]
#[derive(Debug, Clone)]
pub struct RangeMeasurement {
    pub url: String,
    pub range_header: String,
    pub status_code: u16,
    pub dns_and_connect_time: Duration,
    pub time_to_first_byte: Duration,
    pub total_download_time: Duration,
    pub bytes_downloaded: usize,
    pub speed_mbps: f64,
}

mod flac_parser;
mod models;
mod range_fetcher;

use flac_parser::{FlacProgressiveParser, ParseProgress};
use models::FlacMetadata;
use range_fetcher::RangeFetcher;
use std::env;
use std::fs::File;
use std::io::Read;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args: Vec<String> = env::args().collect();

    println!("=====================================================");
    println!("  BitDrop Phase 0 — Spike 2: Progressive FLAC Parser  ");
    println!("=====================================================\n");

    if args.len() < 2 || args[1] == "--self-test" {
        run_self_test()?;
        return Ok(());
    }

    match args[1].as_str() {
        "parse" => {
            if args.len() < 3 {
                eprintln!("Usage: spike-drive parse <path/to/file.flac>");
                return Ok(());
            }
            parse_local_file(&args[2])?;
        }
        "fetch-range" => {
            if args.len() < 3 {
                eprintln!("Usage: spike-drive fetch-range <url> [start_byte] [end_byte] [token]");
                return Ok(());
            }
            let url = &args[2];
            let start = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(0);
            let end = args.get(4).and_then(|s| s.parse().ok()).unwrap_or(262143); // default 256 KiB
            let token = args.get(5).map(|s| s.as_str());

            run_fetch_range(url, start, end, token).await?;
        }
        "stream-test" => {
            if args.len() < 3 {
                eprintln!("Usage: spike-drive stream-test <url> [token]");
                return Ok(());
            }
            let url = &args[2];
            let token = args.get(3).map(|s| s.as_str());

            run_stream_test(url, token).await?;
        }
        _ => {
            print_usage();
        }
    }

    Ok(())
}

fn print_usage() {
    println!("Available commands:");
    println!("  spike-drive --self-test               Run built-in synthetic FLAC verification");
    println!("  spike-drive parse <file.flac>         Progressively parse local FLAC file (first 16KB)");
    println!("  spike-drive fetch-range <url> [s] [e] [token]  Measure HTTP range TTFB and throughput");
    println!("  spike-drive stream-test <url> [token] Fetch first 16KB from remote URL and parse tags");
}

fn print_metadata(meta: &FlacMetadata) {
    let si = &meta.stream_info;
    println!("--- STREAMINFO ---");
    println!("  Sample Rate    : {} Hz", si.sample_rate);
    println!("  Channels       : {}", si.channels);
    println!("  Bit Depth      : {}-bit", si.bits_per_sample);
    println!("  Total Samples  : {}", si.total_samples);
    println!("  Duration       : {:.2} seconds ({:02}:{:02})",
        si.duration_seconds,
        (si.duration_seconds as u64) / 60,
        (si.duration_seconds as u64) % 60
    );
    println!("  Audio Data Start Offset: byte {}", meta.audio_data_start_offset);
    println!("  Bytes Inspected: {} bytes", meta.bytes_inspected);

    if !meta.tags.is_empty() {
        println!("\n--- VORBIS COMMENTS (Tags) ---");
        for (k, v) in &meta.tags {
            println!("  {}: {}", k, v);
        }
    }

    if !meta.pictures.is_empty() {
        println!("\n--- EMBEDDED PICTURES (Art blocks) ---");
        for (i, pic) in meta.pictures.iter().enumerate() {
            println!("  [Picture #{}] MIME: {}, Dims: {}x{}, Size: {} bytes, Data Offset: byte {}",
                i + 1, pic.mime_type, pic.width, pic.height, pic.data_length, pic.data_offset
            );
        }
    }
}

fn parse_local_file(path: &str) -> anyhow::Result<()> {
    println!("Opening local file: {}", path);
    let mut f = File::open(path)?;
    let mut buffer = vec![0u8; 16 * 1024]; // Read only first 16 KiB!
    let bytes_read = f.read(&mut buffer)?;
    buffer.truncate(bytes_read);

    println!("Read initial chunk of {} bytes", bytes_read);

    match FlacProgressiveParser::parse(&buffer, 0)? {
        ParseProgress::Complete(meta) => {
            println!(" Successfully parsed metadata from initial 16 KiB chunk!\n");
            print_metadata(&meta);
        }
        ParseProgress::NeedMoreBytes { offset, length, partial } => {
            println!("ℹ️  File requires additional range: offset={}, length={} bytes", offset, length);
            if let Some(meta) = partial {
                println!("Partial metadata available:");
                print_metadata(&meta);
            }
        }
    }
    Ok(())
}

async fn run_fetch_range(url: &str, start: u64, end: u64, token: Option<&str>) -> anyhow::Result<()> {
    println!("Issuing HTTP Range request: bytes={}-{} to {}", start, end, url);
    let fetcher = RangeFetcher::new()?;
    let (_data, m) = fetcher.fetch_range(url, start, end, token).await?;

    println!("\n--- Performance Measurement ---");
    println!("  HTTP Status           : {}", m.status_code);
    println!("  Time to First Byte    : {:.2} ms", m.time_to_first_byte.as_secs_f64() * 1000.0);
    println!("  Total Download Time   : {:.2} ms", m.total_download_time.as_secs_f64() * 1000.0);
    println!("  Payload Size          : {} bytes ({:.2} KiB)", m.bytes_downloaded, m.bytes_downloaded as f64 / 1024.0);
    println!("  Sustained Throughput  : {:.2} Mbps", m.speed_mbps);

    Ok(())
}

async fn run_stream_test(url: &str, token: Option<&str>) -> anyhow::Result<()> {
    println!("Performing progressive header fetch (first 16 KiB) from: {}", url);
    let fetcher = RangeFetcher::new()?;
    let (data, m) = fetcher.fetch_range(url, 0, 16383, token).await?;

    println!("Received 16 KiB in {:.2} ms (TTFB: {:.2} ms)",
        m.total_download_time.as_secs_f64() * 1000.0,
        m.time_to_first_byte.as_secs_f64() * 1000.0
    );

    match FlacProgressiveParser::parse(&data, 0)? {
        ParseProgress::Complete(meta) => {
            println!("\n Successfully parsed remote FLAC stream metadata!\n");
            print_metadata(&meta);
        }
        ParseProgress::NeedMoreBytes { offset, length, .. } => {
            println!("\n Header extended beyond 16 KiB; targeted secondary fetch needed: byte {}-{}",
                offset, offset + length as u64 - 1
            );
        }
    }

    Ok(())
}

/// Generates a synthetic FLAC byte stream with STREAMINFO, VORBIS_COMMENT,
/// and a simulated 2MB PICTURE block to prove that the progressive parser
/// skips the 2MB image without needing to allocate or download it!
fn run_self_test() -> anyhow::Result<()> {
    println!("Running Synthetic Progressive FLAC Parser Self-Test...");
    let mut synthetic = Vec::new();

    // 1. "fLaC" marker
    synthetic.extend_from_slice(b"fLaC");

    // 2. STREAMINFO block (34 bytes), not last (bit 7 = 0)
    synthetic.push(0x00); // is_last=0, type=0
    synthetic.extend_from_slice(&34u32.to_be_bytes()[1..4]); // length = 34 (24 bits)

    // STREAMINFO body: 96kHz, 2 channels, 24 bits, 10,000,000 samples (~104.16 seconds)
    synthetic.extend_from_slice(&4096u16.to_be_bytes()); // min block size
    synthetic.extend_from_slice(&4096u16.to_be_bytes()); // max block size
    synthetic.extend_from_slice(&[0, 0, 0]); // min frame
    synthetic.extend_from_slice(&[0, 0, 0]); // max frame

    // Pack 96000 (20 bits) | 2 channels (3 bits: val=1) | 24 bits (5 bits: val=23) | 10,000,000 samples (36 bits)
    let sr: u64 = 96000;
    let ch: u64 = 1; // 2 channels
    let bps: u64 = 23; // 24-bit
    let samples: u64 = 10_000_000;
    let packed: u64 = (sr << 44) | (ch << 41) | (bps << 36) | (samples & 0xF_FFFF_FFFF);
    synthetic.extend_from_slice(&packed.to_be_bytes());
    synthetic.extend_from_slice(&[0u8; 16]); // md5

    // 3. VORBIS_COMMENT block (not last)
    let mut comment_body = Vec::new();
    let vendor = "BitDrop Reference Encoder";
    comment_body.extend_from_slice(&(vendor.len() as u32).to_le_bytes());
    comment_body.extend_from_slice(vendor.as_bytes());

    let tags = vec![
        "TITLE=Aja",
        "ARTIST=Steely Dan",
        "ALBUM=Aja (24-bit/96kHz Remaster)",
        "TRACKNUMBER=2",
        "GENRE=Jazz Rock",
    ];
    comment_body.extend_from_slice(&(tags.len() as u32).to_le_bytes());
    for tag in tags {
        comment_body.extend_from_slice(&(tag.len() as u32).to_le_bytes());
        comment_body.extend_from_slice(tag.as_bytes());
    }

    synthetic.push(0x04); // is_last=0, type=4 (VORBIS_COMMENT)
    synthetic.extend_from_slice(&(comment_body.len() as u32).to_be_bytes()[1..4]);
    synthetic.extend_from_slice(&comment_body);

    // 4. PICTURE block (marked as LAST block: 0x80 | 0x06 = 0x86)
    // Simulated 2,500,000 byte (2.5 MB) album art!
    let simulated_art_len: u32 = 2_500_000;
    let mime = "image/jpeg";
    let desc = "Front Cover";
    let mut pic_header = Vec::new();
    pic_header.extend_from_slice(&3u32.to_be_bytes()); // type: Cover (front)
    pic_header.extend_from_slice(&(mime.len() as u32).to_be_bytes());
    pic_header.extend_from_slice(mime.as_bytes());
    pic_header.extend_from_slice(&(desc.len() as u32).to_be_bytes());
    pic_header.extend_from_slice(desc.as_bytes());
    pic_header.extend_from_slice(&1400u32.to_be_bytes()); // width: 1400
    pic_header.extend_from_slice(&1400u32.to_be_bytes()); // height: 1400
    pic_header.extend_from_slice(&24u32.to_be_bytes());   // depth: 24
    pic_header.extend_from_slice(&0u32.to_be_bytes());    // colors: 0
    pic_header.extend_from_slice(&simulated_art_len.to_be_bytes());

    let total_pic_block_len = (pic_header.len() as u32) + simulated_art_len;
    synthetic.push(0x86); // is_last=1, type=6 (PICTURE)
    synthetic.extend_from_slice(&total_pic_block_len.to_be_bytes()[1..4]);
    synthetic.extend_from_slice(&pic_header);

    // NOTE: We only have the first 16 KiB! We do NOT include the 2.5 MB image bytes in our buffer!
    println!("Total synthetic initial buffer size: {} bytes (< 16 KiB)", synthetic.len());
    assert!(synthetic.len() < 16384, "Test buffer must be smaller than 16 KiB");

    match FlacProgressiveParser::parse(&synthetic, 0)? {
        ParseProgress::Complete(meta) => {
            println!("✅ Self-Test PASSED!");
            println!("Successfully parsed STREAMINFO, VORBIS tags, and detected 2.5MB PICTURE block without downloading the picture payload!\n");
            print_metadata(&meta);
        }
        ParseProgress::NeedMoreBytes { .. } => {
            panic!("Self-test failed: expected complete metadata parse from initial buffer");
        }
    }

    Ok(())
}

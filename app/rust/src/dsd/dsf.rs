//! Sony DSF (DSD Stream File) container parser and bitstream demuxer.
//!
//! Parses DSF container headers (`'DSD '`, `'fmt '`, `'data'`), handles block-interleaved
//! multi-channel bitstreams (typically 4096-byte channel blocks), and normalizes LSB-first
//! DSF bit ordering into MSB-first representation via zero-cost bit reversal (`u8::reverse_bits`).

use super::DsdError;
use std::io::{Read, Seek, SeekFrom};

/// Standard DSD sampling rates.
pub const DSD64_RATE: u32 = 2_822_400; // 64 * 44.1 kHz
pub const DSD128_RATE: u32 = 5_644_800; // 128 * 44.1 kHz
pub const DSD256_RATE: u32 = 11_289_600; // 256 * 44.1 kHz
pub const DSD512_RATE: u32 = 22_579_200; // 512 * 44.1 kHz

/// Parsed metadata and layout header for a DSF container.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DsfHeader {
    /// Total file size reported in 'DSD ' chunk header.
    pub file_size: u64,
    /// Offset to ID3v2 metadata chunk (0 if not present).
    pub metadata_offset: u64,
    /// Channel type (1 = mono, 2 = stereo, 3 = 3ch, 4 = quad, 5 = 4ch, 6 = 5ch, 7 = 5.1).
    pub channel_type: u32,
    /// Number of audio channels (e.g. 1, 2, 6).
    pub channel_num: u32,
    /// Sampling frequency in Hz (e.g. 2,822,400 for DSD64).
    pub sample_rate: u32,
    /// Bits per sample (must be 1 for DSD).
    pub bits_per_sample: u32,
    /// Total number of 1-bit samples per channel.
    pub sample_count: u64,
    /// Interleaved block size per channel in bytes (typically 4,096).
    pub block_size_per_channel: usize,
    /// Byte offset in stream where audio block data begins.
    pub data_offset: u64,
    /// Total byte length of audio block data chunk.
    pub data_size: u64,
    /// Calculated duration in milliseconds.
    pub duration_ms: u32,
}

/// Streaming reader and demuxer for Sony DSF audio containers.
pub struct DsfReader<R: Read + Seek> {
    reader: R,
    header: DsfHeader,
    current_sample: u64,
    block_buffer_l: Vec<u8>,
    block_buffer_r: Vec<u8>,
    block_pos: usize,
    block_len: usize,
}

impl<R: Read + Seek> DsfReader<R> {
    /// Opens and validates a DSF stream, parsing container headers.
    pub fn open(mut reader: R) -> Result<Self, DsdError> {
        reader.seek(SeekFrom::Start(0))?;

        // 1. Read 'DSD ' chunk (28 bytes)
        let mut dsd_hdr = [0u8; 28];
        reader.read_exact(&mut dsd_hdr)?;

        if &dsd_hdr[0..4] != b"DSD " {
            return Err(DsdError::InvalidMagic);
        }
        let chunk_size = u64::from_le_bytes(dsd_hdr[4..12].try_into().unwrap());
        if chunk_size != 28 {
            return Err(DsdError::InvalidHeader(
                "Invalid DSD chunk size (must be 28)",
            ));
        }
        let file_size = u64::from_le_bytes(dsd_hdr[12..20].try_into().unwrap());
        let metadata_offset = u64::from_le_bytes(dsd_hdr[20..28].try_into().unwrap());

        // 2. Read 'fmt ' chunk (52 bytes)
        let mut fmt_hdr = [0u8; 52];
        reader.read_exact(&mut fmt_hdr)?;

        if &fmt_hdr[0..4] != b"fmt " {
            return Err(DsdError::InvalidHeader(
                "Missing fmt chunk following DSD chunk",
            ));
        }
        let fmt_chunk_size = u64::from_le_bytes(fmt_hdr[4..12].try_into().unwrap());
        if fmt_chunk_size != 52 {
            return Err(DsdError::InvalidHeader(
                "Invalid fmt chunk size (must be 52)",
            ));
        }
        let format_version = u32::from_le_bytes(fmt_hdr[12..16].try_into().unwrap());
        if format_version != 1 {
            return Err(DsdError::UnsupportedVersion(format_version));
        }
        let format_id = u32::from_le_bytes(fmt_hdr[16..20].try_into().unwrap());
        if format_id != 0 {
            return Err(DsdError::InvalidHeader(
                "Unsupported format ID (only raw DSD supported)",
            ));
        }
        let channel_type = u32::from_le_bytes(fmt_hdr[20..24].try_into().unwrap());
        let channel_num = u32::from_le_bytes(fmt_hdr[24..28].try_into().unwrap());
        if channel_num == 0 || channel_num > 8 {
            return Err(DsdError::UnsupportedChannelCount(channel_num));
        }
        let sample_rate = u32::from_le_bytes(fmt_hdr[28..32].try_into().unwrap());
        if sample_rate != DSD64_RATE
            && sample_rate != DSD128_RATE
            && sample_rate != DSD256_RATE
            && sample_rate != DSD512_RATE
        {
            return Err(DsdError::UnsupportedSampleRate(sample_rate));
        }
        let bits_per_sample = u32::from_le_bytes(fmt_hdr[32..36].try_into().unwrap());
        if bits_per_sample != 1 {
            return Err(DsdError::InvalidHeader("Bits per sample must be 1 for DSD"));
        }
        let sample_count = u64::from_le_bytes(fmt_hdr[36..44].try_into().unwrap());
        let block_size_per_channel =
            u32::from_le_bytes(fmt_hdr[44..48].try_into().unwrap()) as usize;
        if block_size_per_channel == 0 || block_size_per_channel > 65536 {
            return Err(DsdError::InvalidHeader("Invalid block size per channel"));
        }

        // 3. Read 'data' chunk header (12 bytes)
        let mut data_hdr = [0u8; 12];
        reader.read_exact(&mut data_hdr)?;

        if &data_hdr[0..4] != b"data" {
            return Err(DsdError::InvalidHeader("Missing data chunk"));
        }
        let data_chunk_size = u64::from_le_bytes(data_hdr[4..12].try_into().unwrap());
        if data_chunk_size < 12 {
            return Err(DsdError::InvalidHeader("Data chunk size too small"));
        }
        let data_size = data_chunk_size - 12;
        let data_offset = reader.stream_position()?;

        let duration_ms = if sample_rate > 0 {
            ((sample_count as f64 / sample_rate as f64) * 1000.0).round() as u32
        } else {
            0
        };

        let header = DsfHeader {
            file_size,
            metadata_offset,
            channel_type,
            channel_num,
            sample_rate,
            bits_per_sample,
            sample_count,
            block_size_per_channel,
            data_offset,
            data_size,
            duration_ms,
        };

        let mut dsf = Self {
            reader,
            header,
            current_sample: 0,
            block_buffer_l: vec![0u8; block_size_per_channel],
            block_buffer_r: vec![0u8; block_size_per_channel],
            block_pos: 0,
            block_len: 0,
        };

        // Pre-fill initial block frame
        dsf.fill_next_block_frame()?;
        Ok(dsf)
    }

    /// Read next interleaved channel block frame from the stream.
    fn fill_next_block_frame(&mut self) -> Result<(), DsdError> {
        let block_size = self.header.block_size_per_channel;
        let total_samples = self.header.sample_count;

        if self.current_sample >= total_samples {
            self.block_pos = 0;
            self.block_len = 0;
            return Ok(());
        }

        // Calculate remaining bytes for this block (handles final partial block)
        let remaining_samples = total_samples - self.current_sample;
        let remaining_bytes = remaining_samples.div_ceil(8) as usize;
        let bytes_to_read = block_size.min(remaining_bytes);

        if bytes_to_read == 0 {
            self.block_pos = 0;
            self.block_len = 0;
            return Ok(());
        }

        if self.header.channel_num == 1 {
            // Mono: channel 0 only
            self.reader
                .read_exact(&mut self.block_buffer_l[..bytes_to_read])?;
            // Copy Left into Right for stereo output
            self.block_buffer_r[..bytes_to_read]
                .copy_from_slice(&self.block_buffer_l[..bytes_to_read]);
        } else if self.header.channel_num >= 2 {
            // Stereo / Multi-channel: read channel 0 (Left), then channel 1 (Right)
            self.reader
                .read_exact(&mut self.block_buffer_l[..bytes_to_read])?;
            self.reader
                .read_exact(&mut self.block_buffer_r[..bytes_to_read])?;

            // If more than 2 channels, skip remaining channel blocks
            if self.header.channel_num > 2 {
                let skip_bytes = (self.header.channel_num as i64 - 2) * (block_size as i64);
                self.reader.seek(SeekFrom::Current(skip_bytes))?;
            }
        }

        // DSF stores bits within each byte LSB-first. Reverse bits to MSB-first
        // for DoP packaging and standard DSD decimation.
        for b in &mut self.block_buffer_l[..bytes_to_read] {
            *b = b.reverse_bits();
        }
        for b in &mut self.block_buffer_r[..bytes_to_read] {
            *b = b.reverse_bits();
        }

        self.block_pos = 0;
        self.block_len = bytes_to_read;
        Ok(())
    }

    /// Read raw MSB-first DSD bytes for Left and Right channels.
    ///
    /// Returns the number of bytes written to `out_l` and `out_r`.
    pub fn read_stereo_bytes(
        &mut self,
        out_l: &mut [u8],
        out_r: &mut [u8],
    ) -> Result<usize, DsdError> {
        let max_req = out_l.len().min(out_r.len());
        if max_req == 0 || self.current_sample >= self.header.sample_count {
            return Ok(0);
        }

        let mut total_written = 0;

        while total_written < max_req {
            if self.block_pos >= self.block_len {
                self.fill_next_block_frame()?;
                if self.block_len == 0 {
                    break; // EOF reached
                }
            }

            let available = self.block_len - self.block_pos;
            let needed = max_req - total_written;
            let to_copy = available.min(needed);

            out_l[total_written..total_written + to_copy]
                .copy_from_slice(&self.block_buffer_l[self.block_pos..self.block_pos + to_copy]);
            out_r[total_written..total_written + to_copy]
                .copy_from_slice(&self.block_buffer_r[self.block_pos..self.block_pos + to_copy]);

            self.block_pos += to_copy;
            total_written += to_copy;
            self.current_sample += (to_copy as u64) * 8;
        }

        Ok(total_written)
    }

    /// Seeks to a specific DSD sample offset in the bitstream.
    ///
    /// Returns the exact sample position aligned after seek.
    pub fn seek_to_sample(&mut self, target_sample: u64) -> Result<u64, DsdError> {
        let target = target_sample.min(self.header.sample_count);
        let block_size = self.header.block_size_per_channel;
        let samples_per_block = (block_size as u64) * 8;
        let frame_size = (block_size as u64) * (self.header.channel_num as u64);

        let target_frame_idx = target / samples_per_block;
        let sample_in_block = target % samples_per_block;
        let byte_in_block = (sample_in_block / 8) as usize;

        let frame_offset = self.header.data_offset + target_frame_idx * frame_size;
        self.reader.seek(SeekFrom::Start(frame_offset))?;

        self.current_sample = target_frame_idx * samples_per_block;
        self.fill_next_block_frame()?;

        // Advance to byte within the block
        self.block_pos = byte_in_block.min(self.block_len);
        self.current_sample += (self.block_pos as u64) * 8;

        Ok(self.current_sample)
    }

    /// Access parsed DSF container header.
    #[inline(always)]
    pub fn header(&self) -> &DsfHeader {
        &self.header
    }

    /// Current sample position in stream.
    #[inline(always)]
    pub fn current_sample(&self) -> u64 {
        self.current_sample
    }

    /// Total 1-bit samples per channel.
    #[inline(always)]
    pub fn total_samples(&self) -> u64 {
        self.header.sample_count
    }

    /// Duration in milliseconds.
    #[inline(always)]
    pub fn duration_ms(&self) -> u32 {
        self.header.duration_ms
    }

    /// Sampling rate in Hz (e.g. 2,822,400 for DSD64).
    #[inline(always)]
    pub fn sample_rate(&self) -> u32 {
        self.header.sample_rate
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    /// Helper to generate a valid synthetic DSF binary stream.
    fn create_synthetic_dsf(
        sample_rate: u32,
        channels: u32,
        block_size: u32,
        num_blocks_per_channel: usize,
    ) -> Vec<u8> {
        let mut dsf = Vec::new();

        let data_payload_size =
            (block_size as usize) * (channels as usize) * num_blocks_per_channel;
        let data_chunk_size = 12 + data_payload_size as u64;
        let file_size = 28 + 52 + data_chunk_size;
        let sample_count = (block_size as u64 * 8) * (num_blocks_per_channel as u64);

        // 1. 'DSD ' chunk (28 bytes)
        dsf.extend_from_slice(b"DSD ");
        dsf.extend_from_slice(&28u64.to_le_bytes());
        dsf.extend_from_slice(&file_size.to_le_bytes());
        dsf.extend_from_slice(&0u64.to_le_bytes()); // metadata offset

        // 2. 'fmt ' chunk (52 bytes)
        dsf.extend_from_slice(b"fmt ");
        dsf.extend_from_slice(&52u64.to_le_bytes());
        dsf.extend_from_slice(&1u32.to_le_bytes()); // version 1
        dsf.extend_from_slice(&0u32.to_le_bytes()); // format raw DSD
        dsf.extend_from_slice(&channels.to_le_bytes()); // channel type
        dsf.extend_from_slice(&channels.to_le_bytes()); // channel num
        dsf.extend_from_slice(&sample_rate.to_le_bytes());
        dsf.extend_from_slice(&1u32.to_le_bytes()); // bits per sample = 1
        dsf.extend_from_slice(&sample_count.to_le_bytes());
        dsf.extend_from_slice(&block_size.to_le_bytes());
        dsf.extend_from_slice(&0u32.to_le_bytes()); // reserved

        // 3. 'data' chunk
        dsf.extend_from_slice(b"data");
        dsf.extend_from_slice(&data_chunk_size.to_le_bytes());

        // Interleaved payload
        for block_idx in 0..num_blocks_per_channel {
            for ch in 0..channels {
                for i in 0..block_size {
                    // Unique pattern per channel and block to verify demuxing
                    let val = ((block_idx * 16 + ch as usize + i as usize) % 256) as u8;
                    dsf.push(val);
                }
            }
        }

        dsf
    }

    #[test]
    fn test_dsf_header_parsing_valid_stereo_dsd64() {
        let data = create_synthetic_dsf(DSD64_RATE, 2, 4096, 2);
        let cursor = Cursor::new(data);
        let reader = DsfReader::open(cursor).expect("Failed to open valid DSF");

        assert_eq!(reader.header().sample_rate, DSD64_RATE);
        assert_eq!(reader.header().channel_num, 2);
        assert_eq!(reader.header().block_size_per_channel, 4096);
        assert_eq!(reader.header().sample_count, 4096 * 8 * 2);
        assert_eq!(reader.duration_ms(), 23); // (4096 * 16) / 2822400 * 1000 ~ 23ms
    }

    #[test]
    fn test_dsf_header_parsing_valid_stereo_dsd128() {
        let data = create_synthetic_dsf(DSD128_RATE, 2, 4096, 4);
        let cursor = Cursor::new(data);
        let reader = DsfReader::open(cursor).expect("Failed to open valid DSD128 DSF");

        assert_eq!(reader.header().sample_rate, DSD128_RATE);
        assert_eq!(reader.header().channel_num, 2);
        assert_eq!(reader.header().sample_count, 4096 * 8 * 4);
    }

    #[test]
    fn test_dsf_header_corrupted_magic_rejection() {
        let mut data = create_synthetic_dsf(DSD64_RATE, 2, 4096, 1);
        data[0] = b'R';
        data[1] = b'I';
        data[2] = b'F';
        data[3] = b'F';

        let cursor = Cursor::new(data);
        let result = DsfReader::open(cursor);
        assert!(matches!(result, Err(DsdError::InvalidMagic)));
    }

    #[test]
    fn test_dsf_header_invalid_chunk_size_rejection() {
        let mut data = create_synthetic_dsf(DSD64_RATE, 2, 4096, 1);
        // Corrupt 'DSD ' chunk size (offset 4..12)
        data[4] = 32;

        let cursor = Cursor::new(data);
        let result = DsfReader::open(cursor);
        assert!(matches!(result, Err(DsdError::InvalidHeader(_))));
    }

    #[test]
    fn test_dsf_block_demux_and_bit_reversal() {
        // Create 1 block of 64 bytes with specific test byte
        let mut dsf = Vec::new();
        let block_size = 64u32;
        let channels = 2u32;
        let data_payload_size = (block_size as usize) * 2;
        let data_chunk_size = 12 + data_payload_size as u64;
        let file_size = 28 + 52 + data_chunk_size;
        let sample_count = (block_size as u64) * 8;

        dsf.extend_from_slice(b"DSD ");
        dsf.extend_from_slice(&28u64.to_le_bytes());
        dsf.extend_from_slice(&file_size.to_le_bytes());
        dsf.extend_from_slice(&0u64.to_le_bytes());

        dsf.extend_from_slice(b"fmt ");
        dsf.extend_from_slice(&52u64.to_le_bytes());
        dsf.extend_from_slice(&1u32.to_le_bytes());
        dsf.extend_from_slice(&0u32.to_le_bytes());
        dsf.extend_from_slice(&channels.to_le_bytes());
        dsf.extend_from_slice(&channels.to_le_bytes());
        dsf.extend_from_slice(&DSD64_RATE.to_le_bytes());
        dsf.extend_from_slice(&1u32.to_le_bytes());
        dsf.extend_from_slice(&sample_count.to_le_bytes());
        dsf.extend_from_slice(&block_size.to_le_bytes());
        dsf.extend_from_slice(&0u32.to_le_bytes());

        dsf.extend_from_slice(b"data");
        dsf.extend_from_slice(&data_chunk_size.to_le_bytes());

        // Left channel filled with 0b00000001 (LSB is 1)
        dsf.extend(vec![0b00000001u8; block_size as usize]);
        // Right channel filled with 0b10000000 (MSB is 1)
        dsf.extend(vec![0b10000000u8; block_size as usize]);

        let cursor = Cursor::new(dsf);
        let mut reader = DsfReader::open(cursor).expect("Failed to open");

        let mut buf_l = [0u8; 64];
        let mut buf_r = [0u8; 64];
        let n = reader
            .read_stereo_bytes(&mut buf_l, &mut buf_r)
            .expect("Read failed");

        assert_eq!(n, 64);
        // Bit reversal should invert bit orders:
        // 0b00000001 reversed is 0b10000000
        assert_eq!(buf_l[0], 0b10000000);
        // 0b10000000 reversed is 0b00000001
        assert_eq!(buf_r[0], 0b00000001);
    }

    #[test]
    fn test_dsf_sample_seek_alignment() {
        let data = create_synthetic_dsf(DSD64_RATE, 2, 512, 4);
        let cursor = Cursor::new(data);
        let mut reader = DsfReader::open(cursor).expect("Failed to open");

        // Seek to sample 4096 (which is start of block 1: 512 bytes * 8 = 4096 samples)
        let pos = reader.seek_to_sample(4096).expect("Seek failed");
        assert_eq!(pos, 4096);
        assert_eq!(reader.current_sample(), 4096);

        // Read bytes after seek
        let mut buf_l = [0u8; 128];
        let mut buf_r = [0u8; 128];
        let n = reader
            .read_stereo_bytes(&mut buf_l, &mut buf_r)
            .expect("Read failed");
        assert_eq!(n, 128);
        assert_eq!(reader.current_sample(), 4096 + 128 * 8);
    }
}

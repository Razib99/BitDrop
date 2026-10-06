use std::collections::HashMap;
use std::convert::TryInto;
use crate::models::{FlacMetadata, PictureBlockInfo, StreamInfo};
use anyhow::{anyhow, bail, Result};

pub enum ParseProgress {
    Complete(FlacMetadata),
    NeedMoreBytes {
        offset: u64,
        length: usize,
        partial: Option<FlacMetadata>,
    },
}

pub struct FlacProgressiveParser;

impl FlacProgressiveParser {
    /// Parse metadata from a slice of bytes representing the beginning of a FLAC file.
    /// `buffer_start_offset` indicates the file offset of `buffer[0]` (typically 0).
    pub fn parse(buffer: &[u8], buffer_start_offset: u64) -> Result<ParseProgress> {
        if buffer_start_offset != 0 {
            bail!("Initial parse must start at offset 0");
        }

        if buffer.len() < 4 {
            return Ok(ParseProgress::NeedMoreBytes {
                offset: 0,
                length: 16 * 1024,
                partial: None,
            });
        }

        // Verify magic number "fLaC"
        if &buffer[0..4] != b"fLaC" {
            bail!("Invalid FLAC file: missing 'fLaC' marker at offset 0");
        }

        let mut offset = 4usize;
        let mut stream_info: Option<StreamInfo> = None;
        let mut tags = HashMap::new();
        let mut vendor_string = String::new();
        let mut pictures = Vec::new();
        let mut is_last = false;

        while !is_last {
            // Need at least 4 bytes for metadata block header
            if offset + 4 > buffer.len() {
                return Ok(ParseProgress::NeedMoreBytes {
                    offset: offset as u64,
                    length: 16 * 1024,
                    partial: None,
                });
            }

            let header_byte = buffer[offset];
            is_last = (header_byte & 0x80) != 0;
            let block_type = header_byte & 0x7F;

            let block_length = ((buffer[offset + 1] as usize) << 16)
                | ((buffer[offset + 2] as usize) << 8)
                | (buffer[offset + 3] as usize);

            let block_data_start = offset + 4;
            let next_block_offset = block_data_start + block_length;

            match block_type {
                0 => {
                    // STREAMINFO (mandatory 34 bytes)
                    if block_length != 34 {
                        bail!("Invalid STREAMINFO length: expected 34, got {}", block_length);
                    }
                    if block_data_start + 34 > buffer.len() {
                        return Ok(ParseProgress::NeedMoreBytes {
                            offset: block_data_start as u64,
                            length: 34,
                            partial: None,
                        });
                    }

                    let si = Self::parse_streaminfo(&buffer[block_data_start..block_data_start + 34])?;
                    stream_info = Some(si);
                }
                4 => {
                    // VORBIS_COMMENT
                    if block_data_start + block_length <= buffer.len() {
                        let (vendor, parsed_tags) = Self::parse_vorbis_comment(
                            &buffer[block_data_start..block_data_start + block_length],
                        )?;
                        vendor_string = vendor;
                        tags = parsed_tags;
                    } else {
                        // The comment block extends beyond our current buffer
                        return Ok(ParseProgress::NeedMoreBytes {
                            offset: block_data_start as u64,
                            length: block_length,
                            partial: stream_info.map(|si| FlacMetadata {
                                stream_info: si,
                                tags: HashMap::new(),
                                vendor_string: String::new(),
                                pictures: pictures.clone(),
                                audio_data_start_offset: 0,
                                bytes_inspected: offset,
                            }),
                        });
                    }
                }
                6 => {
                    // PICTURE
                    // Format-aware optimization: parse the header to record dimensions/MIME,
                    // but skip downloading the bulk picture payload if it extends far.
                    if let Ok(pic_info) = Self::parse_picture_header(
                        &buffer[block_data_start..std::cmp::min(buffer.len(), next_block_offset)],
                        block_data_start as u64,
                    ) {
                        pictures.push(pic_info);
                    }
                }
                _ => {
                    // PADDING, APPLICATION, SEEKTABLE, CUESHEET, etc.
                    // Just skip block body
                }
            }

            offset = next_block_offset;
        }

        let si = stream_info.ok_or_else(|| anyhow!("FLAC missing STREAMINFO block"))?;

        Ok(ParseProgress::Complete(FlacMetadata {
            stream_info: si,
            tags,
            vendor_string,
            pictures,
            audio_data_start_offset: offset as u64,
            bytes_inspected: offset,
        }))
    }

    fn parse_streaminfo(data: &[u8]) -> Result<StreamInfo> {
        let min_block_size = u16::from_be_bytes(data[0..2].try_into()?);
        let max_block_size = u16::from_be_bytes(data[2..4].try_into()?);
        let min_frame_size = u32::from_be_bytes([0, data[4], data[5], data[6]]);
        let max_frame_size = u32::from_be_bytes([0, data[7], data[8], data[9]]);

        let packed_64 = u64::from_be_bytes(data[10..18].try_into()?);
        let sample_rate = ((packed_64 >> 44) & 0xF_FFFF) as u32;
        let channels = (((packed_64 >> 41) & 0x07) + 1) as u8;
        let bits_per_sample = (((packed_64 >> 36) & 0x1F) + 1) as u8;
        let total_samples = packed_64 & 0xF_FFFF_FFFF;

        let mut md5 = [0u8; 16];
        md5.copy_from_slice(&data[18..34]);

        let duration_seconds = if sample_rate > 0 {
            total_samples as f64 / sample_rate as f64
        } else {
            0.0
        };

        Ok(StreamInfo {
            min_block_size,
            max_block_size,
            min_frame_size,
            max_frame_size,
            sample_rate,
            channels,
            bits_per_sample,
            total_samples,
            md5,
            duration_seconds,
        })
    }

    fn parse_vorbis_comment(data: &[u8]) -> Result<(String, HashMap<String, String>)> {
        let mut cur = 0;
        if data.len() < 4 {
            bail!("Vorbis comment block too short");
        }

        let vendor_len = u32::from_le_bytes(data[cur..cur + 4].try_into()?) as usize;
        cur += 4;
        if cur + vendor_len > data.len() {
            bail!("Vorbis vendor string truncated");
        }

        let vendor_string = String::from_utf8_lossy(&data[cur..cur + vendor_len]).to_string();
        cur += vendor_len;

        if cur + 4 > data.len() {
            bail!("Vorbis comment count truncated");
        }
        let user_comment_count = u32::from_le_bytes(data[cur..cur + 4].try_into()?) as usize;
        cur += 4;

        let mut tags = HashMap::new();
        for _ in 0..user_comment_count {
            if cur + 4 > data.len() {
                break;
            }
            let comment_len = u32::from_le_bytes(data[cur..cur + 4].try_into()?) as usize;
            cur += 4;
            if cur + comment_len > data.len() {
                break;
            }

            let comment_str = String::from_utf8_lossy(&data[cur..cur + comment_len]);
            if let Some(pos) = comment_str.find('=') {
                let key = comment_str[..pos].to_uppercase();
                let val = comment_str[pos + 1..].to_string();
                tags.insert(key, val);
            }
            cur += comment_len;
        }

        Ok((vendor_string, tags))
    }

    fn parse_picture_header(data: &[u8], block_data_start: u64) -> Result<PictureBlockInfo> {
        let mut cur = 0;
        if data.len() < 32 {
            bail!("Picture header too short");
        }

        let picture_type = u32::from_be_bytes(data[cur..cur + 4].try_into()?);
        cur += 4;

        let mime_len = u32::from_be_bytes(data[cur..cur + 4].try_into()?) as usize;
        cur += 4;
        if cur + mime_len > data.len() {
            bail!("Picture MIME truncated");
        }
        let mime_type = String::from_utf8_lossy(&data[cur..cur + mime_len]).to_string();
        cur += mime_len;

        if cur + 4 > data.len() {
            bail!("Picture description length truncated");
        }
        let desc_len = u32::from_be_bytes(data[cur..cur + 4].try_into()?) as usize;
        cur += 4;
        if cur + desc_len > data.len() {
            bail!("Picture description truncated");
        }
        let description = String::from_utf8_lossy(&data[cur..cur + desc_len]).to_string();
        cur += desc_len;

        if cur + 16 > data.len() {
            bail!("Picture dimensions truncated");
        }
        let width = u32::from_be_bytes(data[cur..cur + 4].try_into()?);
        let height = u32::from_be_bytes(data[cur + 4..cur + 8].try_into()?);
        cur += 16; // width (4) + height (4) + depth (4) + colors (4)

        if cur + 4 > data.len() {
            bail!("Picture data length truncated");
        }
        let data_length = u32::from_be_bytes(data[cur..cur + 4].try_into()?);
        cur += 4;

        let data_offset = block_data_start + cur as u64;

        Ok(PictureBlockInfo {
            picture_type,
            mime_type,
            description,
            width,
            height,
            data_offset,
            data_length,
        })
    }
}

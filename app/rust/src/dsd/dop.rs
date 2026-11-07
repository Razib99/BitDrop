//! DoP (DSD over PCM) v1.1 framing, packing, and detection engine.
//!
//! Conforms to the DoP Open Standard Version 1.1 (by dCS, Playback Designs, Meitner).
//!
//! Enables native 1-bit DSD bitstreams (DSD64 at 2.8224 MHz, DSD128 at 5.6448 MHz)
//! to be transmitted losslessly across standard PCM audio pipelines and USB Audio Class
//! (UAC1/UAC2) endpoints without any digital-to-analog or PCM filtering conversion.
//!
//! Frame structure per channel (24-bit PCM container):
//! - Bits 23..16: Alternating 8-bit DSD marker (`0x05` and `0xFA`)
//! - Bits 15..8:  DSD data byte 0 (MSB played first)
//! - Bits 7..0:   DSD data byte 1 (MSB played second)

use super::DsdError;
use crate::usb_dac::streaming::PcmFormat;

/// DoP v1.1 marker byte A (0b00000101).
pub const DOP_MARKER_A: u8 = 0x05;
/// DoP v1.1 marker byte B (0b11111010, bitwise NOT of 0x05).
pub const DOP_MARKER_B: u8 = 0xFA;
/// Standard 0V DSD silence byte (0b10101010).
pub const DSD_SILENCE_BYTE: u8 = 0xAA;
/// Number of consecutive valid alternating frames required to lock DoP detection.
pub const DOP_LOCK_THRESHOLD_FRAMES: usize = 32;

/// Resolves required PCM sample rate for a given native DSD sample rate under DoP v1.1.
pub fn dop_pcm_sample_rate(dsd_rate: u32) -> Result<u32, DsdError> {
    match dsd_rate {
        2_822_400 => Ok(176_400), // DSD64 -> 176.4 kHz PCM
        5_644_800 => Ok(352_800), // DSD128 -> 352.8 kHz DXD PCM
        _ => Err(DsdError::UnsupportedSampleRate(dsd_rate)),
    }
}

/// DoP v1.1 stereo framing and packaging engine.
#[derive(Debug, Clone)]
pub struct DopFramer {
    pcm_format: PcmFormat,
    marker_phase: bool, // false = DOP_MARKER_A (0x05), true = DOP_MARKER_B (0xFA)
}

impl DopFramer {
    /// Constructs a new DoP framer targeting the given USB PCM format.
    ///
    /// Accepts `PcmFormat::S24_3Le`, `PcmFormat::S24_4Le`, or `PcmFormat::S32Le`.
    pub fn new(pcm_format: PcmFormat) -> Result<Self, DsdError> {
        match pcm_format {
            PcmFormat::S24_3Le | PcmFormat::S24_4Le | PcmFormat::S32Le => Ok(Self {
                pcm_format,
                marker_phase: false,
            }),
            _ => Err(DsdError::InvalidHeader(
                "DoP requires 24-bit or 32-bit PCM containers",
            )),
        }
    }

    /// Resets marker phase back to initial 0x05 state.
    pub fn reset(&mut self) {
        self.marker_phase = false;
    }

    /// Current target PCM format.
    #[inline(always)]
    pub fn pcm_format(&self) -> PcmFormat {
        self.pcm_format
    }

    /// Next marker byte for the upcoming stereo frame.
    #[inline(always)]
    pub fn current_marker(&self) -> u8 {
        if self.marker_phase {
            DOP_MARKER_B
        } else {
            DOP_MARKER_A
        }
    }

    /// Advances the marker phase to the next frame.
    #[inline(always)]
    pub fn advance_marker(&mut self) {
        self.marker_phase = !self.marker_phase;
    }

    /// Encodes stereo DSD byte slices into packed PCM wire-format bytes.
    ///
    /// Consumes 2 bytes from `dsd_l` and 2 bytes from `dsd_r` per stereo frame.
    /// Returns `(dsd_bytes_consumed_per_channel, pcm_bytes_written)`.
    pub fn frame_stereo(
        &mut self,
        dsd_l: &[u8],
        dsd_r: &[u8],
        out_pcm: &mut [u8],
    ) -> (usize, usize) {
        let max_dsd_bytes = dsd_l.len().min(dsd_r.len());
        let frames_available = max_dsd_bytes / 2;
        let bytes_per_frame = self.pcm_format.bytes_per_frame(2);
        let max_frames_out = out_pcm.len() / bytes_per_frame;
        let frames_to_process = frames_available.min(max_frames_out);

        if frames_to_process == 0 {
            return (0, 0);
        }

        match self.pcm_format {
            PcmFormat::S24_3Le => {
                // 3 bytes per sample: [dsd1, dsd0, marker] in little-endian
                // Stereo frame = 6 bytes: Left (3) + Right (3)
                for f in 0..frames_to_process {
                    let marker = self.current_marker();
                    self.advance_marker();

                    let dsd_idx = f * 2;
                    let out_idx = f * 6;

                    let l0 = dsd_l[dsd_idx];
                    let l1 = dsd_l[dsd_idx + 1];
                    let r0 = dsd_r[dsd_idx];
                    let r1 = dsd_r[dsd_idx + 1];

                    // Left channel
                    out_pcm[out_idx] = l1;
                    out_pcm[out_idx + 1] = l0;
                    out_pcm[out_idx + 2] = marker;

                    // Right channel
                    out_pcm[out_idx + 3] = r1;
                    out_pcm[out_idx + 4] = r0;
                    out_pcm[out_idx + 5] = marker;
                }
            }
            PcmFormat::S24_4Le | PcmFormat::S32Le => {
                // 4 bytes per sample (MSB-aligned 24-bit): [0x00, dsd1, dsd0, marker]
                // Stereo frame = 8 bytes: Left (4) + Right (4)
                for f in 0..frames_to_process {
                    let marker = self.current_marker();
                    self.advance_marker();

                    let dsd_idx = f * 2;
                    let out_idx = f * 8;

                    let l0 = dsd_l[dsd_idx];
                    let l1 = dsd_l[dsd_idx + 1];
                    let r0 = dsd_r[dsd_idx];
                    let r1 = dsd_r[dsd_idx + 1];

                    // Left channel
                    out_pcm[out_idx] = 0x00;
                    out_pcm[out_idx + 1] = l1;
                    out_pcm[out_idx + 2] = l0;
                    out_pcm[out_idx + 3] = marker;

                    // Right channel
                    out_pcm[out_idx + 4] = 0x00;
                    out_pcm[out_idx + 5] = r1;
                    out_pcm[out_idx + 6] = r0;
                    out_pcm[out_idx + 7] = marker;
                }
            }
            _ => unreachable!(),
        }

        (frames_to_process * 2, frames_to_process * bytes_per_frame)
    }

    /// Generates standard DoP silence frames (0xAA DSD pattern with alternating markers).
    ///
    /// Essential for lead-in, lead-out, seeking, and pause to prevent loud pops or tweeter damage.
    /// Returns the number of PCM wire bytes written.
    pub fn write_silence_frames(&mut self, frame_count: usize, out_pcm: &mut [u8]) -> usize {
        let bytes_per_frame = self.pcm_format.bytes_per_frame(2);
        let frames_to_write = frame_count.min(out_pcm.len() / bytes_per_frame);

        match self.pcm_format {
            PcmFormat::S24_3Le => {
                for f in 0..frames_to_write {
                    let marker = self.current_marker();
                    self.advance_marker();

                    let out_idx = f * 6;
                    out_pcm[out_idx] = DSD_SILENCE_BYTE;
                    out_pcm[out_idx + 1] = DSD_SILENCE_BYTE;
                    out_pcm[out_idx + 2] = marker;
                    out_pcm[out_idx + 3] = DSD_SILENCE_BYTE;
                    out_pcm[out_idx + 4] = DSD_SILENCE_BYTE;
                    out_pcm[out_idx + 5] = marker;
                }
            }
            PcmFormat::S24_4Le | PcmFormat::S32Le => {
                for f in 0..frames_to_write {
                    let marker = self.current_marker();
                    self.advance_marker();

                    let out_idx = f * 8;
                    out_pcm[out_idx] = 0x00;
                    out_pcm[out_idx + 1] = DSD_SILENCE_BYTE;
                    out_pcm[out_idx + 2] = DSD_SILENCE_BYTE;
                    out_pcm[out_idx + 3] = marker;
                    out_pcm[out_idx + 4] = 0x00;
                    out_pcm[out_idx + 5] = DSD_SILENCE_BYTE;
                    out_pcm[out_idx + 6] = DSD_SILENCE_BYTE;
                    out_pcm[out_idx + 7] = marker;
                }
            }
            _ => unreachable!(),
        }

        frames_to_write * bytes_per_frame
    }
}

/// Real-time DoP v1.1 bitstream detector and lock tracker.
///
/// Inspects incoming PCM wire data, verifying continuous 0x05 / 0xFA marker alternation
/// across both stereo channels to prevent false PCM playback or loud ultrasonic bursts.
#[derive(Debug, Clone)]
pub struct DopDetector {
    pcm_format: PcmFormat,
    consecutive_valid_frames: usize,
    last_marker: Option<u8>,
    is_locked: bool,
}

impl DopDetector {
    /// Creates a new DoP detector for the specified PCM format.
    pub fn new(pcm_format: PcmFormat) -> Self {
        Self {
            pcm_format,
            consecutive_valid_frames: 0,
            last_marker: None,
            is_locked: false,
        }
    }

    /// Resets detection state and drops lock.
    pub fn reset(&mut self) {
        self.consecutive_valid_frames = 0;
        self.last_marker = None;
        self.is_locked = false;
    }

    /// Whether the detector is currently locked onto a valid DoP v1.1 stream.
    #[inline(always)]
    pub fn is_locked(&self) -> bool {
        self.is_locked
    }

    /// Number of consecutive valid DoP frames observed.
    #[inline(always)]
    pub fn valid_frame_count(&self) -> usize {
        self.consecutive_valid_frames
    }

    /// Processes a slice of stereo PCM wire bytes, updating the DoP lock state.
    ///
    /// Returns the number of stereo frames inspected.
    pub fn process_stereo_bytes(&mut self, pcm_bytes: &[u8]) -> usize {
        let bytes_per_frame = self.pcm_format.bytes_per_frame(2);
        let num_frames = pcm_bytes.len() / bytes_per_frame;

        for f in 0..num_frames {
            let (m_l, m_r) = match self.pcm_format {
                PcmFormat::S24_3Le => {
                    let idx = f * 6;
                    (pcm_bytes[idx + 2], pcm_bytes[idx + 5])
                }
                PcmFormat::S24_4Le | PcmFormat::S32Le => {
                    let idx = f * 8;
                    (pcm_bytes[idx + 3], pcm_bytes[idx + 7])
                }
                _ => return 0,
            };

            // Both channels must match and be a valid DoP marker (0x05 or 0xFA)
            let is_valid_marker = m_l == m_r && (m_l == DOP_MARKER_A || m_l == DOP_MARKER_B);

            // Must alternate relative to previous frame
            let is_alternating = match self.last_marker {
                Some(prev) => {
                    (prev == DOP_MARKER_A && m_l == DOP_MARKER_B)
                        || (prev == DOP_MARKER_B && m_l == DOP_MARKER_A)
                }
                None => true, // First frame establishes phase
            };

            if is_valid_marker && is_alternating {
                self.consecutive_valid_frames += 1;
                self.last_marker = Some(m_l);

                if self.consecutive_valid_frames >= DOP_LOCK_THRESHOLD_FRAMES {
                    self.is_locked = true;
                }
            } else {
                // Marker sequence broken: immediate unlock to protect speakers
                self.consecutive_valid_frames = 0;
                self.last_marker = None;
                self.is_locked = false;
            }
        }

        num_frames
    }
}

/// Decodes DoP v1.1 PCM wire frames back into raw Left and Right DSD bytes.
///
/// Useful for round-trip verification, bitstream analysis, and bit-exact testing.
#[derive(Debug, Clone)]
pub struct DopDecoder {
    pcm_format: PcmFormat,
}

impl DopDecoder {
    /// Creates a new DoP decoder for the given format.
    pub fn new(pcm_format: PcmFormat) -> Self {
        Self { pcm_format }
    }

    /// Decodes stereo DoP wire bytes into Left and Right DSD bytes.
    ///
    /// Returns the number of DSD bytes appended to each channel buffer.
    pub fn decode_stereo(
        &self,
        pcm_bytes: &[u8],
        dsd_l: &mut Vec<u8>,
        dsd_r: &mut Vec<u8>,
    ) -> usize {
        let bytes_per_frame = self.pcm_format.bytes_per_frame(2);
        let num_frames = pcm_bytes.len() / bytes_per_frame;

        dsd_l.reserve(num_frames * 2);
        dsd_r.reserve(num_frames * 2);

        for f in 0..num_frames {
            let (l0, l1, r0, r1) = match self.pcm_format {
                PcmFormat::S24_3Le => {
                    let idx = f * 6;
                    (
                        pcm_bytes[idx + 1],
                        pcm_bytes[idx],
                        pcm_bytes[idx + 4],
                        pcm_bytes[idx + 3],
                    )
                }
                PcmFormat::S24_4Le | PcmFormat::S32Le => {
                    let idx = f * 8;
                    (
                        pcm_bytes[idx + 2],
                        pcm_bytes[idx + 1],
                        pcm_bytes[idx + 6],
                        pcm_bytes[idx + 5],
                    )
                }
                _ => return 0,
            };

            dsd_l.push(l0);
            dsd_l.push(l1);
            dsd_r.push(r0);
            dsd_r.push(r1);
        }

        num_frames * 2
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_dop_pcm_sample_rate_resolution() {
        assert_eq!(dop_pcm_sample_rate(2_822_400).unwrap(), 176_400);
        assert_eq!(dop_pcm_sample_rate(5_644_800).unwrap(), 352_800);
        assert!(dop_pcm_sample_rate(44_100).is_err());
        assert!(dop_pcm_sample_rate(192_000).is_err());
    }

    #[test]
    fn test_dop_marker_alternation() {
        let mut framer = DopFramer::new(PcmFormat::S24_3Le).expect("Failed to create framer");

        assert_eq!(framer.current_marker(), DOP_MARKER_A);
        framer.advance_marker();
        assert_eq!(framer.current_marker(), DOP_MARKER_B);
        framer.advance_marker();
        assert_eq!(framer.current_marker(), DOP_MARKER_A);
        framer.reset();
        assert_eq!(framer.current_marker(), DOP_MARKER_A);
    }

    #[test]
    fn test_dop_encode_s24_3le_stereo() {
        let mut framer = DopFramer::new(PcmFormat::S24_3Le).expect("Failed to create framer");

        let dsd_l = [0x11u8, 0x22, 0x33, 0x44];
        let dsd_r = [0x55u8, 0x66, 0x77, 0x88];
        let mut out = [0u8; 12];

        let (dsd_consumed, pcm_written) = framer.frame_stereo(&dsd_l, &dsd_r, &mut out);

        assert_eq!(dsd_consumed, 4);
        assert_eq!(pcm_written, 12);

        // Frame 0 (Marker = 0x05):
        // Left: [0x22, 0x11, 0x05]
        assert_eq!(out[0], 0x22);
        assert_eq!(out[1], 0x11);
        assert_eq!(out[2], 0x05);
        // Right: [0x66, 0x55, 0x05]
        assert_eq!(out[3], 0x66);
        assert_eq!(out[4], 0x55);
        assert_eq!(out[5], 0x05);

        // Frame 1 (Marker = 0xFA):
        // Left: [0x44, 0x33, 0xFA]
        assert_eq!(out[6], 0x44);
        assert_eq!(out[7], 0x33);
        assert_eq!(out[8], 0xFA);
        // Right: [0x88, 0x77, 0xFA]
        assert_eq!(out[9], 0x88);
        assert_eq!(out[10], 0x77);
        assert_eq!(out[11], 0xFA);
    }

    #[test]
    fn test_dop_encode_s24_4le_stereo() {
        let mut framer = DopFramer::new(PcmFormat::S24_4Le).expect("Failed to create framer");

        let dsd_l = [0xAAu8, 0xBB];
        let dsd_r = [0xCCu8, 0xDD];
        let mut out = [0u8; 8];

        let (dsd_consumed, pcm_written) = framer.frame_stereo(&dsd_l, &dsd_r, &mut out);

        assert_eq!(dsd_consumed, 2);
        assert_eq!(pcm_written, 8);

        // Left: [0x00, 0xBB, 0xAA, 0x05]
        assert_eq!(&out[0..4], &[0x00, 0xBB, 0xAA, 0x05]);
        // Right: [0x00, 0xDD, 0xCC, 0x05]
        assert_eq!(&out[4..8], &[0x00, 0xDD, 0xCC, 0x05]);
    }

    #[test]
    fn test_dop_silence_generation() {
        let mut framer = DopFramer::new(PcmFormat::S24_3Le).expect("Failed to create framer");
        let mut out = [0u8; 18]; // 3 frames * 6 bytes

        let written = framer.write_silence_frames(3, &mut out);
        assert_eq!(written, 18);

        // Frame 0: marker 0x05, silence 0xAA
        assert_eq!(&out[0..3], &[0xAA, 0xAA, 0x05]);
        assert_eq!(&out[3..6], &[0xAA, 0xAA, 0x05]);

        // Frame 1: marker 0xFA, silence 0xAA
        assert_eq!(&out[6..9], &[0xAA, 0xAA, 0xFA]);
        assert_eq!(&out[9..12], &[0xAA, 0xAA, 0xFA]);

        // Frame 2: marker 0x05, silence 0xAA
        assert_eq!(&out[12..15], &[0xAA, 0xAA, 0x05]);
        assert_eq!(&out[15..18], &[0xAA, 0xAA, 0x05]);
    }

    #[test]
    fn test_dop_detector_lock_and_unlock() {
        let mut detector = DopDetector::new(PcmFormat::S24_3Le);
        assert!(!detector.is_locked());

        let mut framer = DopFramer::new(PcmFormat::S24_3Le).unwrap();
        let mut pcm_buffer = vec![0u8; 6 * 40]; // 40 stereo frames
        framer.write_silence_frames(40, &mut pcm_buffer);

        // Feed first 31 frames: not locked yet
        detector.process_stereo_bytes(&pcm_buffer[0..6 * 31]);
        assert_eq!(detector.valid_frame_count(), 31);
        assert!(!detector.is_locked());

        // Feed 1 more frame: exactly 32 -> should lock
        detector.process_stereo_bytes(&pcm_buffer[6 * 31..6 * 32]);
        assert_eq!(detector.valid_frame_count(), 32);
        assert!(detector.is_locked());

        // Feed remaining frames: stays locked
        detector.process_stereo_bytes(&pcm_buffer[6 * 32..]);
        assert_eq!(detector.valid_frame_count(), 40);
        assert!(detector.is_locked());

        // Corrupt stream with non-DoP PCM data (e.g. 0x00 markers)
        let corrupt = [0x00u8; 6];
        detector.process_stereo_bytes(&corrupt);
        assert!(!detector.is_locked());
        assert_eq!(detector.valid_frame_count(), 0);
    }

    #[test]
    fn test_dop_roundtrip_bit_exact() {
        let mut framer = DopFramer::new(PcmFormat::S24_3Le).unwrap();
        let decoder = DopDecoder::new(PcmFormat::S24_3Le);

        let orig_l: Vec<u8> = (0..200).map(|i| (i * 7 + 13) as u8).collect();
        let orig_r: Vec<u8> = (0..200).map(|i| (i * 11 + 29) as u8).collect();

        let mut pcm_encoded = vec![0u8; 100 * 6];
        let (consumed, written) = framer.frame_stereo(&orig_l, &orig_r, &mut pcm_encoded);
        assert_eq!(consumed, 200);
        assert_eq!(written, 600);

        let mut decoded_l = Vec::new();
        let mut decoded_r = Vec::new();
        let decoded_samples = decoder.decode_stereo(&pcm_encoded, &mut decoded_l, &mut decoded_r);

        assert_eq!(decoded_samples, 200);
        assert_eq!(orig_l, decoded_l, "Left channel DSD roundtrip mismatch!");
        assert_eq!(orig_r, decoded_r, "Right channel DSD roundtrip mismatch!");
    }
}

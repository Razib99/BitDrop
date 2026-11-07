//! USB Isochronous Audio Streaming Engine & Dual Feedback Pacing Loop.
//!
//! Handles high-performance, low-latency isochronous audio transfers via Linux `usbfs`,
//! featuring:
//! - Dual clock pacing:
//!   - Mode A (Asynchronous): 16.16 / 10.14 explicit feedback accumulation from IN feedback endpoints.
//!   - Mode B (Adaptive / Synchronous): Nominal clock ratio fractional pacing for DACs without feedback endpoints.
//! - Lock-free PCM frame formatting (S16_LE, S24_3LE, S24_4LE, S32_LE) from interleaved f32.
//! - Ring of in-flight Isochronous URBs with non-blocking reaping and jitter-free hardware scheduling.

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;

use crate::usb_dac::descriptors::{AudioFormatInfo, EndpointInfo, EndpointSyncType};
use crate::usb_dac::usbfs::{IsoUrb, UsbDeviceHandle, UsbFsError, UsbdevfsUrb};

/// Default number of packets (microframes) bundled into each Isochronous URB.
/// In USB 2.0 High Speed (125 µs microframes), 8 packets = 1.0 ms.
pub const DEFAULT_PACKETS_PER_URB: usize = 8;

/// Default number of in-flight URBs maintained in the USB controller hardware queue.
/// 4 URBs * 1.0 ms = 4.0 ms queued hardware buffer for glitch-free low latency.
pub const DEFAULT_IN_FLIGHT_URBS: usize = 4;

/// Supported PCM sample formats for USB Audio Class endpoints.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PcmFormat {
    /// 16-bit signed PCM (2 bytes per sample, little-endian).
    S16Le,
    /// 24-bit signed PCM packed into 3 bytes (little-endian).
    S24_3Le,
    /// 24-bit signed PCM in 4-byte subslot (MSB aligned: bits 31..8, byte 0 is padding).
    S24_4Le,
    /// 32-bit signed PCM (4 bytes per sample, little-endian).
    S32Le,
}

impl PcmFormat {
    /// Bytes required for one sample in this format.
    #[inline]
    pub fn bytes_per_sample(&self) -> usize {
        match self {
            Self::S16Le => 2,
            Self::S24_3Le => 3,
            Self::S24_4Le | Self::S32Le => 4,
        }
    }

    /// Bytes required for one multi-channel frame.
    #[inline]
    pub fn bytes_per_frame(&self, channels: usize) -> usize {
        self.bytes_per_sample() * channels
    }

    /// Resolves standard PCM format from parsed descriptor `AudioFormatInfo`.
    pub fn from_format_info(info: &AudioFormatInfo) -> Option<Self> {
        match (info.bit_resolution, info.subslot_size) {
            (16, 2) => Some(Self::S16Le),
            (24, 3) => Some(Self::S24_3Le),
            (24, 4) => Some(Self::S24_4Le),
            (32, 4) => Some(Self::S32Le),
            // Graceful fallback for devices reporting bit_resolution <= 16 with 2-byte slots
            (b, 2) if b <= 16 => Some(Self::S16Le),
            // Fallback for 24-bit reported with varying subslots
            (24, _) => Some(Self::S24_3Le),
            // Fallback for 32-bit
            (32, _) => Some(Self::S32Le),
            _ => None,
        }
    }

    /// Formats a buffer of interleaved normalized `f32` audio samples (`[-1.0, 1.0]`)
    /// into wire-format PCM bytes.
    ///
    /// Returns the total number of bytes written to `output`.
    pub fn format_interleaved_f32(&self, input_f32: &[f32], output: &mut [u8]) -> usize {
        let bpc = self.bytes_per_sample();
        let required_bytes = input_f32.len() * bpc;
        assert!(
            output.len() >= required_bytes,
            "Destination buffer too small: need {} bytes, got {}",
            required_bytes,
            output.len()
        );

        match self {
            Self::S16Le => {
                for (i, &sample) in input_f32.iter().enumerate() {
                    let clamped = sample.clamp(-1.0, 1.0);
                    let val = (clamped * 32767.0).round() as i16;
                    let bytes = val.to_le_bytes();
                    output[i * 2] = bytes[0];
                    output[i * 2 + 1] = bytes[1];
                }
            }
            Self::S24_3Le => {
                for (i, &sample) in input_f32.iter().enumerate() {
                    let clamped = sample.clamp(-1.0, 1.0);
                    let val = (clamped * 8388607.0).round() as i32;
                    let bytes = val.to_le_bytes();
                    output[i * 3] = bytes[0];
                    output[i * 3 + 1] = bytes[1];
                    output[i * 3 + 2] = bytes[2];
                }
            }
            Self::S24_4Le => {
                for (i, &sample) in input_f32.iter().enumerate() {
                    let clamped = sample.clamp(-1.0, 1.0);
                    let val = ((clamped * 8388607.0).round() as i32) << 8;
                    let bytes = val.to_le_bytes();
                    output[i * 4..i * 4 + 4].copy_from_slice(&bytes);
                }
            }
            Self::S32Le => {
                for (i, &sample) in input_f32.iter().enumerate() {
                    let clamped = sample.clamp(-1.0, 1.0) as f64;
                    let val = (clamped * 2147483647.0).round() as i32;
                    let bytes = val.to_le_bytes();
                    output[i * 4..i * 4 + 4].copy_from_slice(&bytes);
                }
            }
        }

        required_bytes
    }
}

/// Pacer synchronization mode for isochronous streaming.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PacerMode {
    /// Explicit feedback from an asynchronous IN endpoint (UAC2 16.16 or UAC1 10.14).
    AsynchronousFeedback,
    /// Host-driven fractional accumulator pacing (DUNU Titan X, Type-C IEMs, Synchronous/Adaptive).
    AdaptiveNominal,
}

/// Dual-mode isochronous clock pacer.
///
/// Converts a sample rate (e.g. 44100, 48000, 96000, 192000 Hz) and USB packet rate
/// (e.g. 8000 microframes/s for High Speed, 1000 frames/s for Full Speed) into the exact
/// discrete frame count for each consecutive USB packet with zero long-term clock drift.
#[derive(Debug, Clone)]
pub struct AudioPacer {
    mode: PacerMode,
    sample_rate: u32,
    packets_per_sec: u32,
    nominal_rate_q16: u32,
    current_rate_q16: u32,
    feedback_accum_q16: u32,
    nominal_accum: u64,
    drift_ppm: i32,
    consecutive_packets: u64,
    total_samples_generated: u64,
    min_allowed_rate_q16: u32,
    max_allowed_rate_q16: u32,
}

impl AudioPacer {
    /// Creates a new pacer with nominal rate calculation.
    pub fn new(mode: PacerMode, sample_rate: u32, packets_per_sec: u32) -> Self {
        assert!(sample_rate > 0, "sample_rate must be > 0");
        assert!(packets_per_sec > 0, "packets_per_sec must be > 0");

        let nominal_rate_q16 = ((sample_rate as u64 * 65536) / (packets_per_sec as u64)) as u32;

        let min_allowed_rate_q16 = ((nominal_rate_q16 as u64 * 80) / 100) as u32;
        let max_allowed_rate_q16 = ((nominal_rate_q16 as u64 * 120) / 100) as u32;

        Self {
            mode,
            sample_rate,
            packets_per_sec,
            nominal_rate_q16,
            current_rate_q16: nominal_rate_q16,
            feedback_accum_q16: 0,
            nominal_accum: 0,
            drift_ppm: 0,
            consecutive_packets: 0,
            total_samples_generated: 0,
            min_allowed_rate_q16,
            max_allowed_rate_q16,
        }
    }

    /// Creates a pacer configured from endpoint parameters and speed mode.
    pub fn from_endpoint(
        mode: PacerMode,
        sample_rate: u32,
        data_ep: &EndpointInfo,
        is_high_speed: bool,
    ) -> Self {
        let packets_per_sec = if is_high_speed {
            // High-Speed: microframe period = 2^(interval - 1) * 125 µs
            let exponent = data_ep.interval.saturating_sub(1).min(10);
            8000 / (1 << exponent)
        } else {
            // Full-Speed: interval in milliseconds
            1000 / (data_ep.interval.max(1) as u32)
        };

        Self::new(mode, sample_rate, packets_per_sec.max(1))
    }

    /// Auto-detects the pacer mode based on endpoint synchronization type and feedback endpoint.
    pub fn auto_detect_mode(
        data_ep: &EndpointInfo,
        feedback_ep: &Option<EndpointInfo>,
    ) -> PacerMode {
        if data_ep.sync_type == EndpointSyncType::Asynchronous && feedback_ep.is_some() {
            PacerMode::AsynchronousFeedback
        } else {
            PacerMode::AdaptiveNominal
        }
    }

    /// Returns the integer number of frames to emit for the next packet.
    pub fn next_packet_samples(&mut self) -> usize {
        let samples = match self.mode {
            PacerMode::AdaptiveNominal => {
                let effective_rate = if self.drift_ppm == 0 {
                    self.sample_rate as u64
                } else {
                    let delta = (self.sample_rate as i64 * self.drift_ppm as i64) / 1_000_000;
                    (self.sample_rate as i64 + delta).max(1) as u64
                };
                self.nominal_accum += effective_rate;
                let denom = self.packets_per_sec as u64;
                let s = (self.nominal_accum / denom) as usize;
                self.nominal_accum %= denom;
                s
            }
            PacerMode::AsynchronousFeedback => {
                self.feedback_accum_q16 += self.current_rate_q16;
                let s = (self.feedback_accum_q16 >> 16) as usize;
                self.feedback_accum_q16 &= 0xFFFF;
                s
            }
        };

        self.consecutive_packets += 1;
        self.total_samples_generated += samples as u64;
        samples
    }

    /// Updates pacer rate from a 4-byte UAC2 explicit feedback packet (Q16.16 format).
    ///
    /// Returns `true` if the feedback packet was valid and applied.
    pub fn update_feedback_uac2(&mut self, feedback_bytes: &[u8]) -> bool {
        if feedback_bytes.len() < 4 {
            return false;
        }

        let raw_val = u32::from_le_bytes([
            feedback_bytes[0],
            feedback_bytes[1],
            feedback_bytes[2],
            feedback_bytes[3],
        ]);

        self.apply_feedback_rate_q16(raw_val)
    }

    /// Updates pacer rate from a 3-byte UAC1 explicit feedback packet (10.14 format).
    ///
    /// Returns `true` if the feedback packet was valid and applied.
    pub fn update_feedback_uac1(&mut self, feedback_bytes: &[u8]) -> bool {
        if feedback_bytes.len() < 3 {
            return false;
        }

        let raw_10_14 = (feedback_bytes[0] as u32)
            | ((feedback_bytes[1] as u32) << 8)
            | ((feedback_bytes[2] as u32) << 16);

        // Convert 10.14 to 16.16 by shifting left 2 bits
        let val_q16 = raw_10_14 << 2;
        self.apply_feedback_rate_q16(val_q16)
    }

    /// Validates and applies an incoming Q16.16 rate with single-pole IIR smoothing.
    fn apply_feedback_rate_q16(&mut self, rate_q16: u32) -> bool {
        if rate_q16 < self.min_allowed_rate_q16 || rate_q16 > self.max_allowed_rate_q16 {
            return false;
        }

        // 7/8 previous + 1/8 new smoothing filter to prevent packet jitter
        self.current_rate_q16 =
            (((self.current_rate_q16 as u64 * 7) + (rate_q16 as u64)) / 8) as u32;
        true
    }

    /// Adjusts pacing rate in parts-per-million (ppm) for elastic host buffer leveling.
    ///
    /// E.g. `+50` speeds up consumption by 50 ppm; `-50` slows it down.
    pub fn adjust_drift_ppm(&mut self, ppm: i32) {
        self.drift_ppm = ppm;
        let delta = ((self.nominal_rate_q16 as i64 * ppm as i64) / 1_000_000) as i32;
        let adjusted = (self.nominal_rate_q16 as i64 + delta as i64)
            .max(self.min_allowed_rate_q16 as i64)
            .min(self.max_allowed_rate_q16 as i64) as u32;
        self.current_rate_q16 = adjusted;
    }

    /// Resets accumulator and rate back to nominal.
    pub fn reset_to_nominal(&mut self) {
        self.drift_ppm = 0;
        self.current_rate_q16 = self.nominal_rate_q16;
        self.feedback_accum_q16 = 0;
        self.nominal_accum = 0;
    }

    #[inline]
    pub fn nominal_rate_q16(&self) -> u32 {
        self.nominal_rate_q16
    }

    #[inline]
    pub fn current_rate_q16(&self) -> u32 {
        self.current_rate_q16
    }

    #[inline]
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    #[inline]
    pub fn packets_per_sec(&self) -> u32 {
        self.packets_per_sec
    }

    #[inline]
    pub fn total_samples_generated(&self) -> u64 {
        self.total_samples_generated
    }

    #[inline]
    pub fn consecutive_packets(&self) -> u64 {
        self.consecutive_packets
    }

    #[inline]
    pub fn mode(&self) -> PacerMode {
        self.mode
    }
}

/// Manages a ring of heap-allocated, pinned Isochronous URBs.
pub struct IsoRingBuffer<const N: usize> {
    urbs: Vec<Box<IsoUrb<N>>>,
    buffers: Vec<Vec<u8>>,
    max_packet_size: usize,
    in_flight_count: usize,
}

impl<const N: usize> IsoRingBuffer<N> {
    /// Creates a new URB ring buffer with `num_urbs` entries.
    pub fn new(endpoint: u8, max_packet_size: usize, num_urbs: usize) -> Self {
        assert!(num_urbs > 0, "num_urbs must be > 0");
        assert!(max_packet_size > 0, "max_packet_size must be > 0");

        let mut urbs = Vec::with_capacity(num_urbs);
        let mut buffers = Vec::with_capacity(num_urbs);

        for _ in 0..num_urbs {
            let mut buf = vec![0u8; max_packet_size * N];
            let urb = Box::new(IsoUrb::<N>::new(
                endpoint,
                buf.as_mut_ptr(),
                max_packet_size,
            ));
            urbs.push(urb);
            buffers.push(buf);
        }

        Self {
            urbs,
            buffers,
            max_packet_size,
            in_flight_count: 0,
        }
    }

    /// Returns the number of URBs in this ring.
    #[inline]
    pub fn num_urbs(&self) -> usize {
        self.urbs.len()
    }

    /// Returns the number of packets per URB.
    #[inline]
    pub fn packets_per_urb(&self) -> usize {
        N
    }

    /// Returns the number of URBs currently submitted and in-flight.
    #[inline]
    pub fn in_flight_count(&self) -> usize {
        self.in_flight_count
    }

    /// Returns a mutable slice of the buffer for URB `urb_idx`, packet `pkt_idx`.
    pub fn get_packet_slice_mut(
        &mut self,
        urb_idx: usize,
        pkt_idx: usize,
        length: usize,
    ) -> &mut [u8] {
        assert!(urb_idx < self.urbs.len());
        assert!(pkt_idx < N);
        assert!(length <= self.max_packet_size);

        let offset = pkt_idx * self.max_packet_size;
        &mut self.buffers[urb_idx][offset..offset + length]
    }

    /// Sets the length and zero status for packet `pkt_idx` in URB `urb_idx`.
    pub fn set_packet_desc(&mut self, urb_idx: usize, pkt_idx: usize, length: usize) {
        assert!(urb_idx < self.urbs.len());
        assert!(pkt_idx < N);

        self.urbs[urb_idx].iso_frame_desc[pkt_idx].length = length as u32;
        self.urbs[urb_idx].iso_frame_desc[pkt_idx].actual_length = 0;
        self.urbs[urb_idx].iso_frame_desc[pkt_idx].status = 0;
    }

    /// Prepares total buffer length for submission.
    pub fn finalize_urb_for_submission(&mut self, urb_idx: usize, total_length: usize) {
        assert!(urb_idx < self.urbs.len());
        self.urbs[urb_idx].urb.buffer_length = total_length as i32;
        self.urbs[urb_idx].urb.actual_length = 0;
        self.urbs[urb_idx].urb.status = 0;
        self.urbs[urb_idx].urb.error_count = 0;
    }

    /// Submits URB `urb_idx` to the kernel.
    pub fn submit_urb(
        &mut self,
        handle: &UsbDeviceHandle,
        urb_idx: usize,
    ) -> Result<(), UsbFsError> {
        assert!(urb_idx < self.urbs.len());
        let urb_ptr = self.urbs[urb_idx].as_urb_ptr();
        unsafe {
            handle.submit_urb(urb_ptr)?;
        }
        self.in_flight_count += 1;
        Ok(())
    }

    /// Matches a reaped `UsbdevfsUrb` pointer back to its ring index.
    pub fn find_urb_index(&self, reaped_ptr: *mut UsbdevfsUrb) -> Option<usize> {
        self.urbs
            .iter()
            .position(|urb| std::ptr::eq(&urb.urb, reaped_ptr))
    }

    /// Decrements in-flight count upon reaping an URB.
    pub fn mark_reaped(&mut self) {
        self.in_flight_count = self.in_flight_count.saturating_sub(1);
    }

    /// Discards all currently in-flight URBs.
    pub fn discard_all(&mut self, handle: &UsbDeviceHandle) {
        for urb in &mut self.urbs {
            let ptr = urb.as_urb_ptr();
            let _ = unsafe { handle.discard_urb(ptr) };
        }
    }

    /// Reaps all remaining discarded URBs until the queue is completely drained.
    pub fn drain_reap(&mut self, handle: &UsbDeviceHandle, timeout_ms: u32) {
        while self.in_flight_count > 0 {
            match handle.reap_urb(Some(timeout_ms)) {
                Ok(ptr) => {
                    if self.find_urb_index(ptr).is_some() {
                        self.mark_reaped();
                    }
                }
                Err(_) => break, // Timeout or error, stop draining
            }
        }
    }
}

/// Abstract audio rendering provider supplying interleaved `f32` samples.
pub trait AudioSampleSource: Send {
    /// Renders `frames` audio frames (each with `channels` interleaved samples) into `out_slice`.
    ///
    /// Returns `true` if playback should continue, or `false` to end stream.
    fn render_audio_frames(&mut self, out_slice: &mut [f32], channels: usize) -> bool;
}

/// Functional audio source wrapper for closures.
pub struct CallbackAudioSource<F: FnMut(&mut [f32], usize) -> bool + Send>(pub F);

impl<F: FnMut(&mut [f32], usize) -> bool + Send> AudioSampleSource for CallbackAudioSource<F> {
    fn render_audio_frames(&mut self, out_slice: &mut [f32], channels: usize) -> bool {
        (self.0)(out_slice, channels)
    }
}

/// Configuration parameters for an isochronous streaming session.
#[derive(Debug, Clone)]
pub struct UsbStreamConfig {
    pub data_endpoint: EndpointInfo,
    pub feedback_endpoint: Option<EndpointInfo>,
    pub sample_rate: u32,
    pub channels: u8,
    pub format: PcmFormat,
    pub pacer_mode: PacerMode,
    pub is_high_speed: bool,
    pub num_urbs: usize,
}

/// Handle to an active USB isochronous audio stream worker thread.
pub struct UsbStreamHandle {
    is_running: Arc<AtomicBool>,
    frames_played: Arc<AtomicU64>,
    underruns: Arc<AtomicU32>,
    worker_handle: Option<JoinHandle<Result<(), UsbFsError>>>,
}

impl UsbStreamHandle {
    /// Signals the worker thread to stop and waits for it to join.
    pub fn stop(&mut self) -> Result<(), UsbFsError> {
        self.is_running.store(false, Ordering::Release);
        if let Some(handle) = self.worker_handle.take() {
            match handle.join() {
                Ok(res) => res,
                Err(_) => Err(UsbFsError::Io(std::io::Error::other(
                    "USB streaming worker thread panicked",
                ))),
            }
        } else {
            Ok(())
        }
    }

    #[inline]
    pub fn is_running(&self) -> bool {
        self.is_running.load(Ordering::Acquire)
    }

    #[inline]
    pub fn frames_played(&self) -> u64 {
        self.frames_played.load(Ordering::Relaxed)
    }

    #[inline]
    pub fn underruns(&self) -> u32 {
        self.underruns.load(Ordering::Relaxed)
    }
}

/// High-level Isochronous Streaming Engine.
pub struct UsbStreamingEngine;

impl UsbStreamingEngine {
    /// Launches an isochronous audio streaming session on a background real-time thread.
    pub fn start_stream<S: AudioSampleSource + 'static>(
        handle: Arc<UsbDeviceHandle>,
        config: UsbStreamConfig,
        mut source: S,
    ) -> Result<UsbStreamHandle, UsbFsError> {
        let is_running = Arc::new(AtomicBool::new(true));
        let frames_played = Arc::new(AtomicU64::new(0));
        let underruns = Arc::new(AtomicU32::new(0));

        let thread_running = Arc::clone(&is_running);
        let thread_frames = Arc::clone(&frames_played);
        let thread_underruns = Arc::clone(&underruns);

        let builder = std::thread::Builder::new().name("bitdrop-usb-stream".into());

        let worker_handle = builder
            .spawn(move || -> Result<(), UsbFsError> {
                let mut pacer = AudioPacer::from_endpoint(
                    config.pacer_mode,
                    config.sample_rate,
                    &config.data_endpoint,
                    config.is_high_speed,
                );

                let max_packet_size = config.data_endpoint.max_packet_size as usize;
                let num_urbs = config.num_urbs.max(2);
                let channels = config.channels as usize;
                let bytes_per_frame = config.format.bytes_per_frame(channels);

                let mut ring = IsoRingBuffer::<DEFAULT_PACKETS_PER_URB>::new(
                    config.data_endpoint.address,
                    max_packet_size,
                    num_urbs,
                );

                // Scratch f32 render buffer sized for maximum packet sample capacity
                let max_frames_per_packet = max_packet_size / bytes_per_frame;
                let mut f32_scratch = vec![0.0f32; max_frames_per_packet * channels];
                let mut pcm_scratch = vec![0u8; max_packet_size];

                // 1. Initial pre-roll: fill and submit all URBs in the ring
                for urb_idx in 0..num_urbs {
                    let mut total_urb_bytes = 0;
                    for pkt_idx in 0..DEFAULT_PACKETS_PER_URB {
                        let samples = pacer.next_packet_samples();
                        let frame_samples = samples * channels;
                        let packet_bytes = samples * bytes_per_frame;

                        let active_slice = &mut f32_scratch[..frame_samples];
                        let ok = source.render_audio_frames(active_slice, channels);
                        if !ok {
                            thread_running.store(false, Ordering::Release);
                        }

                        config
                            .format
                            .format_interleaved_f32(active_slice, &mut pcm_scratch[..packet_bytes]);

                        let pkt_slice = ring.get_packet_slice_mut(urb_idx, pkt_idx, packet_bytes);
                        pkt_slice.copy_from_slice(&pcm_scratch[..packet_bytes]);
                        ring.set_packet_desc(urb_idx, pkt_idx, packet_bytes);

                        total_urb_bytes += packet_bytes;
                        thread_frames.fetch_add(samples as u64, Ordering::Relaxed);
                    }

                    ring.finalize_urb_for_submission(urb_idx, total_urb_bytes);
                    ring.submit_urb(&handle, urb_idx)?;
                }

                // 2. Real-time streaming loop
                while thread_running.load(Ordering::Acquire) {
                    // Poll with 100ms timeout so we don't block indefinitely on disconnect
                    let reaped_ptr = match handle.reap_urb(Some(100)) {
                        Ok(ptr) => ptr,
                        Err(UsbFsError::TimedOut) => {
                            thread_underruns.fetch_add(1, Ordering::Relaxed);
                            continue;
                        }
                        Err(err) => {
                            // Device disconnected or fatal error
                            ring.discard_all(&handle);
                            ring.drain_reap(&handle, 50);
                            return Err(err);
                        }
                    };

                    ring.mark_reaped();

                    let urb_idx = match ring.find_urb_index(reaped_ptr) {
                        Some(idx) => idx,
                        None => continue, // Foreign or unknown URB
                    };

                    let mut total_urb_bytes = 0;
                    for pkt_idx in 0..DEFAULT_PACKETS_PER_URB {
                        let samples = pacer.next_packet_samples();
                        let frame_samples = samples * channels;
                        let packet_bytes = samples * bytes_per_frame;

                        let active_slice = &mut f32_scratch[..frame_samples];
                        let ok = source.render_audio_frames(active_slice, channels);
                        if !ok {
                            thread_running.store(false, Ordering::Release);
                        }

                        config
                            .format
                            .format_interleaved_f32(active_slice, &mut pcm_scratch[..packet_bytes]);

                        let pkt_slice = ring.get_packet_slice_mut(urb_idx, pkt_idx, packet_bytes);
                        pkt_slice.copy_from_slice(&pcm_scratch[..packet_bytes]);
                        ring.set_packet_desc(urb_idx, pkt_idx, packet_bytes);

                        total_urb_bytes += packet_bytes;
                        thread_frames.fetch_add(samples as u64, Ordering::Relaxed);
                    }

                    ring.finalize_urb_for_submission(urb_idx, total_urb_bytes);
                    if let Err(err) = ring.submit_urb(&handle, urb_idx) {
                        ring.discard_all(&handle);
                        ring.drain_reap(&handle, 50);
                        return Err(err);
                    }
                }

                // 3. Clean teardown: discard and drain all in-flight URBs
                ring.discard_all(&handle);
                ring.drain_reap(&handle, 50);
                Ok(())
            })
            .map_err(UsbFsError::Io)?;

        Ok(UsbStreamHandle {
            is_running,
            frames_played,
            underruns,
            worker_handle: Some(worker_handle),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::usb_dac::descriptors::{EndpointDirection, EndpointSyncType, EndpointUsageType};

    #[test]
    fn test_pcm_format_properties_and_resolutions() {
        assert_eq!(PcmFormat::S16Le.bytes_per_sample(), 2);
        assert_eq!(PcmFormat::S16Le.bytes_per_frame(2), 4);

        assert_eq!(PcmFormat::S24_3Le.bytes_per_sample(), 3);
        assert_eq!(PcmFormat::S24_3Le.bytes_per_frame(2), 6);

        assert_eq!(PcmFormat::S24_4Le.bytes_per_sample(), 4);
        assert_eq!(PcmFormat::S24_4Le.bytes_per_frame(2), 8);

        assert_eq!(PcmFormat::S32Le.bytes_per_sample(), 4);
        assert_eq!(PcmFormat::S32Le.bytes_per_frame(2), 8);
    }

    #[test]
    fn test_pcm_format_conversion_s16le() {
        let input = [0.0f32, 1.0f32, -1.0f32, 0.5f32];
        let mut out = [0u8; 8];
        let written = PcmFormat::S16Le.format_interleaved_f32(&input, &mut out);
        assert_eq!(written, 8);

        // 0.0 -> 0
        assert_eq!(i16::from_le_bytes([out[0], out[1]]), 0);
        // 1.0 -> 32767
        assert_eq!(i16::from_le_bytes([out[2], out[3]]), 32767);
        // -1.0 -> -32767
        assert_eq!(i16::from_le_bytes([out[4], out[5]]), -32767);
        // 0.5 -> 16384 (or 16383.5 rounded)
        assert_eq!(i16::from_le_bytes([out[6], out[7]]), 16384);
    }

    #[test]
    fn test_pcm_format_conversion_s24_3le() {
        let input = [1.0f32, -1.0f32];
        let mut out = [0u8; 6];
        let written = PcmFormat::S24_3Le.format_interleaved_f32(&input, &mut out);
        assert_eq!(written, 6);

        // Max 24-bit positive: 0x7FFFFF (8388607)
        assert_eq!(out[0], 0xFF);
        assert_eq!(out[1], 0xFF);
        assert_eq!(out[2], 0x7F);

        // Negative 24-bit: -8388607 in 2's complement
        let neg = (-8388607i32).to_le_bytes();
        assert_eq!(out[3], neg[0]);
        assert_eq!(out[4], neg[1]);
        assert_eq!(out[5], neg[2]);
    }

    #[test]
    fn test_pcm_format_conversion_s24_4le() {
        let input = [1.0f32];
        let mut out = [0u8; 4];
        let written = PcmFormat::S24_4Le.format_interleaved_f32(&input, &mut out);
        assert_eq!(written, 4);

        // High 24 bits: 0x7FFFFF00
        assert_eq!(out[0], 0x00); // padding byte
        assert_eq!(out[1], 0xFF);
        assert_eq!(out[2], 0xFF);
        assert_eq!(out[3], 0x7F);
    }

    #[test]
    fn test_pcm_format_conversion_s32le() {
        let input = [1.0f32, -1.0f32];
        let mut out = [0u8; 8];
        let written = PcmFormat::S32Le.format_interleaved_f32(&input, &mut out);
        assert_eq!(written, 8);

        assert_eq!(
            i32::from_le_bytes(out[0..4].try_into().unwrap()),
            2147483647
        );
        assert_eq!(
            i32::from_le_bytes(out[4..8].try_into().unwrap()),
            -2147483647
        );
    }

    #[test]
    fn test_pacer_high_speed_48k_exact() {
        // 48000 Hz at 8000 packets/s -> exactly 6.0 frames per packet
        let mut pacer = AudioPacer::new(PacerMode::AdaptiveNominal, 48000, 8000);
        assert_eq!(pacer.nominal_rate_q16(), 6 * 65536);

        for _ in 0..100 {
            assert_eq!(pacer.next_packet_samples(), 6);
        }
        assert_eq!(pacer.total_samples_generated(), 600);
    }

    #[test]
    fn test_pacer_high_speed_44_1k_fractional_accumulator() {
        // 44100 Hz at 8000 packets/s -> 5.5125 frames per packet
        let mut pacer = AudioPacer::new(PacerMode::AdaptiveNominal, 44100, 8000);

        let mut total_samples = 0;
        let mut counts = [0usize; 7]; // tracks 5 vs 6 distribution

        for _ in 0..8000 {
            let s = pacer.next_packet_samples();
            assert!(s == 5 || s == 6);
            counts[s] += 1;
            total_samples += s;
        }

        // Across exactly 8000 microframes, sum must be 44100 frames!
        assert_eq!(total_samples, 44100);
        // 5 * 3900 + 6 * 4100 = 19500 + 24600 = 44100
        assert_eq!(counts[5], 3900);
        assert_eq!(counts[6], 4100);
    }

    #[test]
    fn test_pacer_high_speed_96k_and_192k() {
        let mut pacer_96k = AudioPacer::new(PacerMode::AdaptiveNominal, 96000, 8000);
        for _ in 0..100 {
            assert_eq!(pacer_96k.next_packet_samples(), 12);
        }

        let mut pacer_192k = AudioPacer::new(PacerMode::AdaptiveNominal, 192000, 8000);
        for _ in 0..100 {
            assert_eq!(pacer_192k.next_packet_samples(), 24);
        }
    }

    #[test]
    fn test_pacer_full_speed_44_1k_distribution() {
        // Full Speed: 44100 Hz at 1000 packets/s -> 44.1 frames per packet
        let mut pacer = AudioPacer::new(PacerMode::AdaptiveNominal, 44100, 1000);

        let mut total = 0;
        for _ in 0..1000 {
            let s = pacer.next_packet_samples();
            assert!(s == 44 || s == 45);
            total += s;
        }
        assert_eq!(total, 44100);
    }

    #[test]
    fn test_pacer_uac2_feedback_filter() {
        let mut pacer = AudioPacer::new(PacerMode::AsynchronousFeedback, 48000, 8000);
        let nominal_q16 = pacer.nominal_rate_q16();

        // Simulate DAC running slightly fast: 6.001 frames/pkt = 6.001 * 65536 = 393282
        let fb_fast = 393282u32.to_le_bytes();
        let ok = pacer.update_feedback_uac2(&fb_fast);
        assert!(ok);
        // Filtered rate should be nudged upwards towards 393282
        assert!(pacer.current_rate_q16() > nominal_q16);

        // Corrupted feedback out-of-bounds (> 120% nominal) must be rejected
        let fb_corrupt = (nominal_q16 * 2).to_le_bytes();
        assert!(!pacer.update_feedback_uac2(&fb_corrupt));
    }

    #[test]
    fn test_pacer_uac1_feedback_10_14() {
        // 44.1k at 1000 pkt/s: nominal = 44.1 = 44 + 0.1
        // In 10.14: 44.1 * 16384 = 722534
        let mut pacer = AudioPacer::new(PacerMode::AsynchronousFeedback, 44100, 1000);
        let raw_val = 722534u32;
        let bytes = [
            (raw_val & 0xFF) as u8,
            ((raw_val >> 8) & 0xFF) as u8,
            ((raw_val >> 16) & 0xFF) as u8,
        ];
        assert!(pacer.update_feedback_uac1(&bytes));
    }

    #[test]
    fn test_pacer_drift_ppm_adjustment() {
        let mut pacer = AudioPacer::new(PacerMode::AdaptiveNominal, 48000, 8000);
        let nominal = pacer.nominal_rate_q16();

        // +100 ppm adjustment
        pacer.adjust_drift_ppm(100);
        assert!(pacer.current_rate_q16() > nominal);

        // -100 ppm adjustment
        pacer.adjust_drift_ppm(-100);
        assert!(pacer.current_rate_q16() < nominal);

        pacer.reset_to_nominal();
        assert_eq!(pacer.current_rate_q16(), nominal);
    }

    #[test]
    fn test_iso_ring_buffer_structure_and_packet_slices() {
        let mut ring = IsoRingBuffer::<DEFAULT_PACKETS_PER_URB>::new(0x01, 192, 4);
        assert_eq!(ring.num_urbs(), 4);
        assert_eq!(ring.packets_per_urb(), DEFAULT_PACKETS_PER_URB);
        assert_eq!(ring.in_flight_count(), 0);

        // Write to packet slice
        let slice = ring.get_packet_slice_mut(0, 0, 48);
        slice[0] = 0xAA;
        slice[47] = 0xBB;
        ring.set_packet_desc(0, 0, 48);

        // Verify descriptor updated
        assert_eq!(ring.urbs[0].iso_frame_desc[0].length, 48);
        assert_eq!(ring.urbs[0].iso_frame_desc[0].status, 0);

        let slice_verify = ring.get_packet_slice_mut(0, 0, 48);
        assert_eq!(slice_verify[0], 0xAA);
        assert_eq!(slice_verify[47], 0xBB);
    }

    #[test]
    fn test_auto_detect_pacer_mode() {
        let async_ep = EndpointInfo {
            address: 0x01,
            direction: EndpointDirection::Out,
            sync_type: EndpointSyncType::Asynchronous,
            usage_type: EndpointUsageType::Data,
            max_packet_size: 512,
            interval: 1,
            refresh: 0,
            synch_address: 0x82,
        };

        let feedback_ep = EndpointInfo {
            address: 0x82,
            direction: EndpointDirection::In,
            sync_type: EndpointSyncType::NoSync,
            usage_type: EndpointUsageType::Feedback,
            max_packet_size: 4,
            interval: 4,
            refresh: 0,
            synch_address: 0,
        };

        let mode_async = AudioPacer::auto_detect_mode(&async_ep, &Some(feedback_ep));
        assert_eq!(mode_async, PacerMode::AsynchronousFeedback);

        // Adaptive endpoint without feedback (DUNU Titan X style)
        let adaptive_ep = EndpointInfo {
            address: 0x01,
            direction: EndpointDirection::Out,
            sync_type: EndpointSyncType::Adaptive,
            usage_type: EndpointUsageType::Data,
            max_packet_size: 512,
            interval: 1,
            refresh: 0,
            synch_address: 0,
        };
        let mode_adaptive = AudioPacer::auto_detect_mode(&adaptive_ep, &None);
        assert_eq!(mode_adaptive, PacerMode::AdaptiveNominal);
    }
}

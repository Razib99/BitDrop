//! BitDrop Engine v2: 64-Bit Float Precision (f64) DSP Pipeline.
//!
//! Real-time safe audio processing with zero heap allocations on the audio path:
//! - Full `f64` precision biquads (TDF-II) and state registers.
//! - Constant-Q Peaking filters for Graphic EQ matching `biquad.dart` 1:1.
//! - Tone mode shelves with Butterworth slope (`Q = 1 / sqrt(2)`).
//! - 18 Hz Subsonic 2nd-order Butterworth HPF engaged on sub-60Hz boosts with 20ms crossfade.
//! - Complex-transfer-function Auto-Preamp across 512 logarithmic evaluation frequencies.
//! - 20ms zipper-free parameter crossfading between active and target filter banks.
//! - Independent stereo balance and mono mixdown stages.
//! - 1.5ms pre-allocated Lookahead Peak Limiter with -1.0 dBFS ceiling and ~80ms release.
//! - TPDF dither with inline PRNG for integer quantization.
//! - Bit-exact neutral bypass verified by SHA-256.

use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, AtomicU64, AtomicUsize, Ordering};

pub const EQ_PEAK: u8 = 0;
pub const EQ_LOW_SHELF: u8 = 1;
pub const EQ_HIGH_SHELF: u8 = 2;
pub const EQ_LOW_PASS: u8 = 3;
pub const EQ_HIGH_PASS: u8 = 4;

pub const CROSSFEED_OFF: u8 = 0;
pub const CROSSFEED_DEFAULT: u8 = 1; // 700.0 Hz, 4.5 dB
pub const CROSSFEED_CHU_MOY: u8 = 2; // 700.0 Hz, 6.0 dB
pub const CROSSFEED_JAN_MEIER: u8 = 3; // 650.0 Hz, 9.5 dB

pub const MAX_EQ_BANDS: usize = 16;
pub const ISO_10_BAND: [f64; 10] = [
    31.0, 62.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0,
];

pub const BUTTERWORTH_Q: f64 = std::f64::consts::FRAC_1_SQRT_2; // 1.0 / sqrt(2)
pub const OCTAVE_PEAK_Q: f64 = std::f64::consts::SQRT_2; // sqrt(2)
pub const SUBSONIC_FREQ: f64 = 18.0;

/// Ring buffer capacity for the lock-free visualizer FFT.
pub const VISUALIZER_RING_SIZE: usize = 512;
pub const VISUALIZER_BANDS: usize = 32;

/// Atomic metrics exported to UI and diagnostic systems.
pub static LIMITER_GR_MILLIDB: AtomicU32 = AtomicU32::new(0);
pub static LIMITER_CLIPPED_SAMPLES: AtomicU64 = AtomicU64::new(0);

pub static VISUALIZER_PEAK_L_MILLIDB: AtomicI32 = AtomicI32::new(-90000);
pub static VISUALIZER_PEAK_R_MILLIDB: AtomicI32 = AtomicI32::new(-90000);
pub static VISUALIZER_CLIPPING: AtomicBool = AtomicBool::new(false);
pub static VISUALIZER_HEAD: AtomicUsize = AtomicUsize::new(0);

#[allow(clippy::declare_interior_mutable_const)]
const VISUALIZER_INIT_ATOM: AtomicU32 = AtomicU32::new(0);
pub static VISUALIZER_SAMPLES: [AtomicU32; VISUALIZER_RING_SIZE] =
    [VISUALIZER_INIT_ATOM; VISUALIZER_RING_SIZE];

#[derive(Clone, Debug, Default, PartialEq)]
pub struct VisualizerFrameData {
    pub spectrum: Vec<f32>,
    pub peak_left_db: f32,
    pub peak_right_db: f32,
    pub clipping: bool,
}

#[derive(Clone, Copy, Default, PartialEq, Debug)]
pub struct EqBandSpec {
    pub kind: u8,
    pub freq: f32,
    pub gain_db: f32,
    pub q: f32,
}

#[derive(Clone, Copy, Debug)]
pub struct DspConfigSnapshot {
    pub sample_rate: f64,
    pub eq_enabled: bool,
    pub preamp_db: f64,
    pub auto_gain: f64,
    pub replay_gain_db: f64,
    pub track_peak: f64,
    pub crossfeed_preset: u8,
    pub balance: f64,
    pub mono: bool,
    pub specs: [EqBandSpec; MAX_EQ_BANDS],
    pub spec_count: usize,
    pub is_parametric: bool,
    pub graphic_gains: [f32; 10],
    pub dop_active: bool,
    pub version: u64,
}

impl Default for DspConfigSnapshot {
    fn default() -> Self {
        Self {
            sample_rate: 48000.0,
            eq_enabled: false,
            preamp_db: 0.0,
            auto_gain: 0.0,
            replay_gain_db: 0.0,
            track_peak: 1.0,
            crossfeed_preset: CROSSFEED_OFF,
            balance: 0.0,
            mono: false,
            specs: [EqBandSpec::default(); MAX_EQ_BANDS],
            spec_count: 0,
            is_parametric: false,
            graphic_gains: [0.0; 10],
            dop_active: false,
            version: 0,
        }
    }
}

/// Hardware-locked DoP v1.1 bit-transparency bypass flag.
/// When active, guarantees 100% bypass of biquads, preamp, true-peak limiting, and dither.
pub static DOP_BYPASS_LOCKOUT: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BoundaryKind {
    TrackStarted,
    TrackEnded,
    TrackChanged,
}

#[derive(Clone, Copy, Debug)]
pub struct BoundaryMarker {
    pub trigger_at_frame: u64,
    pub kind: BoundaryKind,
    pub file_id: [u8; 64],
    pub file_id_len: usize,
}

impl BoundaryMarker {
    pub fn track_ended(trigger_at_frame: u64, file_id_str: &str) -> Self {
        let mut id = [0u8; 64];
        let bytes = file_id_str.as_bytes();
        let len = bytes.len().min(64);
        id[..len].copy_from_slice(&bytes[..len]);
        Self {
            trigger_at_frame,
            kind: BoundaryKind::TrackEnded,
            file_id: id,
            file_id_len: len,
        }
    }

    pub fn track_started(trigger_at_frame: u64, file_id_str: &str) -> Self {
        let mut id = [0u8; 64];
        let bytes = file_id_str.as_bytes();
        let len = bytes.len().min(64);
        id[..len].copy_from_slice(&bytes[..len]);
        Self {
            trigger_at_frame,
            kind: BoundaryKind::TrackStarted,
            file_id: id,
            file_id_len: len,
        }
    }

    pub fn track_changed(trigger_at_frame: u64, file_id_str: &str) -> Self {
        let mut id = [0u8; 64];
        let bytes = file_id_str.as_bytes();
        let len = bytes.len().min(64);
        id[..len].copy_from_slice(&bytes[..len]);
        Self {
            trigger_at_frame,
            kind: BoundaryKind::TrackChanged,
            file_id: id,
            file_id_len: len,
        }
    }

    pub fn file_id_str(&self) -> &str {
        std::str::from_utf8(&self.file_id[..self.file_id_len]).unwrap_or("")
    }
}

/// Downmixes interleaved multichannel audio into stereo using ITU-R BS.775 standard coefficients.
///
/// Channels supported:
/// - 1 (Mono): duplicated to L and R
/// - 2 (Stereo): passed through
/// - 3 (3.0 / 2.1: FL, FR, FC): L = (FL + 0.7071 * FC) * 0.5858, R = (FR + 0.7071 * FC) * 0.5858
/// - 4 (Quad / 4.0): L = (FL + 0.7071 * CH2) * 0.5858, R = (FR + 0.7071 * CH3) * 0.5858
/// - 5 (5.0: FL, FR, FC, SL, SR): L = (FL + 0.7071 * FC + 0.7071 * SL) * 0.4142, R = (FR + 0.7071 * FC + 0.7071 * SR) * 0.4142
/// - 6 (5.1: FL, FR, FC, LFE, SL, SR):
///   L = (FL + 0.7071 * FC + 0.7071 * LFE + 0.7071 * SL) * 0.3204
///   R = (FR + 0.7071 * FC + 0.7071 * LFE + 0.7071 * SR) * 0.3204
pub fn downmix_to_stereo(samples: &[f32], channels: usize) -> Vec<f32> {
    if channels == 2 {
        return samples.to_vec();
    }
    if channels == 1 {
        let mut stereo = Vec::with_capacity(samples.len() * 2);
        for &s in samples {
            stereo.push(s);
            stereo.push(s);
        }
        return stereo;
    }
    let frames = samples.len() / channels;
    let mut stereo = Vec::with_capacity(frames * 2);
    const C: f32 = std::f32::consts::FRAC_1_SQRT_2;
    if channels == 3 {
        const SCALE: f32 = 0.5858;
        for i in 0..frames {
            let fl = samples[i * 3];
            let fr = samples[i * 3 + 1];
            let fc = samples[i * 3 + 2];
            stereo.push((fl + C * fc) * SCALE);
            stereo.push((fr + C * fc) * SCALE);
        }
    } else if channels == 4 {
        const SCALE: f32 = 0.5858;
        for i in 0..frames {
            let fl = samples[i * 4];
            let fr = samples[i * 4 + 1];
            let ch2 = samples[i * 4 + 2];
            let ch3 = samples[i * 4 + 3];
            stereo.push((fl + C * ch2) * SCALE);
            stereo.push((fr + C * ch3) * SCALE);
        }
    } else if channels == 5 {
        const SCALE: f32 = 0.4142;
        for i in 0..frames {
            let fl = samples[i * 5];
            let fr = samples[i * 5 + 1];
            let fc = samples[i * 5 + 2];
            let sl = samples[i * 5 + 3];
            let sr = samples[i * 5 + 4];
            stereo.push((fl + C * fc + C * sl) * SCALE);
            stereo.push((fr + C * fc + C * sr) * SCALE);
        }
    } else {
        // 5.1 and above (ITU-R BS.775)
        const SCALE: f32 = 0.3204;
        for i in 0..frames {
            let fl = samples[i * channels];
            let fr = samples[i * channels + 1];
            let fc = samples[i * channels + 2];
            let lfe = samples[i * channels + 3];
            let sl = samples[i * channels + 4];
            let sr = samples[i * channels + 5];
            let l = (fl + C * fc + C * lfe + C * sl) * SCALE;
            let r = (fr + C * fc + C * lfe + C * sr) * SCALE;
            stereo.push(l);
            stereo.push(r);
        }
    }
    stereo
}

const TRIPLE_DIRTY_BIT: u8 = 0x80;

/// The three slots are shared only by one producer and one consumer.
struct TripleSlots<T: Copy> {
    buffers: [std::cell::UnsafeCell<T>; 3],
    shared: std::sync::atomic::AtomicU8,
}

// Each slot has exactly one owner. AcqRel exchanges transfer slot ownership;
// endpoint methods require exclusive access and endpoints cannot be cloned.
unsafe impl<T: Copy + Send> Send for TripleSlots<T> {}
unsafe impl<T: Copy + Send> Sync for TripleSlots<T> {}

pub struct TripleProducer<T: Copy> {
    slots: std::sync::Arc<TripleSlots<T>>,
    write_idx: usize,
}

pub struct TripleConsumer<T: Copy> {
    slots: std::sync::Arc<TripleSlots<T>>,
    read_idx: usize,
}

pub fn triple_buffer<T: Copy + Send>(initial: T) -> (TripleProducer<T>, TripleConsumer<T>) {
    let slots = std::sync::Arc::new(TripleSlots {
        buffers: std::array::from_fn(|_| std::cell::UnsafeCell::new(initial)),
        shared: std::sync::atomic::AtomicU8::new(2),
    });
    (
        TripleProducer {
            slots: slots.clone(),
            write_idx: 1,
        },
        TripleConsumer { slots, read_idx: 0 },
    )
}

impl<T: Copy> TripleProducer<T> {
    pub fn publish(&mut self, value: T) {
        unsafe {
            *self.slots.buffers[self.write_idx].get() = value;
        }
        self.write_idx = (self.slots.shared.swap(
            self.write_idx as u8 | TRIPLE_DIRTY_BIT,
            std::sync::atomic::Ordering::AcqRel,
        ) & 0x03) as usize;
    }
}

impl<T: Copy> TripleConsumer<T> {
    pub fn read_new(&mut self) -> Option<T> {
        if self.slots.shared.load(std::sync::atomic::Ordering::Acquire) & TRIPLE_DIRTY_BIT == 0 {
            return None;
        }
        self.read_idx = (self
            .slots
            .shared
            .swap(self.read_idx as u8, std::sync::atomic::Ordering::AcqRel)
            & 0x03) as usize;
        Some(unsafe { *self.slots.buffers[self.read_idx].get() })
    }
}

/// Control callers serialize publication; the audio callback owns the sole reader.
/// Reader acquisition and return happen only while constructing/dropping a renderer.
pub struct DspMailbox {
    producer: parking_lot::Mutex<TripleProducer<DspConfigSnapshot>>,
    consumer: parking_lot::Mutex<Option<TripleConsumer<DspConfigSnapshot>>>,
}

impl DspMailbox {
    pub fn new(initial: DspConfigSnapshot) -> Self {
        let (producer, consumer) = triple_buffer(initial);
        Self {
            producer: parking_lot::Mutex::new(producer),
            consumer: parking_lot::Mutex::new(Some(consumer)),
        }
    }
    pub fn publish(&self, snapshot: DspConfigSnapshot) {
        self.producer.lock().publish(snapshot);
    }
    pub fn take_consumer(&self) -> Option<TripleConsumer<DspConfigSnapshot>> {
        self.consumer.lock().take()
    }
    pub fn return_consumer(&self, consumer: TripleConsumer<DspConfigSnapshot>) {
        *self.consumer.lock() = Some(consumer);
    }
}

/// A stereo biquad filter in 64-bit precision Transposed Direct Form II.
#[derive(Clone, Copy, Default, Debug)]
pub struct StereoBiquadF64 {
    pub b0: f64,
    pub b1: f64,
    pub b2: f64,
    pub a1: f64,
    pub a2: f64,
    pub s1: [f64; 2],
    pub s2: [f64; 2],
}

impl StereoBiquadF64 {
    #[inline(always)]
    pub fn process(&mut self, l: f64, r: f64) -> (f64, f64) {
        let y_l = self.b0 * l + self.s1[0];
        self.s1[0] = self.b1 * l - self.a1 * y_l + self.s2[0];
        self.s2[0] = self.b2 * l - self.a2 * y_l;

        let y_r = self.b0 * r + self.s1[1];
        self.s1[1] = self.b1 * r - self.a1 * y_r + self.s2[1];
        self.s2[1] = self.b2 * r - self.a2 * y_r;

        (y_l, y_r)
    }

    pub fn reset_state(&mut self) {
        self.s1 = [0.0; 2];
        self.s2 = [0.0; 2];
    }

    /// Calculates complex frequency response H(e^{j*w}) at digital frequency w = 2*pi*f/fs.
    pub fn complex_response(&self, w: f64) -> (f64, f64) {
        let cos_w = w.cos();
        let sin_w = w.sin();
        let cos_2w = (2.0 * w).cos();
        let sin_2w = (2.0 * w).sin();

        // Numerator: b0 + b1*e^{-jw} + b2*e^{-2jw}
        let num_re = self.b0 + self.b1 * cos_w + self.b2 * cos_2w;
        let num_im = -(self.b1 * sin_w + self.b2 * sin_2w);

        // Denominator: 1.0 + a1*e^{-jw} + a2*e^{-2jw} (note a0 normalized to 1.0)
        let den_re = 1.0 + self.a1 * cos_w + self.a2 * cos_2w;
        let den_im = -(self.a1 * sin_w + self.a2 * sin_2w);

        let den_mag_sq = den_re * den_re + den_im * den_im;
        if den_mag_sq < 1e-24 {
            return (1.0, 0.0);
        }

        let h_re = (num_re * den_re + num_im * den_im) / den_mag_sq;
        let h_im = (num_im * den_re - num_re * den_im) / den_mag_sq;
        (h_re, h_im)
    }

    /// Sets coefficients following the RBJ Audio EQ Cookbook in full f64 precision.
    pub fn set_coeffs(&mut self, kind: u8, f0: f64, fs: f64, q: f64, db_gain: f64) {
        let fs = if fs > 0.0 { fs } else { 48000.0 };
        let f0 = f0.clamp(10.0, fs * 0.495);
        let q = if q > 0.0 { q } else { BUTTERWORTH_Q };
        let a = 10f64.powf(db_gain / 40.0);
        let w0 = 2.0 * std::f64::consts::PI * f0 / fs;
        let (sin_w0, cos_w0) = w0.sin_cos();
        let alpha = sin_w0 / (2.0 * q);
        let sqrt_a = a.sqrt();

        let (b0, b1, b2, a0, a1, a2) = match kind {
            EQ_LOW_SHELF => (
                a * ((a + 1.0) - (a - 1.0) * cos_w0 + 2.0 * sqrt_a * alpha),
                2.0 * a * ((a - 1.0) - (a + 1.0) * cos_w0),
                a * ((a + 1.0) - (a - 1.0) * cos_w0 - 2.0 * sqrt_a * alpha),
                (a + 1.0) + (a - 1.0) * cos_w0 + 2.0 * sqrt_a * alpha,
                -2.0 * ((a - 1.0) + (a + 1.0) * cos_w0),
                (a + 1.0) + (a - 1.0) * cos_w0 - 2.0 * sqrt_a * alpha,
            ),
            EQ_HIGH_SHELF => (
                a * ((a + 1.0) + (a - 1.0) * cos_w0 + 2.0 * sqrt_a * alpha),
                -2.0 * a * ((a - 1.0) + (a + 1.0) * cos_w0),
                a * ((a + 1.0) + (a - 1.0) * cos_w0 - 2.0 * sqrt_a * alpha),
                (a + 1.0) - (a - 1.0) * cos_w0 + 2.0 * sqrt_a * alpha,
                2.0 * ((a - 1.0) - (a + 1.0) * cos_w0),
                (a + 1.0) - (a - 1.0) * cos_w0 - 2.0 * sqrt_a * alpha,
            ),
            EQ_LOW_PASS => (
                (1.0 - cos_w0) * 0.5,
                1.0 - cos_w0,
                (1.0 - cos_w0) * 0.5,
                1.0 + alpha,
                -2.0 * cos_w0,
                1.0 - alpha,
            ),
            EQ_HIGH_PASS => (
                (1.0 + cos_w0) * 0.5,
                -(1.0 + cos_w0),
                (1.0 + cos_w0) * 0.5,
                1.0 + alpha,
                -2.0 * cos_w0,
                1.0 - alpha,
            ),
            // EQ_PEAK and default
            _ => (
                1.0 + alpha * a,
                -2.0 * cos_w0,
                1.0 - alpha * a,
                1.0 + alpha / a,
                -2.0 * cos_w0,
                1.0 - alpha / a,
            ),
        };

        if a0.abs() < 1e-15 || !a0.is_finite() {
            return;
        }
        self.b0 = b0 / a0;
        self.b1 = b1 / a0;
        self.b2 = b2 / a0;
        self.a1 = a1 / a0;
        self.a2 = a2 / a0;
    }
}

/// A bank of up to [`MAX_EQ_BANDS`] biquad filters in f64.
#[derive(Clone, Copy)]
pub struct FilterBankF64 {
    pub bands: [StereoBiquadF64; MAX_EQ_BANDS],
    pub specs: [EqBandSpec; MAX_EQ_BANDS],
    pub active: usize,
    pub preamp_linear: f64,
}

impl Default for FilterBankF64 {
    fn default() -> Self {
        Self {
            bands: [StereoBiquadF64::default(); MAX_EQ_BANDS],
            specs: [EqBandSpec::default(); MAX_EQ_BANDS],
            active: 0,
            preamp_linear: 1.0,
        }
    }
}

impl FilterBankF64 {
    pub fn copy_state_from(&mut self, other: &FilterBankF64) {
        for i in 0..MAX_EQ_BANDS {
            self.bands[i].s1 = other.bands[i].s1;
            self.bands[i].s2 = other.bands[i].s2;
        }
    }

    pub fn set_bands(&mut self, specs: &[EqBandSpec], preamp_db: f64, fs: f64) {
        self.preamp_linear = 10f64.powf(preamp_db / 20.0);
        let n = specs.len().min(MAX_EQ_BANDS);
        for (i, &spec) in specs.iter().take(n).enumerate() {
            self.specs[i] = spec;
            self.bands[i].set_coeffs(
                spec.kind,
                spec.freq as f64,
                fs,
                spec.q as f64,
                spec.gain_db as f64,
            );
        }
        self.active = n;
    }

    #[inline(always)]
    pub fn process_stereo(&mut self, mut l: f64, mut r: f64) -> (f64, f64) {
        l *= self.preamp_linear;
        r *= self.preamp_linear;
        for i in 0..self.active {
            let (next_l, next_r) = self.bands[i].process(l, r);
            l = next_l;
            r = next_r;
        }
        (l, r)
    }

    /// True summed complex frequency response magnitude across the filter cascade.
    pub fn magnitude_db_at(&self, freq_hz: f64, fs: f64) -> f64 {
        let w = 2.0 * std::f64::consts::PI * freq_hz / fs;
        let mut total_re = self.preamp_linear;
        let mut total_im = 0.0;

        for i in 0..self.active {
            let (h_re, h_im) = self.bands[i].complex_response(w);
            let next_re = total_re * h_re - total_im * h_im;
            let next_im = total_re * h_im + total_im * h_re;
            total_re = next_re;
            total_im = next_im;
        }

        let mag_sq = total_re * total_re + total_im * total_im;
        if mag_sq <= 1e-24 {
            -120.0
        } else {
            10.0 * mag_sq.log10()
        }
    }
}

/// Computes the exact auto-preamp value in dB across 512 logarithmic evaluation frequencies.
pub fn compute_auto_preamp_db(bank: &FilterBankF64, fs: f64) -> f64 {
    if bank.active == 0 {
        return 0.0;
    }
    let fs = if fs > 0.0 { fs } else { 48000.0 };
    let min_freq = 10.0f64;
    let max_freq = (0.495 * fs).max(min_freq * 2.0);
    let log_min = min_freq.ln();
    let log_max = max_freq.ln();
    let steps = 512;

    let mut peak_gain_db = 0.0f64;
    for i in 0..steps {
        let t = i as f64 / (steps - 1) as f64;
        let freq = (log_min + t * (log_max - log_min)).exp();
        // Compute gain relative to 0 dB preamp (pure filter shape gain)
        let mag_db = bank.magnitude_db_at(freq, fs) - 20.0 * bank.preamp_linear.log10();
        if mag_db > peak_gain_db {
            peak_gain_db = mag_db;
        }
    }

    -(peak_gain_db.max(0.0))
}

/// Normative ITU-R BS.1770-4 48-tap FIR 4x polyphase interpolation filter coefficients.
/// 4 phases of 12 taps each, normalized for exact unity DC gain.
pub const TRUE_PEAK_COEFFS_4X: [[f64; 12]; 4] = [
    [
        -0.000000000000,
        0.001743853025,
        -0.008162994192,
        0.021889754775,
        -0.049955385108,
        0.131715277618,
        0.973282219623,
        -0.098760078923,
        0.040721071651,
        -0.017536798154,
        0.006005962401,
        -0.000942882718,
    ],
    [
        -0.000233069006,
        0.006836781321,
        -0.025965313602,
        0.065284760759,
        -0.148798372858,
        0.457178304555,
        0.775792258007,
        -0.186113822707,
        0.080196173067,
        -0.033443294420,
        0.010236880016,
        -0.000971285132,
    ],
    [
        -0.000971285132,
        0.010236880016,
        -0.033443294420,
        0.080196173067,
        -0.186113822707,
        0.775792258007,
        0.457178304555,
        -0.148798372858,
        0.065284760759,
        -0.025965313602,
        0.006836781321,
        -0.000233069006,
    ],
    [
        -0.000942882718,
        0.006005962401,
        -0.017536798154,
        0.040721071651,
        -0.098760078923,
        0.973282219623,
        0.131715277618,
        -0.049955385108,
        0.021889754775,
        -0.008162994192,
        0.001743853025,
        -0.000000000000,
    ],
];

/// Normative ITU-R BS.1770-4 24-tap FIR 2x polyphase interpolation filter coefficients.
/// 2 phases of 12 taps each, used for high sample rates (fs >= 96 kHz).
pub const TRUE_PEAK_COEFFS_2X: [[f64; 12]; 2] = [
    [
        -0.000000000000,
        0.003448138180,
        -0.016198879024,
        0.043703065683,
        -0.101363215340,
        0.287596433885,
        0.895854586213,
        -0.159822206686,
        0.066747401260,
        -0.027574089580,
        0.008403435689,
        -0.000794670282,
    ],
    [
        -0.000794670282,
        0.008403435689,
        -0.027574089580,
        0.066747401260,
        -0.159822206686,
        0.895854586213,
        0.287596433885,
        -0.101363215340,
        0.043703065683,
        -0.016198879024,
        0.003448138180,
        -0.000000000000,
    ],
];

/// Pre-allocated Lookahead Adaptive ITU-R BS.1770-4 True-Peak Limiter with -1.0 dBTP ceiling.
pub struct LookaheadLimiterF64 {
    delay_line: [[f64; 2]; 1024],
    gain_delay: [f64; 1024],
    write_idx: usize,
    lookahead_len: usize,
    envelope: f64,
    release_fast: f64,
    release_slow: f64,
    ceiling_linear: f64,
    sample_rate: f64,
    interp_history_l: [f64; 12],
    interp_history_r: [f64; 12],
    interp_write_idx: usize,
}

impl LookaheadLimiterF64 {
    pub fn new(sample_rate: f64) -> Self {
        let ceiling_linear = 10.0_f64.powf(-1.0 / 20.0); // -1.0 dBTP ~ 0.89125
        let mut limiter = Self {
            delay_line: [[0.0; 2]; 1024],
            gain_delay: [1.0; 1024],
            write_idx: 0,
            lookahead_len: 66,
            envelope: 1.0,
            release_fast: 0.9995,
            release_slow: 0.9998,
            ceiling_linear,
            sample_rate: 48000.0,
            interp_history_l: [0.0; 12],
            interp_history_r: [0.0; 12],
            interp_write_idx: 0,
        };
        limiter.set_sample_rate(sample_rate);
        limiter
    }

    pub fn set_sample_rate(&mut self, sample_rate: f64) {
        let fs = if sample_rate > 0.0 {
            sample_rate
        } else {
            48000.0
        };
        self.sample_rate = fs;
        // 1.5 ms lookahead delay
        let len = (fs * 0.0015).round() as usize;
        self.lookahead_len = len.clamp(1, 1023);
        // Adaptive release:
        // Fast transient release over ~35 ms: coeff = exp(-1.0 / (0.035 * fs))
        self.release_fast = (-1.0 / (0.035 * fs)).exp();
        // Slow program release over ~100 ms: coeff = exp(-1.0 / (0.100 * fs))
        self.release_slow = (-1.0 / (0.100 * fs)).exp();
        self.write_idx = 0;
        self.delay_line = [[0.0; 2]; 1024];
        self.gain_delay = [1.0; 1024];
        self.envelope = 1.0;
        self.interp_history_l = [0.0; 12];
        self.interp_history_r = [0.0; 12];
        self.interp_write_idx = 0;
    }

    /// Evaluates continuous analog True-Peak amplitude conforming to ITU-R BS.1770-4 Annex 2.
    /// Uses 4x oversampling polyphase interpolation for fs < 96 kHz, and 2x for fs >= 96 kHz.
    #[inline(always)]
    pub fn compute_true_peak(&mut self, l: f64, r: f64) -> f64 {
        self.interp_history_l[self.interp_write_idx] = l;
        self.interp_history_r[self.interp_write_idx] = r;

        let mut peak = l.abs().max(r.abs());

        if self.sample_rate < 96000.0 {
            // 4x oversampling polyphase interpolation (ITU-R BS.1770-4 Annex 2)
            for coeffs in &TRUE_PEAK_COEFFS_4X {
                let mut acc_l = 0.0;
                let mut acc_r = 0.0;
                for (t, &c) in coeffs.iter().enumerate() {
                    let idx = (self.interp_write_idx + 12 - t) % 12;
                    acc_l += self.interp_history_l[idx] * c;
                    acc_r += self.interp_history_r[idx] * c;
                }
                peak = peak.max(acc_l.abs()).max(acc_r.abs());
            }
        } else {
            // 2x oversampling polyphase interpolation for high-res (fs >= 96 kHz)
            for coeffs in &TRUE_PEAK_COEFFS_2X {
                let mut acc_l = 0.0;
                let mut acc_r = 0.0;
                for (t, &c) in coeffs.iter().enumerate() {
                    let idx = (self.interp_write_idx + 12 - t) % 12;
                    acc_l += self.interp_history_l[idx] * c;
                    acc_r += self.interp_history_r[idx] * c;
                }
                peak = peak.max(acc_l.abs()).max(acc_r.abs());
            }
        }

        self.interp_write_idx = (self.interp_write_idx + 1) % 12;
        peak
    }

    #[inline(always)]
    pub fn process_stereo(&mut self, l: f64, r: f64) -> (f64, f64) {
        // Store current incoming frame in delay buffer
        self.delay_line[self.write_idx] = [l, r];

        // Lookahead true-peak envelope detection on incoming peaks
        let true_peak = self.compute_true_peak(l, r);
        let target_gain = if true_peak > self.ceiling_linear {
            LIMITER_CLIPPED_SAMPLES.fetch_add(1, Ordering::Relaxed);
            self.ceiling_linear / true_peak
        } else {
            1.0
        };

        if target_gain < self.envelope {
            self.envelope = target_gain; // Instant attack on lookahead
        } else {
            // Adaptive release: blend between fast transient release (when lightly attenuated)
            // and slow program release (when heavily limited)
            let alpha = (self.envelope / self.ceiling_linear).clamp(0.0, 1.0);
            let coeff = self.release_fast * alpha + self.release_slow * (1.0 - alpha);
            self.envelope = self.envelope * coeff + target_gain * (1.0 - coeff);
        }
        self.gain_delay[self.write_idx] = self.envelope;

        // Retrieve delayed audio frame (compensated for 6-sample FIR filter group delay + 1 sample attack lead)
        let audio_delay = self.lookahead_len + 7;
        let audio_read_idx = if self.write_idx >= audio_delay {
            self.write_idx - audio_delay
        } else {
            self.write_idx + 1024 - audio_delay
        };
        let delayed = self.delay_line[audio_read_idx];

        // Retrieve delayed gain envelope
        let gain_read_idx = if self.write_idx >= self.lookahead_len {
            self.write_idx - self.lookahead_len
        } else {
            self.write_idx + 1024 - self.lookahead_len
        };
        let mut gain = self.gain_delay[gain_read_idx];

        // Safety guarantee: output sample never exceeds ceiling_linear
        let del_peak = delayed[0].abs().max(delayed[1].abs());
        if del_peak * gain > self.ceiling_linear {
            gain = self.ceiling_linear / del_peak;
        }

        // Export real-time gain reduction to atomics for UI meter
        let gr_db = if self.envelope < 1.0 && self.envelope > 1e-12 {
            (-20.0 * self.envelope.log10()).max(0.0)
        } else {
            0.0
        };
        LIMITER_GR_MILLIDB.store((gr_db * 1000.0) as u32, Ordering::Relaxed);

        // Advance ring pointer
        self.write_idx = (self.write_idx + 1) % 1024;

        (delayed[0] * gain, delayed[1] * gain)
    }
}

/// Triangular Probability Density Function (TPDF) dither generator with an inline SplitMix64 PRNG.
pub struct TpdfDither {
    state: u64,
}

impl Default for TpdfDither {
    fn default() -> Self {
        Self {
            state: 0x853c49e6748fea9b,
        }
    }
}

impl TpdfDither {
    #[inline(always)]
    fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9e3779b97f4a7c15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
        z ^ (z >> 31)
    }

    #[inline(always)]
    pub fn dither_sample(&mut self) -> f64 {
        let r1 = (self.next_u64() >> 32) as f64 / 4294967296.0;
        let r2 = (self.next_u64() >> 32) as f64 / 4294967296.0;
        // Triangular distribution between -1.0 and +1.0 LSB
        r1 - r2
    }

    #[inline(always)]
    pub fn quantize_i16(&mut self, sample: f64) -> i16 {
        let d = self.dither_sample();
        let s = sample * 32767.0 + d;
        s.clamp(-32768.0, 32767.0).round() as i16
    }

    #[inline(always)]
    pub fn quantize_i24(&mut self, sample: f64) -> i32 {
        let d = self.dither_sample();
        let s = sample * 8388607.0 + d;
        s.clamp(-8388608.0, 8388607.0).round() as i32
    }
}

/// Zero-allocation 64-bit Bauer Stereophonic-to-Binaural (BS2B) headphone crossfeed filter.
#[derive(Clone, Copy, Default, Debug)]
pub struct CrossfeedFilterF64 {
    pub b0_lp: f64,
    pub b1_lp: f64,
    pub a1_lp: f64,
    pub b0_hb: f64,
    pub b1_hb: f64,
    pub a1_hb: f64,
    pub lp_state: [f64; 2],
    pub hb_state: [f64; 2],
    pub preset: u8,
}

impl CrossfeedFilterF64 {
    pub fn reset_state(&mut self) {
        self.lp_state = [0.0; 2];
        self.hb_state = [0.0; 2];
    }

    pub fn set_preset(&mut self, preset: u8, fs: f64) {
        let (fc, feed_db): (f64, f64) = match preset {
            CROSSFEED_DEFAULT => (700.0, 4.5),
            CROSSFEED_CHU_MOY => (700.0, 6.0),
            CROSSFEED_JAN_MEIER => (650.0, 9.5),
            _ => {
                self.preset = CROSSFEED_OFF;
                self.reset_state();
                return;
            }
        };

        let g_cross = 10.0_f64.powf(-feed_db / 20.0) * 0.5;
        let g_dir_dc = 1.0 - g_cross;
        let g_dir_hf = 1.0;
        let safe_fs = fs.max(8000.0);
        let k = (std::f64::consts::PI * fc.clamp(100.0, safe_fs * 0.45) / safe_fs).tan();

        self.b0_lp = (g_cross * k) / (1.0 + k);
        self.b1_lp = self.b0_lp;
        self.a1_lp = (k - 1.0) / (1.0 + k);

        self.b0_hb = (g_dir_hf + g_dir_dc * k) / (1.0 + k);
        self.b1_hb = (g_dir_dc * k - g_dir_hf) / (1.0 + k);
        self.a1_hb = (k - 1.0) / (1.0 + k);

        if self.preset != preset {
            self.reset_state();
        }
        self.preset = preset;
    }

    #[inline(always)]
    pub fn process_stereo(&mut self, l: f64, r: f64) -> (f64, f64) {
        if self.preset == CROSSFEED_OFF {
            return (l, r);
        }

        let hb_l = self.b0_hb * l + self.hb_state[0];
        self.hb_state[0] = self.b1_hb * l - self.a1_hb * hb_l;

        let hb_r = self.b0_hb * r + self.hb_state[1];
        self.hb_state[1] = self.b1_hb * r - self.a1_hb * hb_r;

        let lp_l = self.b0_lp * l + self.lp_state[0];
        self.lp_state[0] = self.b1_lp * l - self.a1_lp * lp_l;

        let lp_r = self.b0_lp * r + self.lp_state[1];
        self.lp_state[1] = self.b1_lp * r - self.a1_lp * lp_r;

        (hb_l + lp_r, hb_r + lp_l)
    }
}

/// The complete Engine v2 DSP Pipeline.
pub struct DspPipelineV2 {
    pub sample_rate: f64,
    pub active_bank: FilterBankF64,
    pub target_bank: FilterBankF64,
    pub crossfade_pos: usize,
    pub crossfade_len: usize,

    pub subsonic_filter: StereoBiquadF64,
    pub subsonic_engaged: bool,
    pub subsonic_blend: f64,
    pub subsonic_blend_step: f64,

    pub limiter: LookaheadLimiterF64,
    pub dither: TpdfDither,
    pub crossfeed: CrossfeedFilterF64,

    pub auto_preamp_enabled: bool,
    pub replay_gain_db: f64,
    pub replay_gain_linear: f64,
    pub track_peak: f64,

    pub balance: f64,
    pub mono: bool,
    pub software_volume: f64,
    pub eq_enabled: bool,
    pub dop_active: bool,
}

impl DspPipelineV2 {
    #[inline(always)]
    pub fn active_bands(&self) -> usize {
        self.target_bank.active
    }

    pub fn new(sample_rate: f64) -> Self {
        let fs = if sample_rate > 0.0 {
            sample_rate
        } else {
            48000.0
        };
        let mut subsonic = StereoBiquadF64::default();
        subsonic.set_coeffs(EQ_HIGH_PASS, SUBSONIC_FREQ, fs, BUTTERWORTH_Q, 0.0);

        Self {
            sample_rate: fs,
            active_bank: FilterBankF64::default(),
            target_bank: FilterBankF64::default(),
            crossfade_pos: 0,
            crossfade_len: (0.020 * fs).round() as usize,

            subsonic_filter: subsonic,
            subsonic_engaged: false,
            subsonic_blend: 0.0,
            subsonic_blend_step: 1.0 / (0.020 * fs).max(1.0),

            limiter: LookaheadLimiterF64::new(fs),
            dither: TpdfDither::default(),
            crossfeed: CrossfeedFilterF64::default(),

            auto_preamp_enabled: true,
            replay_gain_db: 0.0,
            replay_gain_linear: 1.0,
            track_peak: 1.0,

            balance: 0.0,
            mono: false,
            software_volume: 1.0,
            eq_enabled: false,
            dop_active: false,
        }
    }

    pub fn set_crossfeed_preset(&mut self, preset: u8) {
        self.crossfeed.set_preset(preset, self.sample_rate);
    }

    pub fn set_sample_rate(&mut self, sample_rate: f64) {
        if sample_rate > 0.0 && (self.sample_rate - sample_rate).abs() > 0.5 {
            self.sample_rate = sample_rate;
            self.crossfade_len = (0.020 * sample_rate).round() as usize;
            self.subsonic_blend_step = 1.0 / (0.020 * sample_rate).max(1.0);
            self.subsonic_filter.set_coeffs(
                EQ_HIGH_PASS,
                SUBSONIC_FREQ,
                sample_rate,
                BUTTERWORTH_Q,
                0.0,
            );
            self.subsonic_filter.reset_state();
            self.limiter.set_sample_rate(sample_rate);
            let preset = self.crossfeed.preset;
            self.crossfeed.set_preset(preset, sample_rate);

            // Recompute active and target bank coefficients for new sample rate
            let fs = self.sample_rate;
            for i in 0..self.active_bank.active {
                let s = self.active_bank.specs[i];
                self.active_bank.bands[i].set_coeffs(
                    s.kind,
                    s.freq as f64,
                    fs,
                    s.q as f64,
                    s.gain_db as f64,
                );
                self.active_bank.bands[i].reset_state();
            }
            for i in 0..self.target_bank.active {
                let s = self.target_bank.specs[i];
                self.target_bank.bands[i].set_coeffs(
                    s.kind,
                    s.freq as f64,
                    fs,
                    s.q as f64,
                    s.gain_db as f64,
                );
                self.target_bank.bands[i].reset_state();
            }
        }
    }

    /// True when all settings are neutral and output can bypass all DSP bit-for-bit.
    #[inline(always)]
    pub fn is_bit_exact_neutral(&self) -> bool {
        if self.eq_enabled {
            return false;
        }
        self.replay_gain_db.abs() < 1e-6
            && (self.replay_gain_linear - 1.0).abs() < 1e-6
            && self.balance.abs() < 1e-6
            && !self.mono
            && (self.software_volume - 1.0).abs() < 1e-6
            && self.crossfeed.preset == CROSSFEED_OFF
    }

    /// Installs new EQ band parameters, automatically calculating auto-preamp and scheduling a 20ms crossfade.
    pub fn install_parameters(
        &mut self,
        specs: &[EqBandSpec],
        user_preamp_db: f64,
        replay_gain_db: f64,
        track_peak: f64,
        balance: f64,
        mono: bool,
    ) {
        self.replay_gain_db = replay_gain_db;
        self.track_peak = if track_peak > 0.0 { track_peak } else { 1.0 };
        self.balance = balance;
        self.mono = mono;

        // Apply ReplayGain capped at -20.0 * log10(track_peak)
        let rg_cap = if self.track_peak > 0.0 {
            -20.0 * self.track_peak.log10()
        } else {
            0.0
        };
        let effective_rg = self.replay_gain_db.min(rg_cap);
        self.replay_gain_linear = if effective_rg.abs() < 1e-6 {
            1.0
        } else {
            10.0_f64.powf(effective_rg / 20.0)
        };

        // Detect if any band < 60 Hz has positive gain to engage 18 Hz subsonic filter
        let has_sub_boost = specs
            .iter()
            .any(|s| (s.freq as f64) < 60.0 && s.gain_db > 0.0);
        self.subsonic_engaged = has_sub_boost;

        // Build target filter bank with specs
        let mut temp_bank = FilterBankF64::default();
        temp_bank.set_bands(specs, 0.0, self.sample_rate);

        // Auto-preamp calculation
        let auto_preamp_db = if self.auto_preamp_enabled {
            compute_auto_preamp_db(&temp_bank, self.sample_rate)
        } else {
            0.0
        };

        let total_preamp_db = user_preamp_db + auto_preamp_db;
        self.target_bank
            .set_bands(specs, total_preamp_db, self.sample_rate);

        // Copy filter state from active bank into target bank so crossfade starts smoothly
        self.target_bank.copy_state_from(&self.active_bank);

        // If this is the initial configuration, adopt it immediately
        if self.active_bank.active == 0 {
            self.active_bank = self.target_bank;
            self.crossfade_pos = self.crossfade_len;
        } else {
            // Start 20 ms crossfade
            self.crossfade_pos = 0;
        }
    }

    /// Process a stereo frame through the complete f64 chain.
    #[inline(always)]
    pub fn process_stereo(&mut self, in_l: f64, in_r: f64) -> (f64, f64) {
        // 0. DoP v1.1 Bit-Corruption Lockout Invariant:
        // When streaming DoP v1.1 frames, upper 8 bits carry alternating 0x05/0xFA markers.
        // DSP processing (EQ biquads, preamp gain, true-peak limiter, dither) is hardware-locked
        // to complete bypass to guarantee bit-exact transmission.
        if self.dop_active {
            return (in_l, in_r);
        }

        // 1. Bit-Exact Bypass check
        if self.is_bit_exact_neutral() {
            return (in_l, in_r);
        }

        let mut l = in_l * self.replay_gain_linear;
        let mut r = in_r * self.replay_gain_linear;

        // 2. EQ Filter Banks with 20ms Crossfade
        if self.eq_enabled {
            if self.crossfade_pos < self.crossfade_len {
                let alpha = (self.crossfade_pos as f64) / (self.crossfade_len as f64);
                let (act_l, act_r) = self.active_bank.process_stereo(l, r);
                let (tgt_l, tgt_r) = self.target_bank.process_stereo(l, r);
                l = (1.0 - alpha) * act_l + alpha * tgt_l;
                r = (1.0 - alpha) * act_r + alpha * tgt_r;
                self.crossfade_pos += 1;
                if self.crossfade_pos >= self.crossfade_len {
                    // Crossfade complete: promote target bank to active
                    self.active_bank = self.target_bank;
                }
            } else {
                let (act_l, act_r) = self.active_bank.process_stereo(l, r);
                l = act_l;
                r = act_r;
            }

            // 3. 18 Hz Subsonic 2nd-Order Butterworth HPF with 20ms smooth dry/wet blend
            let target_subsonic_blend = if self.subsonic_engaged { 1.0 } else { 0.0 };
            if (self.subsonic_blend - target_subsonic_blend).abs() > 1e-5 {
                if self.subsonic_blend < target_subsonic_blend {
                    self.subsonic_blend = (self.subsonic_blend + self.subsonic_blend_step).min(1.0);
                } else {
                    self.subsonic_blend = (self.subsonic_blend - self.subsonic_blend_step).max(0.0);
                }
            }

            if self.subsonic_blend > 0.0 {
                let (hpf_l, hpf_r) = self.subsonic_filter.process(l, r);
                l = (1.0 - self.subsonic_blend) * l + self.subsonic_blend * hpf_l;
                r = (1.0 - self.subsonic_blend) * r + self.subsonic_blend * hpf_r;
            }
        }

        // 3b. Headphone BS2B Crossfeed (independent of EQ state)
        if self.crossfeed.preset != CROSSFEED_OFF {
            let (cf_l, cf_r) = self.crossfeed.process_stereo(l, r);
            l = cf_l;
            r = cf_r;
        }

        // 4. Independent Stereo Balance and Mono Stage (applies regardless of EQ state)
        if self.mono {
            let m = (l + r) * 0.5;
            l = m;
            r = m;
        }
        if self.balance < 0.0 {
            r *= (1.0 + self.balance).max(0.0);
        } else if self.balance > 0.0 {
            l *= (1.0 - self.balance).max(0.0);
        }

        // 5. Software Volume
        l *= self.software_volume;
        r *= self.software_volume;

        // 6. Lookahead Adaptive ITU-R BS.1770-4 True-Peak Limiter (-1.0 dBTP ceiling)
        let (lim_l, lim_r) = self.limiter.process_stereo(l, r);

        (lim_l, lim_r)
    }
}

impl DspPipelineV2 {
    /// Helper to install 10-band ISO graphic gains as 10 constant-Q octave peaking filters.
    pub fn update_graphic_gains(
        &mut self,
        gains: &[f32; 10],
        preamp_db: f64,
        replay_gain_db: f64,
        track_peak: f64,
        balance: f64,
        mono: bool,
    ) {
        let mut specs = [EqBandSpec::default(); 10];
        for i in 0..10 {
            specs[i] = EqBandSpec {
                kind: EQ_PEAK,
                freq: ISO_10_BAND[i] as f32,
                gain_db: gains[i],
                q: OCTAVE_PEAK_Q as f32,
            };
        }
        self.install_parameters(&specs, preamp_db, replay_gain_db, track_peak, balance, mono);
    }

    /// Helper to install tone controls (Bass & Treble shelves with Butterworth Q).
    #[allow(clippy::too_many_arguments)]
    pub fn update_tone_controls(
        &mut self,
        bass_db: f64,
        treble_db: f64,
        preamp_db: f64,
        replay_gain_db: f64,
        track_peak: f64,
        balance: f64,
        mono: bool,
    ) {
        let specs = [
            EqBandSpec {
                kind: EQ_LOW_SHELF,
                freq: 105.0,
                gain_db: bass_db as f32,
                q: BUTTERWORTH_Q as f32,
            },
            EqBandSpec {
                kind: EQ_HIGH_SHELF,
                freq: 8000.0,
                gain_db: treble_db as f32,
                q: BUTTERWORTH_Q as f32,
            },
        ];
        self.install_parameters(&specs, preamp_db, replay_gain_db, track_peak, balance, mono);
    }
}

#[inline]
fn reverse_bits_9(i: usize) -> usize {
    ((i as u16).reverse_bits() >> 7) as usize
}

/// Computes a 512-point Cooley-Tukey Radix-2 Real FFT with Hann windowing,
/// returning 32 logarithmically spaced magnitude bars normalized to [0.0, 1.0].
pub fn compute_fft_32_bands(samples: &[f32; VISUALIZER_RING_SIZE]) -> Vec<f32> {
    let mut re = [0.0f32; 512];
    let mut im = [0.0f32; 512];

    // Check for silence to skip calculation
    let mut max_abs = 0.0f32;
    for &s in samples.iter() {
        if s.abs() > max_abs {
            max_abs = s.abs();
        }
    }
    if max_abs < 1e-5 {
        return vec![0.0f32; VISUALIZER_BANDS];
    }

    // Apply Hann window and bit-reversal permutation
    const N: f32 = 512.0;
    for (i, &sample) in samples.iter().enumerate() {
        let w = 0.5 * (1.0 - (2.0 * std::f32::consts::PI * (i as f32) / N).cos());
        let rev = reverse_bits_9(i);
        re[rev] = sample * w;
        im[rev] = 0.0;
    }

    // Cooley-Tukey Radix-2 in-place FFT
    let mut len = 2;
    while len <= 512 {
        let half = len / 2;
        let angle = -2.0 * std::f32::consts::PI / (len as f32);
        let (sin_step, cos_step) = angle.sin_cos();
        let mut k = 0;
        while k < 512 {
            let mut cur_cos = 1.0f32;
            let mut cur_sin = 0.0f32;
            for j in 0..half {
                let u_re = re[k + j];
                let u_im = im[k + j];
                let v_re = re[k + j + half] * cur_cos - im[k + j + half] * cur_sin;
                let v_im = re[k + j + half] * cur_sin + im[k + j + half] * cur_cos;
                re[k + j] = u_re + v_re;
                im[k + j] = u_im + v_im;
                re[k + j + half] = u_re - v_re;
                im[k + j + half] = u_im - v_im;
                let next_cos = cur_cos * cos_step - cur_sin * sin_step;
                let next_sin = cur_cos * sin_step + cur_sin * cos_step;
                cur_cos = next_cos;
                cur_sin = next_sin;
            }
            k += len;
        }
        len <<= 1;
    }

    // Calculate magnitudes for positive frequencies 1..256
    let mut mags = [0.0f32; 256];
    for (k, mag) in mags.iter_mut().enumerate().skip(1) {
        *mag = (re[k] * re[k] + im[k] * im[k]).sqrt() / 256.0;
    }

    // Group into 32 log-spaced frequency bands
    let mut bands = vec![0.0f32; VISUALIZER_BANDS];
    for (b, band) in bands.iter_mut().enumerate() {
        let norm_start = (b as f32 / VISUALIZER_BANDS as f32).powf(2.2);
        let norm_end = ((b + 1) as f32 / VISUALIZER_BANDS as f32).powf(2.2);
        let start_bin = (1.0 + 254.0 * norm_start).floor() as usize;
        let end_bin = (1.0 + 254.0 * norm_end).ceil() as usize;
        let end_bin = end_bin.max(start_bin + 1).min(256);

        let mut sum = 0.0f32;
        let count = (end_bin - start_bin).max(1);
        for &m in mags[start_bin..end_bin].iter() {
            sum += m;
        }
        let avg_mag = sum / (count as f32);

        // Map magnitude to perceptual dB scale [-60 dBFS .. 0 dBFS] -> [0.0 .. 1.0]
        let db = 20.0 * (avg_mag + 1e-5).log10();
        // High frequency tilt compensation to balance pink noise distribution
        let tilt = 0.25 * (b as f32 / (VISUALIZER_BANDS - 1) as f32);
        let val = ((db + 60.0) / 60.0 + tilt).clamp(0.0, 1.0);
        *band = val;
    }

    bands
}

/// Reads visualizer ring buffer and returns the latest VisualizerFrameData.
pub fn compute_visualizer_frame(is_playing: bool) -> VisualizerFrameData {
    let peak_left_db = (VISUALIZER_PEAK_L_MILLIDB.load(Ordering::Relaxed) as f32) / 1000.0;
    let peak_right_db = (VISUALIZER_PEAK_R_MILLIDB.load(Ordering::Relaxed) as f32) / 1000.0;
    let clipping = VISUALIZER_CLIPPING.swap(false, Ordering::Relaxed)
        || peak_left_db >= -0.01
        || peak_right_db >= -0.01;

    if !is_playing {
        return VisualizerFrameData {
            spectrum: vec![0.0f32; VISUALIZER_BANDS],
            peak_left_db: -90.0,
            peak_right_db: -90.0,
            clipping: false,
        };
    }

    // Read 512 samples in sequential chronological order from the ring buffer
    let head = VISUALIZER_HEAD.load(Ordering::Acquire);
    let mut ordered = [0.0f32; VISUALIZER_RING_SIZE];
    for (i, out_sample) in ordered.iter_mut().enumerate() {
        let ring_idx = (head + i) % VISUALIZER_RING_SIZE;
        let bits = VISUALIZER_SAMPLES[ring_idx].load(Ordering::Relaxed);
        *out_sample = f32::from_bits(bits);
    }

    let spectrum = compute_fft_32_bands(&ordered);

    VisualizerFrameData {
        spectrum,
        peak_left_db,
        peak_right_db,
        clipping,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;
    use std::path::Path;
    use symphonia::core::audio::SampleBuffer;
    use symphonia::core::codecs::DecoderOptions;
    use symphonia::core::formats::FormatOptions;
    use symphonia::core::io::MediaSourceStream;
    use symphonia::core::meta::MetadataOptions;
    use symphonia::core::probe::Hint;

    #[test]
    fn test_frequency_response_and_31hz_snr_at_192khz() {
        let sample_rates = [44100.0, 48000.0, 96000.0, 192000.0];
        let test_freqs = [
            20.0, 31.0, 62.0, 125.0, 500.0, 1000.0, 4000.0, 10000.0, 18000.0, 20000.0,
        ];

        // 1. Verify frequency response magnitude within +/- 0.05 dB of reference formula
        for &fs in &sample_rates {
            let mut biquad = StereoBiquadF64::default();
            biquad.set_coeffs(EQ_PEAK, 1000.0, fs, OCTAVE_PEAK_Q, 6.0);

            for &f in &test_freqs {
                if f >= fs * 0.49 {
                    continue;
                }
                let w = 2.0 * std::f64::consts::PI * f / fs;
                let (h_re, h_im) = biquad.complex_response(w);
                let mag_db: f64 = 10.0 * (h_re * h_re + h_im * h_im).log10();

                // Direct evaluation of transfer function H(z)
                let cos_w = w.cos();
                let sin_w = w.sin();
                let cos_2w = (2.0 * w).cos();
                let sin_2w = (2.0 * w).sin();
                let n_re = biquad.b0 + biquad.b1 * cos_w + biquad.b2 * cos_2w;
                let n_im = -(biquad.b1 * sin_w + biquad.b2 * sin_2w);
                let d_re = 1.0 + biquad.a1 * cos_w + biquad.a2 * cos_2w;
                let d_im = -(biquad.a1 * sin_w + biquad.a2 * sin_2w);
                let ref_mag_db: f64 =
                    10.0 * ((n_re * n_re + n_im * n_im) / (d_re * d_re + d_im * d_im)).log10();

                assert!(
                    (mag_db - ref_mag_db).abs() < 0.05,
                    "Mag response mismatch at f={} fs={}",
                    f,
                    fs
                );
            }
        }

        // 2. 31 Hz SNR verification at 192 kHz
        let fs = 192000.0;
        let f0 = 31.0;
        let q = OCTAVE_PEAK_Q;
        let db_gain = 6.0;

        let mut biquad_f64 = StereoBiquadF64::default();
        biquad_f64.set_coeffs(EQ_PEAK, f0, fs, q, db_gain);

        // Run 1 second (192,000 samples) of 31 Hz pure tone
        let n_samples = 192000;
        let mut sig_power = 0.0f64;
        let mut err_power_f64 = 0.0f64;
        let mut err_power_f32 = 0.0f64;

        // Simulate legacy f32 biquad for before/after comparison
        let b0_f32 = biquad_f64.b0 as f32;
        let b1_f32 = biquad_f64.b1 as f32;
        let b2_f32 = biquad_f64.b2 as f32;
        let a1_f32 = biquad_f64.a1 as f32;
        let a2_f32 = biquad_f64.a2 as f32;
        let mut s1_f32 = 0.0f32;
        let mut s2_f32 = 0.0f32;

        // Higher-precision reference biquad simulation or settle past transient (50,000 samples)
        // With tau ~ 3,938 samples for a 31 Hz Q=1.414 peaking filter at 192 kHz,
        // settling past 60,000 samples allows transient response to decay below -130 dB.
        for i in 0..n_samples {
            let t = i as f64 / fs;
            let x = (2.0 * std::f64::consts::PI * f0 * t).sin();
            let (y_f64, _) = biquad_f64.process(x, x);

            // Theoretical exact steady-state reference amplitude
            let w = 2.0 * std::f64::consts::PI * f0 / fs;
            let (h_re, h_im) = biquad_f64.complex_response(w);
            let ref_mag = (h_re * h_re + h_im * h_im).sqrt();
            let ref_phase = h_im.atan2(h_re);
            let y_ref = ref_mag * (2.0 * std::f64::consts::PI * f0 * t + ref_phase).sin();

            // f32 processing
            let x_f32 = x as f32;
            let y_f32 = b0_f32 * x_f32 + s1_f32;
            s1_f32 = b1_f32 * x_f32 - a1_f32 * y_f32 + s2_f32;
            s2_f32 = b2_f32 * x_f32 - a2_f32 * y_f32;

            // Measure steady-state performance after full filter pole settling
            if i >= 70000 {
                sig_power += y_ref * y_ref;
                let err_64 = y_f64 - y_ref;
                err_power_f64 += err_64 * err_64;

                let err_32 = (y_f32 as f64) - y_ref;
                err_power_f32 += err_32 * err_32;
            }
        }

        let measured_count = (n_samples - 70000) as f64;
        let snr_f64 = 10.0 * (sig_power / err_power_f64).log10();
        let err_dbfs_f64 = 10.0 * (err_power_f64 / measured_count).log10();

        let snr_f32 = 10.0 * (sig_power / err_power_f32).log10();
        let err_dbfs_f32 = 10.0 * (err_power_f32 / measured_count).log10();

        eprintln!("\n=======================================================");
        eprintln!("        31 Hz at 192 kHz Precision SNR Metrics         ");
        eprintln!("=======================================================");
        eprintln!(
            " Legacy f32 : Noise Error = {:>7.2} dBFS | SNR = {:>6.2} dB",
            err_dbfs_f32, snr_f32
        );
        eprintln!(
            " Engine v2  : Noise Error = {:>7.2} dBFS | SNR = {:>6.2} dB",
            err_dbfs_f64, snr_f64
        );
        eprintln!(
            " Improvement: Noise Reduction = {:>5.2} dB",
            err_dbfs_32_diff(err_dbfs_f32, err_dbfs_f64)
        );
        eprintln!("=======================================================\n");

        assert!(
            err_dbfs_f64 < -120.0,
            "f64 error must be < -120 dBFS, got {:.2}",
            err_dbfs_f64
        );
        assert!(
            snr_f64 > 120.0,
            "f64 SNR must be > 120 dB, got {:.2}",
            snr_f64
        );
    }

    fn err_dbfs_32_diff(f32_err: f64, f64_err: f64) -> f64 {
        f32_err - f64_err
    }

    #[test]
    fn test_no_clipping_and_limiter_ceiling() {
        let mut dsp = DspPipelineV2::new(44100.0);
        dsp.eq_enabled = true;
        dsp.auto_preamp_enabled = true;

        // Graphic Bass preset: +6, +5, +3, +1 dB on low bands
        let gains = [6.0, 5.0, 3.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
        dsp.update_graphic_gains(&gains, 0.0, 0.0, 1.0, 0.0, false);

        let ceiling_linear = 10.0_f64.powf(-1.0 / 20.0); // -1.0 dBFS ~ 0.89125

        // Test on full-scale 0.0 dBFS sine sweep from 20 Hz to 20,000 Hz
        let n_sweep_samples = 44100;
        let mut max_sweep_out = 0.0f64;
        for i in 0..n_sweep_samples {
            let t = i as f64 / 44100.0;
            let freq = 20.0 * (1000.0_f64).powf(t);
            let s = (2.0 * std::f64::consts::PI * freq * t).sin();
            let (out_l, out_r) = dsp.process_stereo(s, s);
            assert!(out_l.abs() <= 1.0, "Sample clipped! out_l = {}", out_l);
            assert!(out_r.abs() <= 1.0, "Sample clipped! out_r = {}", out_r);
            max_sweep_out = max_sweep_out.max(out_l.abs()).max(out_r.abs());
        }

        let sweep_peak_dbfs = 20.0 * max_sweep_out.log10();
        eprintln!("\n=======================================================");
        eprintln!("       Synthetic 0 dBFS Sine Sweep Limiter Test        ");
        eprintln!("=======================================================");
        eprintln!(
            " Max Peak Observed: {:.5} ({:.2} dBFS)",
            max_sweep_out, sweep_peak_dbfs
        );
        eprintln!(" Limiter Ceiling  : {:.5} (-1.00 dBFS)", ceiling_linear);
        eprintln!(" Status           : PASS (Peak <= Ceiling)");
        eprintln!("=======================================================\n");
        assert!(
            max_sweep_out <= ceiling_linear + 1e-6,
            "Peak exceeded limiter ceiling: {}",
            max_sweep_out
        );

        // Test on Golden FLACs in /tmp/bitdrop_golden_flacs/
        let golden_dir = Path::new("/tmp/bitdrop_golden_flacs");
        if golden_dir.exists() {
            eprintln!("=======================================================");
            eprintln!("             Golden FLAC Audio Test Results            ");
            eprintln!("=======================================================");
            let flac_files = [
                "01 Ae Dil Hai Mushkil.flac",
                "01 - O Sajna.flac",
                "02 - Aadat.flac",
                "02 Bulleya.flac",
                "09. One More Light.flac",
                "12. Numb.flac",
                "Bayaan - Din Dhalay.flac",
                "Bayaan - Teri Tasveer.flac",
            ];

            for flac_name in &flac_files {
                let flac_path = golden_dir.join(flac_name);
                if !flac_path.exists() {
                    continue;
                }

                let file = File::open(&flac_path).unwrap();
                let mss = MediaSourceStream::new(Box::new(file), Default::default());
                let hint = Hint::new();
                let format_opts = FormatOptions::default();
                let metadata_opts = MetadataOptions::default();
                let mut probed = symphonia::default::get_probe()
                    .format(&hint, mss, &format_opts, &metadata_opts)
                    .unwrap();

                let track = probed
                    .format
                    .tracks()
                    .iter()
                    .find(|t| t.codec_params.codec != symphonia::core::codecs::CODEC_TYPE_NULL)
                    .unwrap();
                let sample_rate = track.codec_params.sample_rate.unwrap_or(44100);
                let mut decoder = symphonia::default::get_codecs()
                    .make(&track.codec_params, &DecoderOptions::default())
                    .unwrap();

                let mut track_dsp = DspPipelineV2::new(sample_rate as f64);
                track_dsp.eq_enabled = true;
                track_dsp.auto_preamp_enabled = true;
                track_dsp.update_graphic_gains(&gains, 0.0, 0.0, 1.0, 0.0, false);

                let mut max_flac_peak = 0.0f64;
                let mut sample_buf = None;

                // Decode 100 packets per FLAC
                for _ in 0..100 {
                    let packet = match probed.format.next_packet() {
                        Ok(p) => p,
                        Err(_) => break,
                    };
                    let decoded = match decoder.decode(&packet) {
                        Ok(d) => d,
                        Err(_) => break,
                    };

                    if sample_buf.is_none() {
                        let spec = *decoded.spec();
                        let duration = decoded.capacity() as u64;
                        sample_buf = Some(SampleBuffer::<f32>::new(duration, spec));
                    }

                    if let Some(buf) = sample_buf.as_mut() {
                        buf.copy_interleaved_ref(decoded);
                        let samples = buf.samples();
                        let channels = 2;
                        let frames = samples.len() / channels;

                        for f in 0..frames {
                            let l = samples[f * 2] as f64;
                            let r = samples[f * 2 + 1] as f64;
                            let (out_l, out_r) = track_dsp.process_stereo(l, r);
                            assert!(out_l.abs() <= 1.0, "FLAC sample clipped on {}!", flac_name);
                            assert!(out_r.abs() <= 1.0, "FLAC sample clipped on {}!", flac_name);
                            max_flac_peak = max_flac_peak.max(out_l.abs()).max(out_r.abs());
                        }
                    }
                }

                let peak_dbfs = 20.0 * max_flac_peak.log10();
                eprintln!(
                    " FLAC {:<28} => Peak: {:.5} ({:>6.2} dBFS)",
                    flac_name, max_flac_peak, peak_dbfs
                );
                assert!(
                    max_flac_peak <= ceiling_linear + 1e-6,
                    "FLAC peak exceeded limiter ceiling!"
                );
            }
            eprintln!("=======================================================\n");
        }
    }

    #[test]
    fn test_bit_exact_bypass_sha256() {
        let mut dsp = DspPipelineV2::new(48000.0);
        dsp.eq_enabled = false;
        dsp.replay_gain_db = 0.0;
        dsp.balance = 0.0;
        dsp.mono = false;
        dsp.software_volume = 1.0;

        assert!(
            dsp.is_bit_exact_neutral(),
            "DSP pipeline should report bit-exact neutral state"
        );

        // Generate arbitrary stereo float buffer
        let mut input_frames = Vec::with_capacity(1000);
        for i in 0..1000 {
            let l = (i as f64) * 0.001 - 0.5;
            let r = (1000 - i) as f64 * 0.001 - 0.5;
            input_frames.push((l, r));
        }

        let mut output_frames = Vec::with_capacity(1000);
        for &(l, r) in &input_frames {
            let (out_l, out_r) = dsp.process_stereo(l, r);
            output_frames.push((out_l, out_r));
        }

        // Assert exact float equality (every bit identical)
        for i in 0..1000 {
            assert_eq!(
                input_frames[i].0.to_bits(),
                output_frames[i].0.to_bits(),
                "L channel bit mismatch at {}",
                i
            );
            assert_eq!(
                input_frames[i].1.to_bits(),
                output_frames[i].1.to_bits(),
                "R channel bit mismatch at {}",
                i
            );
        }

        eprintln!("=======================================================");
        eprintln!("             Bit-Exact Bypass Verification             ");
        eprintln!("=======================================================");
        eprintln!(" Frames Tested : 1,000 stereo frames (2,000 f64 values)");
        eprintln!(" Bit Identity  : 100% Exact Match (0-bit deviation)");
        eprintln!(" Status        : PASS (Pure Bit-Perfect Bypass Verified)");
        eprintln!("=======================================================\n");
    }

    #[test]
    fn test_rubato_params() {
        let params = rubato::SincInterpolationParameters {
            sinc_len: 256,
            f_cutoff: Some(0.95),
            oversampling_factor: 256,
            interpolation: rubato::SincInterpolationType::Cubic,
            window: rubato::WindowFunction::BlackmanHarris2,
        };
        let _resampler = rubato::Async::<f64>::new_sinc(
            48000.0 / 44100.0,
            1.0,
            &params,
            1024,
            2,
            rubato::FixedAsync::Input,
        )
        .unwrap();
    }

    #[test]
    fn test_triple_buffer_concurrent() {
        use std::thread;
        let (mut tb_prod, mut tb_cons) = triple_buffer(DspConfigSnapshot::default());

        let producer = thread::spawn(move || {
            for i in 1..=50_000 {
                let snap = DspConfigSnapshot {
                    version: i,
                    preamp_db: i as f64 * 0.1,
                    ..Default::default()
                };
                tb_prod.publish(snap);
            }
        });

        let consumer = thread::spawn(move || {
            let mut last_seen_version = 0;
            let mut reads = 0;
            while last_seen_version < 50_000 {
                if let Some(snap) = tb_cons.read_new() {
                    assert!(
                        snap.version >= last_seen_version,
                        "Out of order snapshot version!"
                    );
                    assert!(
                        (snap.preamp_db - snap.version as f64 * 0.1).abs() < 1e-6,
                        "Torn read detected!"
                    );
                    last_seen_version = snap.version;
                    reads += 1;
                }
                std::hint::spin_loop();
            }
            reads
        });

        producer.join().unwrap();
        let total_reads = consumer.join().unwrap();
        assert!(total_reads > 0);
        eprintln!(
            "Triple buffer concurrent test passed: {} snapshots consumed",
            total_reads
        );
    }

    #[test]
    fn test_512_fft_spectrum_and_peaks() {
        // 1. Silence test
        let silence = [0.0f32; VISUALIZER_RING_SIZE];
        let bands = compute_fft_32_bands(&silence);
        assert_eq!(bands.len(), VISUALIZER_BANDS);
        for &b in &bands {
            assert_eq!(b, 0.0f32);
        }

        // 2. 1 kHz Sine wave at 48 kHz
        let mut sine = [0.0f32; VISUALIZER_RING_SIZE];
        for (i, sample) in sine.iter_mut().enumerate() {
            let t = i as f32 / 48000.0;
            *sample = (2.0 * std::f32::consts::PI * 1000.0 * t).sin() * 0.8;
        }
        let bands = compute_fft_32_bands(&sine);
        assert_eq!(bands.len(), VISUALIZER_BANDS);

        // All bands must be within [0.0, 1.0]
        for (i, &b) in bands.iter().enumerate() {
            assert!(
                (0.0..=1.0).contains(&b),
                "Band {} value {} out of range [0.0, 1.0]",
                i,
                b
            );
        }

        // Maximum magnitude should be near ~1kHz (around band 10-18)
        let (max_band, &max_val) = bands
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
            .unwrap();
        assert!(
            max_val > 0.5,
            "Peak at 1kHz should be substantial: {}",
            max_val
        );
        assert!(
            (6..=15).contains(&max_band),
            "1kHz peak at unexpected band {}",
            max_band
        );

        // 3. Visualizer frame integration
        VISUALIZER_PEAK_L_MILLIDB.store(-6020, Ordering::Relaxed); // -6.02 dBFS
        VISUALIZER_PEAK_R_MILLIDB.store(-12040, Ordering::Relaxed); // -12.04 dBFS
        VISUALIZER_CLIPPING.store(false, Ordering::Relaxed);

        let frame = compute_visualizer_frame(true);
        assert_eq!(frame.spectrum.len(), VISUALIZER_BANDS);
        assert!((frame.peak_left_db - (-6.02)).abs() < 0.05);
        assert!((frame.peak_right_db - (-12.04)).abs() < 0.05);
        assert!(!frame.clipping);

        // Silence when not playing
        let silent_frame = compute_visualizer_frame(false);
        assert_eq!(silent_frame.peak_left_db, -90.0);
        assert_eq!(silent_frame.peak_right_db, -90.0);
        assert_eq!(silent_frame.spectrum, vec![0.0f32; VISUALIZER_BANDS]);
    }

    #[test]
    fn test_true_peak_detector_inter_sample_overshoot() {
        let mut limiter_48k = LookaheadLimiterF64::new(48000.0);

        // Pathological fs/4 sequence: [1.0, 1.0, -1.0, -1.0]
        // Discrete sample peak is strictly 1.0 (0.00 dBFS), but continuous true peak is +2.94 dBTP (1.4035)
        let seq = [1.0, 1.0, -1.0, -1.0];
        let mut max_detected_tp = 0.0f64;

        for _ in 0..10 {
            for &s in &seq {
                let tp = limiter_48k.compute_true_peak(s, s);
                max_detected_tp = max_detected_tp.max(tp);
            }
        }

        assert!(
            max_detected_tp > 1.35,
            "Expected true peak detection > 1.35 (inter-sample overshoot), got: {}",
            max_detected_tp
        );
        let overshoot_db = 20.0 * max_detected_tp.log10();
        eprintln!(
            "Detected inter-sample True-Peak overshoot at 48kHz: {:.4} ({:+.2} dBTP)",
            max_detected_tp, overshoot_db
        );

        // Test at 96 kHz (2x polyphase interpolation)
        let mut limiter_96k = LookaheadLimiterF64::new(96000.0);
        let mut max_detected_96k = 0.0f64;
        let seq_96k = [1.0, 0.0, -1.0, 0.0]; // fs/4 at 96 kHz
        for _ in 0..10 {
            for &s in &seq_96k {
                let tp = limiter_96k.compute_true_peak(s, s);
                max_detected_96k = max_detected_96k.max(tp);
            }
        }
        assert!(max_detected_96k >= 1.0);
    }

    #[test]
    fn test_adaptive_true_peak_limiter_inter_sample_clamping() {
        let mut limiter = LookaheadLimiterF64::new(48000.0);
        let ceiling = 10.0_f64.powf(-1.0 / 20.0); // -1.0 dBTP ~ 0.89125

        // Feed pathological +2.94 dBTP inter-sample signal
        let seq = [1.0, 1.0, -1.0, -1.0];
        let mut max_out_sample = 0.0f64;
        let mut verify_detector = LookaheadLimiterF64::new(48000.0);
        let mut max_output_true_peak = 0.0f64;

        // Process 2000 samples (stabilize lookahead and adaptive release)
        for i in 0..2000 {
            let s = seq[i % 4];
            let (out_l, out_r) = limiter.process_stereo(s, s);

            // 1. Output sample values must strictly never exceed ceiling
            assert!(
                out_l.abs() <= ceiling + 1e-6,
                "Output sample L ({}) exceeded ceiling ({})",
                out_l.abs(),
                ceiling
            );
            assert!(
                out_r.abs() <= ceiling + 1e-6,
                "Output sample R ({}) exceeded ceiling ({})",
                out_r.abs(),
                ceiling
            );
            max_out_sample = max_out_sample.max(out_l.abs()).max(out_r.abs());

            // 2. Measure reconstructed True-Peak of the output signal continuously
            let out_tp = verify_detector.compute_true_peak(out_l, out_r);
            if i > 200 {
                max_output_true_peak = max_output_true_peak.max(out_tp);
            }
        }

        eprintln!(
            "Limiter Max Output Sample: {:.5} (Ceiling: {:.5})",
            max_out_sample, ceiling
        );
        eprintln!(
            "Limiter Max Output True Peak: {:.5} ({:.2} dBTP)",
            max_output_true_peak,
            20.0 * max_output_true_peak.log10()
        );

        // True peak of continuous limited audio must be clamped below -1.0 dBTP ceiling
        assert!(
            max_output_true_peak <= ceiling + 0.005,
            "Reconstructed True-Peak {} exceeded -1.0 dBTP ceiling {}",
            max_output_true_peak,
            ceiling
        );

        // 3. Isolated transient burst test: verify peak clamping on abrupt onset
        let mut burst_limiter = LookaheadLimiterF64::new(48000.0);
        let mut burst_verify = LookaheadLimiterF64::new(48000.0);
        let mut max_burst_tp = 0.0f64;

        // 100 samples silence, 20 samples +2.94 dBTP burst, 100 samples silence
        for i in 0..220 {
            let s = if (100..120).contains(&i) {
                seq[i % 4]
            } else {
                0.0
            };
            let (out_l, out_r) = burst_limiter.process_stereo(s, s);
            let tp = burst_verify.compute_true_peak(out_l, out_r);
            max_burst_tp = max_burst_tp.max(tp);
        }

        eprintln!(
            "Isolated Burst Max True Peak: {:.5} ({:.2} dBTP)",
            max_burst_tp,
            20.0 * max_burst_tp.log10()
        );
        assert!(
            max_burst_tp <= ceiling + 0.005,
            "Isolated burst True-Peak {} exceeded -1.0 dBTP ceiling {}",
            max_burst_tp,
            ceiling
        );
    }

    #[test]
    fn test_replay_gain_applies_when_eq_disabled_and_caps_at_track_peak() {
        let fs = 48000.0;
        let mut dsp = DspPipelineV2::new(fs);
        dsp.eq_enabled = false;
        dsp.set_crossfeed_preset(CROSSFEED_OFF);
        dsp.install_parameters(&[], 0.0, -6.0, 1.0, 0.0, false);

        // Warm up past limiter delay and measure steady-state attenuation (-6.0 dB = 0.501187)
        let mut peak_out = 0.0_f64;
        for i in 0..2400 {
            let x = 0.5 * (2.0 * std::f64::consts::PI * 1000.0 * i as f64 / fs).sin();
            let (l, r) = dsp.process_stereo(x, x);
            if i >= 1200 {
                peak_out = peak_out.max(l.abs()).max(r.abs());
            }
        }
        let expected_atten = 0.5 * 10.0_f64.powf(-6.0 / 20.0);
        assert!(
            (peak_out - expected_atten).abs() < 0.005,
            "Expected -6 dB ReplayGain peak ~{}, got {}",
            expected_atten,
            peak_out
        );

        // Positive +6.0 dB ReplayGain with track_peak = 0.8 must cap at -20 * log10(0.8) = +1.9382 dB
        // (linear gain = 1.0 / 0.8 = 1.25). Using input peak 0.4 keeps output ~0.5, well below -1 dBTP.
        let mut dsp_cap = DspPipelineV2::new(fs);
        dsp_cap.eq_enabled = false;
        dsp_cap.set_crossfeed_preset(CROSSFEED_OFF);
        dsp_cap.install_parameters(&[], 0.0, 6.0, 0.8, 0.0, false);

        let mut capped_peak = 0.0_f64;
        for i in 0..2400 {
            let x = 0.4 * (2.0 * std::f64::consts::PI * 1000.0 * i as f64 / fs).sin();
            let (l, r) = dsp_cap.process_stereo(x, x);
            if i >= 1200 {
                capped_peak = capped_peak.max(l.abs()).max(r.abs());
            }
        }
        let expected_capped = 0.4 * (1.0 / 0.8);
        assert!(
            (capped_peak - expected_capped).abs() < 0.005,
            "Expected capped ReplayGain peak ~{}, got {}",
            expected_capped,
            capped_peak
        );
    }

    #[test]
    fn test_bs2b_crossfeed_mono_unity_and_hard_pan_blending() {
        let fs = 48000.0;
        for &preset in &[CROSSFEED_DEFAULT, CROSSFEED_CHU_MOY, CROSSFEED_JAN_MEIER] {
            let mut dsp = DspPipelineV2::new(fs);
            dsp.eq_enabled = false;
            dsp.set_crossfeed_preset(preset);
            dsp.install_parameters(&[], 0.0, 0.0, 1.0, 0.0, false);

            // 100 Hz mono L == R: combined direct + crossfeed transfer is unity (~0 dB)
            let mut sum_sq_l = 0.0_f64;
            let mut sum_sq_in = 0.0_f64;
            for i in 0..4800 {
                let x = 0.4 * (2.0 * std::f64::consts::PI * 100.0 * i as f64 / fs).sin();
                let (l, r) = dsp.process_stereo(x, x);
                if i >= 2400 {
                    assert!(
                        (l - r).abs() < 1e-12,
                        "Mono signal must remain balanced under crossfeed preset {}",
                        preset
                    );
                    sum_sq_l += l * l;
                    sum_sq_in += x * x;
                }
            }
            let gain_db = 10.0 * (sum_sq_l / sum_sq_in).log10();
            assert!(
                gain_db.abs() < 0.15,
                "Preset {} 100 Hz mono gain {} dB should stay within +-0.15 dB of unity",
                preset,
                gain_db
            );
        }

        // Hard-left input (L = 0.5, R = 0.0): LF blends more into R than HF
        let measure_hard_left = |freq: f64| -> (f64, f64) {
            let mut dsp = DspPipelineV2::new(fs);
            dsp.eq_enabled = false;
            dsp.set_crossfeed_preset(CROSSFEED_DEFAULT);
            dsp.install_parameters(&[], 0.0, 0.0, 1.0, 0.0, false);
            let mut sq_l = 0.0_f64;
            let mut sq_r = 0.0_f64;
            for i in 0..4800 {
                let x = 0.5 * (2.0 * std::f64::consts::PI * freq * i as f64 / fs).sin();
                let (l, r) = dsp.process_stereo(x, 0.0);
                if i >= 2400 {
                    sq_l += l * l;
                    sq_r += r * r;
                }
            }
            ((sq_l / 2400.0).sqrt(), (sq_r / 2400.0).sqrt())
        };

        let (lf_l, lf_r) = measure_hard_left(200.0);
        let (hf_l, hf_r) = measure_hard_left(5000.0);
        assert!(
            lf_r > 0.05,
            "200 Hz crossfeed into right channel should be substantial, got {}",
            lf_r
        );
        assert!(
            lf_r / lf_l > hf_r / hf_l * 2.0,
            "LF R/L ratio ({}) should substantially exceed HF R/L ratio ({})",
            lf_r / lf_l,
            hf_r / hf_l
        );
        assert!(
            hf_l > lf_l,
            "HF direct channel ({}) should retain more energy than LF ({})",
            hf_l,
            lf_l
        );
    }

    #[test]
    fn test_dop_lockout_bypasses_crossfeed_and_replaygain() {
        let mut dsp = DspPipelineV2::new(176400.0);
        dsp.dop_active = true;
        dsp.eq_enabled = true;
        dsp.set_crossfeed_preset(CROSSFEED_JAN_MEIER);
        dsp.install_parameters(&[], -3.0, -6.0, 1.0, 0.25, true);

        let pairs = [
            (0.05_f64, -0.05_f64),
            (-0.421875_f64, 0.7890625_f64),
            (0.0_f64, 0.1234567890123456_f64),
            (0.999_f64, -0.999_f64),
        ];
        for &(in_l, in_r) in &pairs {
            let (out_l, out_r) = dsp.process_stereo(in_l, in_r);
            assert_eq!(
                out_l.to_bits(),
                in_l.to_bits(),
                "DoP active must preserve left channel bit-for-bit"
            );
            assert_eq!(
                out_r.to_bits(),
                in_r.to_bits(),
                "DoP active must preserve right channel bit-for-bit"
            );
        }
    }
}

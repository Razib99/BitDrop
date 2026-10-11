#[cfg(target_os = "android")]
use oboe::{
    AudioApi, AudioOutputCallback, AudioOutputStreamSafe, AudioStream, AudioStreamAsync,
    AudioStreamBase,
    AudioStreamBuilder, DataCallbackResult, Output, PerformanceMode, SharingMode, Stereo,
};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::io::{MediaSource, MediaSourceStream};
use symphonia::core::probe::Hint;
use std::fs::File;
use std::path::PathBuf;
use std::thread;

use crate::cloud::media_source::CloudMediaSource;

lazy_static::lazy_static! {
    static ref PLAYER_STATE: Mutex<PlayerState> = Mutex::new(PlayerState::default());
    static ref CMD_SENDER: Mutex<Option<crossbeam_channel::Sender<DecoderCmd>>> = Mutex::new(None);
    /// Opening a source is slow and belongs off the decode thread; see the
    /// loader thread in `init_engine`.
    static ref LOAD_SENDER: Mutex<Option<crossbeam_channel::Sender<DecoderCmd>>> = Mutex::new(None);
}

/// Bumped on every play request. The loader stamps each open with the value
/// it started under and drops the result if a newer request has landed since,
/// so a slow track that the user already skipped past never takes over.
static LOAD_GENERATION: AtomicU64 = AtomicU64::new(0);

#[cfg(target_os = "android")]
lazy_static::lazy_static! {
    static ref ACTIVE_STREAM: Mutex<Option<AudioStreamAsync<Output, PlayerCallback>>> =
        Mutex::new(None);
    /// A clone of the decode queue's receiving end, kept so the output stream
    /// can be rebuilt without disturbing the decoder. Crossbeam receivers
    /// share one queue, so the new callback picks up exactly where the old
    /// one left off.
    static ref AUDIO_RX: Mutex<Option<crossbeam_channel::Receiver<Vec<f32>>>> = Mutex::new(None);
}

/// Frames the output has asked for. The watchdog watches this and nothing
/// else: a stream that has silently died still reports itself as open, but it
/// stops pulling, and that is the only reliable symptom.
#[cfg(target_os = "android")]
static CONSUMED_FRAMES: AtomicU64 = AtomicU64::new(0);

/// Set from Oboe's error callback. An exclusive low-latency stream is torn
/// down by any routing change — an incoming call, a USB DAC appearing, a
/// Bluetooth connection — and AAudio does not bring it back. Without this the
/// app looks like it is playing, position and all, and makes no sound.
#[cfg(target_os = "android")]
static STREAM_LOST: AtomicBool = AtomicBool::new(false);

/// How many times the output stream has had to be rebuilt. Surfaced to the
/// UI because a recovery is the one thing that explains a brief silence the
/// user did not cause, and because a climbing count means the device is
/// refusing the exclusive path and the engine should be told about it.
static STREAM_RESTARTS: AtomicU64 = AtomicU64::new(0);



#[cfg(not(target_os = "android"))]
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

#[cfg(not(target_os = "android"))]
lazy_static::lazy_static! {
    static ref CPAL_STREAM: Mutex<CpalStreamWrapper> = Mutex::new(CpalStreamWrapper(None));
}

#[cfg(not(target_os = "android"))]
pub struct CpalStreamWrapper(Option<cpal::Stream>);
#[cfg(not(target_os = "android"))]
unsafe impl Send for CpalStreamWrapper {}
#[cfg(not(target_os = "android"))]
unsafe impl Sync for CpalStreamWrapper {}

lazy_static::lazy_static! {

}
#[derive(Clone, Default)]
pub struct PlayerState {
    pub target_sample_rate: u32,
    pub flush_requested: bool,
    pub is_playing: bool,
    pub position_ms: u32,
    pub duration_ms: u32,
    pub current_track_id: String,
    
    pub eq_enabled: bool,
    pub eq_gains: [f32; 10],
    pub eq_preamp: f32,
    pub auto_gain: f32,
    pub eq_updated: bool,

    /// Where the output gain is heading, 0.0 or 1.0.
    ///
    /// Track changes ramp to silence, swap, then ramp back. Cutting straight
    /// from one track's samples to another's puts a step discontinuity into
    /// the stream, which is audible as a click and is worse on good gear.
    pub fade_target: f32,

    /// Gain change per frame, derived from the output rate.
    pub fade_step: f32,

    /// Output is pinned to silence while the engine refills, whatever
    /// `fade_target` says. The two are separate because they answer different
    /// questions: the target is where the ramp is going, the gate is whether
    /// the engine is ready to be heard at all. Starting a track or landing a
    /// seek on an empty queue is what makes playback stutter into life.
    pub gate_output: bool,

    /// A track is being opened. Set the instant the user picks one, before
    /// any network round trip, so the UI can react immediately.
    pub loading: bool,

    /// How far the decoder has read. `position_ms` is this minus the queue,
    /// which is the part the listener has actually heard.
    pub decoded_ms: u32,

    /// True while playback is waiting on the network rather than simply
    /// paused, so the UI can say which it is.
    pub buffering: bool,

    /// Roughly how much decoded audio is queued ahead of the output.
    pub buffered_ms: u32,

    /// What the current track actually is, as the decoder read it. The UI
    /// must never infer these from a filename.
    pub source_codec: String,
    pub source_sample_rate: u32,
    pub source_bits: u32,
    pub source_channels: u32,
}

/// How long a track-change ramp takes. Long enough to read as a deliberate
/// fade rather than a cut, short enough not to hold up the next track.
pub const FADE_MS: u32 = 260;

/// Ramp either side of a seek. Shorter than a track change on purpose: a
/// seek should feel like a jump, not like a transition.
const SEEK_FADE_MS: u32 = 90;

/// Ramp for pausing and for concealing an underrun. Below the threshold
/// where a gain change is heard as anything but a clean stop.
const DUCK_MS: u32 = 30;

/// How much decoded audio to bank before a new track or a landed seek is
/// allowed to be heard. This is the whole difference between "it starts" and
/// "it stutters, then starts".
const PREBUFFER_MS: u32 = 500;

/// Frames of decoded audio the output may run ahead by. Deep enough that
/// opening the next track over the network never starves the current one.
const QUEUE_BUFFERS: usize = 48;

/// Per-frame gain change that walks a ramp of `ms` at `sample_rate`.
fn ramp_step(ms: u32, sample_rate: u32) -> f32 {
    let sr = if sample_rate == 0 { 48000 } else { sample_rate };
    1.0 / (ms.max(1) as f32 * sr as f32 / 1000.0)
}

/// Points the output ramp at `target`, to be reached over `ms`.
fn set_ramp(state: &mut PlayerState, target: f32, ms: u32) {
    state.fade_step = ramp_step(ms, state.target_sample_rate);
    state.fade_target = target;
}


#[derive(Clone, Copy, Default)]
#[flutter_rust_bridge::frb(ignore)]
pub struct Biquad {
    b0: f32, b1: f32, b2: f32,
    a1: f32, a2: f32,
    s1: f32, s2: f32,
}

impl Biquad {
    pub fn process(&mut self, x: f32) -> f32 {
        let y = self.b0 * x + self.s1;
        self.s1 = self.b1 * x - self.a1 * y + self.s2;
        self.s2 = self.b2 * x - self.a2 * y;
        y
    }

    pub fn set_peaking(&mut self, f0: f32, fs: f32, q: f32, db_gain: f32) {
        let w0 = 2.0 * std::f32::consts::PI * f0 / fs;
        let alpha = w0.sin() / (2.0 * q);
        let a = (10.0_f32).powf(db_gain / 40.0);
        
        let a0 = 1.0 + alpha / a;
        self.b0 = (1.0 + alpha * a) / a0;
        self.b1 = (-2.0 * w0.cos()) / a0;
        self.b2 = (1.0 - alpha * a) / a0;
        self.a1 = (-2.0 * w0.cos()) / a0;
        self.a2 = (1.0 - alpha / a) / a0;
    }
}

#[flutter_rust_bridge::frb(ignore)]
pub struct GraphicEq {
    preamp_linear: f32,
    bands_left: [Biquad; 10],
    bands_right: [Biquad; 10],
    freqs: [f32; 10],
    q: f32,
    sample_rate: f32,
}

impl GraphicEq {
    pub fn new(sample_rate: f32) -> Self {
        GraphicEq {
            bands_left: [Biquad::default(); 10],
            bands_right: [Biquad::default(); 10],
            freqs: [31.5, 63.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0],
            q: 1.414,
            sample_rate,
            preamp_linear: 1.0,
        }
    }

    pub fn update_gains(&mut self, gains: &[f32; 10], preamp_db: f32) {
        self.preamp_linear = (10.0_f32).powf(preamp_db / 20.0);
        for i in 0..10 {
            let mut bl = self.bands_left[i];
            let mut br = self.bands_right[i];
            
            bl.set_peaking(self.freqs[i], self.sample_rate, self.q, gains[i]);
            br.set_peaking(self.freqs[i], self.sample_rate, self.q, gains[i]);
            
            self.bands_left[i] = bl;
            self.bands_right[i] = br;
        }
    }

    pub fn process_stereo(&mut self, mut left: f32, mut right: f32) -> (f32, f32) {
        left *= self.preamp_linear;
        right *= self.preamp_linear;
        for i in 0..10 {
            left = self.bands_left[i].process(left);
            right = self.bands_right[i].process(right);
        }
        (left, right)
    }
}

pub enum DecoderCmd {
    Play(String), // local file path
    /// A track streamed from cloud storage over HTTP byte ranges. The decode
    /// thread builds the `CloudMediaSource` itself, so no Rust handle has to
    /// cross the FFI boundary and Dart never owns a decoder resource.
    PlayCloud {
        file_id: String,
        url: String,
        auth_token: Option<String>,
        total_size: u64,
        cache_dir: String,
        ext: String,
    },
    Pause,
    Resume,
    Seek(u32), // ms
    Stop,
}


/// A decoder set up and ready to pull packets from.
struct OpenedTrack {
    format: Box<dyn symphonia::core::formats::FormatReader>,
    decoder: Box<dyn symphonia::core::codecs::Decoder>,
    track_id: u32,
    sample_rate: u32,
    time_base: Option<symphonia::core::units::TimeBase>,
    duration_ms: u32,
    codec: String,
    bits_per_sample: u32,
    channels: u32,
}

/// Probes any `MediaSource` and builds a decoder for its default track.
///
/// Local files and cloud byte-range streams differ only in how the source is
/// constructed, so both go through here, which keeps seeking, gapless and
/// duration handling identical whatever the track is being read from.
fn open_media_source(source: Box<dyn MediaSource>, ext: &str) -> Option<OpenedTrack> {
    let mut hint = Hint::new();
    if !ext.is_empty() {
        hint.with_extension(ext);
    }

    let mss = MediaSourceStream::new(source, Default::default());
    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &Default::default(), &Default::default())
        .ok()?;

    let mut format = probed.format;
    let track = format.default_track().cloned()?;
    let sample_rate = track.codec_params.sample_rate.unwrap_or(44100);
    let time_base = track.codec_params.time_base;

    let decoder = symphonia::default::get_codecs()
        .make(&track.codec_params, &DecoderOptions { verify: true })
        .ok()?;

    // `frac` is a fraction of a second in 0.0..1.0, so it must be scaled
    // before truncation. Casting it to an integer first always yielded 0 and
    // silently rounded every duration down to a whole second.
    let duration_ms = match (track.codec_params.n_frames, time_base) {
        (Some(frames), Some(t)) => {
            let time = t.calc_time(frames);
            (time.seconds * 1000 + (time.frac * 1000.0) as u64) as u32
        }
        _ => 0,
    };

    // Taken from the decoder, not guessed from the file name: this is what
    // the signal path reports as the source format.
    let codec = symphonia::default::get_codecs()
        .get_codec(track.codec_params.codec)
        .map(|d| d.short_name.to_uppercase())
        .unwrap_or_else(|| "UNKNOWN".to_string());

    Some(OpenedTrack {
        format,
        decoder,
        track_id: track.id,
        sample_rate,
        time_base,
        duration_ms,
        codec,
        bits_per_sample: track.codec_params.bits_per_sample.unwrap_or(0),
        channels: track
            .codec_params
            .channels
            .map(|c| c.count() as u32)
            .unwrap_or(2),
    })
}

#[cfg(target_os = "android")]
struct PlayerCallback {
    receiver: crossbeam_channel::Receiver<Vec<f32>>,
    current_buffer: Vec<f32>,
    buffer_idx: usize,
    eq: GraphicEq,
    /// Survives across callbacks: a ramp spans several buffers.
    fade_gain: f32,
    /// Underrun concealment, multiplied with `fade_gain`. Kept separate so a
    /// dropout never disturbs the musical fade in progress around it.
    duck: f32,
    /// The last frame written. An underrun decays this to silence instead of
    /// writing a hard zero, which would be a click.
    last: (f32, f32),
}

#[cfg(target_os = "android")]
impl AudioOutputCallback for PlayerCallback {
    // Oboe hands stereo f32 frames over as (left, right) pairs, not as an
    // interleaved flat slice. The decoder's buffers are interleaved, so this
    // callback is where the two representations meet.
    type FrameType = (f32, Stereo);

    /// Oboe has already torn the stream down by the time this runs, so there
    /// is nothing to salvage here — just record it and let the watchdog in
    /// `init_engine` rebuild, off the callback thread.
    fn on_error_after_close(
        &mut self,
        _stream: &mut dyn AudioOutputStreamSafe,
        error: oboe::Error,
    ) {
        eprintln!("[bitdrop] output stream lost: {:?}", error);
        STREAM_LOST.store(true, Ordering::SeqCst);
    }

    fn on_audio_ready(
        &mut self,
        _stream: &mut dyn AudioOutputStreamSafe,
        audio_data: &mut [(f32, f32)],
    ) -> DataCallbackResult {
        // Proof of life for the watchdog, recorded before anything that
        // could return early.
        CONSUMED_FRAMES.fetch_add(audio_data.len() as u64, Ordering::Relaxed);

        // One short lock, then nothing else blocking: this runs on the
        // real-time audio thread and must not allocate or wait.
        let (is_playing, eq_enabled, eq_updated, gains, preamp, fade_target, fade_step, gated,
             flush, rate) = {
            let mut state = PLAYER_STATE.lock().unwrap();
            let up = state.eq_updated;
            state.eq_updated = false;
            let flush = state.flush_requested;
            state.flush_requested = false;
            (
                state.is_playing,
                state.eq_enabled,
                up,
                state.eq_gains,
                state.eq_preamp,
                state.fade_target,
                state.fade_step,
                state.gate_output,
                flush,
                state.target_sample_rate,
            )
        };

        if eq_updated {
            self.eq.update_gains(&gains, preamp);
        }

        if flush {
            self.current_buffer.clear();
            self.buffer_idx = 0;
            while self.receiver.try_recv().is_ok() {}
        }

        // Where the gain is heading this callback, and how fast. Pausing and
        // gating both mean silence, but they should not sound the same: a
        // pause is a quick clean stop, while a gated swap keeps whatever
        // musical ramp the track change asked for.
        let (want, step) = if !is_playing {
            (0.0, ramp_step(DUCK_MS, rate))
        } else if gated {
            (0.0, fade_step)
        } else {
            (fade_target, fade_step)
        };

        // Already silent and meant to stay that way: leave the queue alone so
        // it can refill, rather than draining audio nobody will hear.
        if want <= 0.0 && self.fade_gain <= 0.0 {
            for frame in audio_data.iter_mut() {
                *frame = (0.0, 0.0);
            }
            return DataCallbackResult::Continue;
        }

        let duck_step = ramp_step(DUCK_MS, rate);

        for frame in audio_data.iter_mut() {
            // Refill from the decoder when the current buffer runs out. A
            // miss is an underrun: decay the last frame to silence instead of
            // slamming to zero, which is what a dropout clicks on.
            if self.buffer_idx + 1 >= self.current_buffer.len() {
                match self.receiver.try_recv() {
                    Ok(next) => {
                        self.current_buffer = next;
                        self.buffer_idx = 0;
                    }
                    Err(_) => {
                        self.duck = (self.duck - duck_step).max(0.0);
                        let g = self.fade_gain * self.duck;
                        *frame = (self.last.0 * g, self.last.1 * g);
                        continue;
                    }
                }
            }

            let mut l = self.current_buffer[self.buffer_idx];
            let mut r = self.current_buffer[self.buffer_idx + 1];
            self.buffer_idx += 2;

            if eq_enabled {
                let (pl, pr) = self.eq.process_stereo(l, r);
                l = pl;
                r = pr;
            }

            if self.fade_gain < want {
                self.fade_gain = (self.fade_gain + step).min(want);
            } else if self.fade_gain > want {
                self.fade_gain = (self.fade_gain - step).max(want);
            }
            // Come back from a dropout over a few milliseconds rather than
            // snapping to full level.
            self.duck = (self.duck + duck_step).min(1.0);

            self.last = (l, r);
            let g = self.fade_gain * self.duck;
            *frame = (l * g, r * g);
        }

        DataCallbackResult::Continue
    }
}

pub fn init_engine() {
    {
        // Derived defaults: a zeroed fade target would mute the output for
        // good, since the ramp would have nowhere to go.
        let mut state = PLAYER_STATE.lock().unwrap();
        state.fade_target = 1.0;
        state.fade_step = ramp_step(FADE_MS, 48000);
    }

    let (cmd_tx, cmd_rx) = crossbeam_channel::unbounded::<DecoderCmd>();
    *CMD_SENDER.lock().unwrap() = Some(cmd_tx);

    let (load_tx, load_rx) = crossbeam_channel::unbounded::<DecoderCmd>();
    *LOAD_SENDER.lock().unwrap() = Some(load_tx);
    let (loaded_tx, loaded_rx) =
        crossbeam_channel::bounded::<(u64, String, Box<OpenedTrack>)>(2);

    let (audio_tx, audio_rx) = crossbeam_channel::bounded::<Vec<f32>>(QUEUE_BUFFERS);

    #[cfg(not(target_os = "android"))]
    {
        let host = cpal::default_host();
        if let Some(device) = host.default_output_device() {
            if let Ok(config) = device.default_output_config() {
                let sample_format = config.sample_format();
                let config: cpal::StreamConfig = config.into();
                PLAYER_STATE.lock().unwrap().target_sample_rate = config.sample_rate.0;
                let channels = config.channels as usize;
                
                let mut current_buffer: Vec<f32> = Vec::new();
                let mut buffer_idx = 0;
                let mut eq = GraphicEq::new(config.sample_rate.0 as f32);
                // Live across callbacks: a ramp spans several buffers.
                let mut fade_gain: f32 = 1.0;
                let mut duck: f32 = 1.0;
                let mut last: (f32, f32) = (0.0, 0.0);
                let rate = config.sample_rate.0;
                let duck_step = ramp_step(DUCK_MS, rate);

                let stream = device.build_output_stream(
                    &config,
                    move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                        let (is_playing, eq_enabled, eq_updated, gains, preamp,
                             fade_target, fade_step, gated, flush) = {
                            let mut state = PLAYER_STATE.lock().unwrap();
                            let up = state.eq_updated;
                            state.eq_updated = false;
                            let flush = state.flush_requested;
                            state.flush_requested = false;
                            (state.is_playing, state.eq_enabled, up, state.eq_gains,
                             state.eq_preamp, state.fade_target, state.fade_step,
                             state.gate_output, flush)
                        };

                        if eq_updated {
                            eq.update_gains(&gains, preamp);
                        }

                        if flush {
                            current_buffer.clear();
                            buffer_idx = 0;
                            while audio_rx.try_recv().is_ok() {}
                        }

                        // See the Oboe callback: same three-way decision
                        // between paused, gated and playing.
                        let (want, step) = if !is_playing {
                            (0.0, duck_step)
                        } else if gated {
                            (0.0, fade_step)
                        } else {
                            (fade_target, fade_step)
                        };

                        if want <= 0.0 && fade_gain <= 0.0 {
                            for sample in data.iter_mut() { *sample = 0.0; }
                            return;
                        }

                        let mut out_idx = 0;
                        while out_idx < data.len() {
                            if buffer_idx >= current_buffer.len() {
                                if let Ok(new_buf) = audio_rx.try_recv() {
                                    current_buffer = new_buf;
                                    buffer_idx = 0;
                                } else {
                                    // Underrun: decay the last frame out
                                    // rather than cutting to a hard zero.
                                    while out_idx < data.len() {
                                        duck = (duck - duck_step).max(0.0);
                                        let g = fade_gain * duck;
                                        data[out_idx] = last.0 * g;
                                        if channels > 1 { data[out_idx + 1] = last.1 * g; }
                                        out_idx += channels;
                                    }
                                    break;
                                }
                            }
                            
                            let mut frames_to_process = (current_buffer.len() - buffer_idx) / channels;
                            let frames_available_in_out = (data.len() - out_idx) / channels;
                            
                            let frames = std::cmp::min(frames_to_process, frames_available_in_out);
                            
                            for _ in 0..frames {
                                let mut l = current_buffer[buffer_idx];
                                let mut r = if channels > 1 { current_buffer[buffer_idx + 1] } else { l };
                                
                                if eq_enabled {
                                    let (fl, fr) = eq.process_stereo(l, r);
                                    l = fl;
                                    r = fr;
                                }

                                // Per-frame ramp toward the target. Applied
                                // last so it also smooths any EQ transient.
                                if fade_gain < want {
                                    fade_gain = (fade_gain + step).min(want);
                                } else if fade_gain > want {
                                    fade_gain = (fade_gain - step).max(want);
                                }
                                duck = (duck + duck_step).min(1.0);

                                last = (l, r);
                                let g = fade_gain * duck;
                                data[out_idx] = l * g;
                                if channels > 1 {
                                    data[out_idx + 1] = r * g;
                                }
                                
                                out_idx += channels;
                                buffer_idx += 2; // Our symphonia buffer is always stereo
                            }
                        }
                    },
                    |err| eprintln!("an error occurred on stream: {}", err),
                    None // None means blocking isn't timed out.
                );
                
                if let Ok(stream) = stream {
                    let _ = stream.play();
                    CPAL_STREAM.lock().unwrap().0 = Some(stream);
                }
            }
        }
    }


    #[cfg(target_os = "android")]
    {
        *AUDIO_RX.lock().unwrap() = Some(audio_rx.clone());
        open_output_stream();
        start_stream_watchdog();
    }

    // Opening a source means a container probe and, for a cloud track, a
    // network round trip — anywhere from a moment to a couple of seconds.
    // Doing that on the decode thread stops the audio it is still feeding,
    // and that stop *is* the gap between tracks. Here the old track plays on
    // until the new one is genuinely ready to take over, so the only silence
    // the listener gets is the fade that was asked for.
    thread::spawn(move || {
        while let Ok(cmd) = load_rx.recv() {
            let generation = LOAD_GENERATION.load(Ordering::SeqCst);

            let opened = match cmd {
                DecoderCmd::Play(path) => {
                    let ext = std::path::Path::new(&path)
                        .extension()
                        .and_then(|e| e.to_str())
                        .unwrap_or("")
                        .to_string();
                    match File::open(&path) {
                        Ok(file) => open_media_source(Box::new(file), &ext).map(|t| (path, t)),
                        Err(e) => {
                            eprintln!("[bitdrop] could not open {}: {}", path, e);
                            None
                        }
                    }
                }
                DecoderCmd::PlayCloud {
                    file_id,
                    url,
                    auth_token,
                    total_size,
                    cache_dir,
                    ext,
                } => match CloudMediaSource::new(
                    file_id.clone(),
                    url,
                    auth_token,
                    total_size,
                    PathBuf::from(cache_dir),
                ) {
                    Ok(source) => {
                        open_media_source(Box::new(source), &ext).map(|t| (file_id, t))
                    }
                    Err(e) => {
                        eprintln!("[bitdrop] could not open cloud track {}: {}", file_id, e);
                        None
                    }
                },
                _ => None,
            };

            // A newer request landed while this one was opening. The user is
            // waiting on that one, so this result is dead weight.
            if generation != LOAD_GENERATION.load(Ordering::SeqCst) {
                continue;
            }

            match opened {
                Some((id, track)) => {
                    let _ = loaded_tx.send((generation, id, Box::new(track)));
                }
                None => {
                    // Nothing is coming to lift the gate, so lift it here.
                    // Otherwise a failed open leaves the output muted for good.
                    let mut state = PLAYER_STATE.lock().unwrap();
                    state.loading = false;
                    state.gate_output = false;
                    set_ramp(&mut state, 1.0, FADE_MS);
                }
            }
        }
    });

    thread::spawn(move || {
        let mut current_format: Option<Box<dyn symphonia::core::formats::FormatReader>> = None;
        let mut current_decoder: Option<Box<dyn symphonia::core::codecs::Decoder>> = None;
        let mut current_track_id: u32 = 0;
        let mut tb: Option<symphonia::core::units::TimeBase> = None;

        // A decoded buffer the queue had no room for yet. Holding it here,
        // rather than blocking in `send`, is what keeps Pause and Seek
        // responsive when the output is running several seconds ahead.
        let mut pending_out: Option<Vec<f32>> = None;

        /// Consecutive failed reads before a track is given up on. Enough to
        /// ride out a dropped connection, few enough that a genuinely broken
        /// source does not hang playback.
        const MAX_READ_FAILURES: u32 = 5;
        let mut read_failures: u32 = 0;

        loop {
            // Drain everything queued so a burst can be collapsed: dragging
            // the slider emits a seek per frame and only the last one is a
            // destination worth paying a network round trip for.
            let mut pending: Vec<DecoderCmd> = Vec::new();
            while let Ok(cmd) = cmd_rx.try_recv() {
                pending.push(cmd);
            }
            let last_seek = pending
                .iter()
                .rposition(|c| matches!(c, DecoderCmd::Seek(_)));
            let pending: Vec<DecoderCmd> = pending
                .into_iter()
                .enumerate()
                .filter(|(i, c)| !matches!(c, DecoderCmd::Seek(_)) || Some(*i) == last_seek)
                .map(|(_, c)| c)
                .collect();

            for cmd in pending {
                match cmd {
                    // Play and PlayCloud are handled by the loader thread;
                    // they never reach here.
                    DecoderCmd::Play(_) | DecoderCmd::PlayCloud { .. } => {}
                    DecoderCmd::Pause => {
                        PLAYER_STATE.lock().unwrap().is_playing = false;
                    }
                    DecoderCmd::Resume => {
                        let mut state = PLAYER_STATE.lock().unwrap();
                        // Ramp back rather than reappearing at full level.
                        set_ramp(&mut state, 1.0, DUCK_MS * 3);
                        state.is_playing = true;
                    }
                    DecoderCmd::Seek(ms) => {
                        // The ramp is already running: engine_seek starts it
                        // on the caller's thread so it begins the moment the
                        // finger lifts, not after this thread gets scheduled.
                        let was_playing = PLAYER_STATE.lock().unwrap().is_playing;
                        if was_playing {
                            thread::sleep(Duration::from_millis(SEEK_FADE_MS as u64 + 20));
                        }

                        pending_out = None;
                        {
                            let mut state = PLAYER_STATE.lock().unwrap();
                            state.flush_requested = true;
                            state.buffered_ms = 0;
                            state.position_ms = ms;
                            state.decoded_ms = ms;
                            // Landing on an empty queue is exactly what makes
                            // a seek stutter into life. Refill first.
                            state.gate_output = true;
                            set_ramp(&mut state, 1.0, SEEK_FADE_MS);
                        }

                        if let (Some(format), Some(t)) = (current_format.as_mut(), tb) {
                            let ts = (ms as u64 * t.denom as u64) / (1000 * t.numer as u64);
                            let _ = format.seek(
                                symphonia::core::formats::SeekMode::Coarse,
                                symphonia::core::formats::SeekTo::TimeStamp {
                                    ts,
                                    track_id: current_track_id,
                                },
                            );
                            // The decoder is mid-stream after a jump; without
                            // this the first packets decode to garbage.
                            if let Some(d) = current_decoder.as_mut() {
                                d.reset();
                            }
                        } else {
                            PLAYER_STATE.lock().unwrap().gate_output = false;
                        }
                    }
                    DecoderCmd::Stop => {
                        current_format = None;
                        current_decoder = None;
                        pending_out = None;
                        let mut state = PLAYER_STATE.lock().unwrap();
                        state.is_playing = false;
                        state.gate_output = false;
                        state.buffering = false;
                        state.loading = false;
                    }
                }
            }

            // A freshly opened track takes over here, and only here: by this
            // point every byte it needs to start is already in hand, so the
            // swap costs a fade rather than a gap.
            if let Ok((generation, id, opened)) = loaded_rx.try_recv() {
                if generation == LOAD_GENERATION.load(Ordering::SeqCst) {
                    let was_playing = {
                        let mut state = PLAYER_STATE.lock().unwrap();
                        let playing = state.is_playing;
                        if playing {
                            set_ramp(&mut state, 0.0, FADE_MS);
                        }
                        playing
                    };
                    // The callback owns the ramp; this just waits it out so
                    // the outgoing track is at silence before it is cut.
                    if was_playing {
                        thread::sleep(Duration::from_millis(FADE_MS as u64 + 30));
                    }

                    let opened = *opened;
                    tb = opened.time_base;
                    current_track_id = opened.track_id;
                    current_decoder = Some(opened.decoder);
                    current_format = Some(opened.format);
                    pending_out = None;

                    let mut state = PLAYER_STATE.lock().unwrap();
                    state.flush_requested = true;
                    state.is_playing = true;
                    state.loading = false;
                    state.position_ms = 0;
                    state.decoded_ms = 0;
                    state.buffered_ms = 0;
                    state.duration_ms = opened.duration_ms;
                    state.current_track_id = id;
                    state.source_codec = opened.codec;
                    state.source_sample_rate = opened.sample_rate;
                    state.source_bits = opened.bits_per_sample;
                    state.source_channels = opened.channels;
                    state.gate_output = true;
                    set_ramp(&mut state, 1.0, FADE_MS);
                }
            }

            let is_playing = PLAYER_STATE.lock().unwrap().is_playing;
            if !is_playing || current_format.is_none() {
                thread::sleep(Duration::from_millis(20));
                continue;
            }

            // Deliver whatever last round decoded before pulling more. A
            // short timeout keeps this loop coming back for commands instead
            // of parking inside a blocking send.
            if let Some(buf) = pending_out.take() {
                match audio_tx.send_timeout(buf, Duration::from_millis(20)) {
                    Ok(()) => {}
                    Err(crossbeam_channel::SendTimeoutError::Timeout(back)) => {
                        pending_out = Some(back);
                        continue;
                    }
                    Err(_) => {}
                }
            }

            if let (Some(format), Some(decoder)) = (current_format.as_mut(), current_decoder.as_mut()) {
                // A cloud read that fails is not the end of the track. Range
                // requests time out, tokens expire and connections drop, and
                // treating any of those as EOF is how a song silently stops
                // half way through. Only a genuine short read is the end.
                let next = format.next_packet();
                let ended = match &next {
                    Ok(_) => {
                        read_failures = 0;
                        false
                    }
                    Err(symphonia::core::errors::Error::IoError(e))
                        if e.kind() == std::io::ErrorKind::UnexpectedEof =>
                    {
                        true
                    }
                    Err(e) => {
                        read_failures += 1;
                        eprintln!(
                            "[bitdrop] read failed ({}/{}): {}",
                            read_failures, MAX_READ_FAILURES, e
                        );
                        if read_failures < MAX_READ_FAILURES {
                            // Back off and let the source try the range
                            // request again on the next pass.
                            thread::sleep(Duration::from_millis(400));
                            continue;
                        }
                        true
                    }
                };

                if let Ok(packet) = next {
                    if packet.track_id() == current_track_id {
                        if let Ok(audio_buf) = decoder.decode(&packet) {
                            let target_sr = PLAYER_STATE.lock().unwrap().target_sample_rate;
                            let track_sr = audio_buf.spec().rate;
                            let mut channels = audio_buf.spec().channels.count();

                            let mut sample_buf = SampleBuffer::<f32>::new(audio_buf.capacity() as u64, *audio_buf.spec());
                            sample_buf.copy_interleaved_ref(audio_buf);
                            
                            let mut samples = sample_buf.samples().to_vec();
                            
                            // DOWNMIX TO STEREO
                            if channels == 1 {
                                let mut stereo = Vec::with_capacity(samples.len() * 2);
                                for s in samples {
                                    stereo.push(s);
                                    stereo.push(s);
                                }
                                samples = stereo;
                                channels = 2;
                            } else if channels > 2 {
                                let mut stereo = Vec::with_capacity((samples.len() / channels) * 2);
                                for i in 0..(samples.len() / channels) {
                                    let fl = samples[i * channels];
                                    let fr = samples[i * channels + 1];
                                    let fc = samples[i * channels + 2]; // Usually Center
                                    
                                    // Mix center channel into L and R, attenuate to avoid clipping
                                    stereo.push((fl + fc * 0.707) * 0.8);
                                    stereo.push((fr + fc * 0.707) * 0.8);
                                }
                                samples = stereo;
                                channels = 2;
                            }
                            
                            if track_sr != target_sr && target_sr > 0 && channels > 0 {
                                let ratio = track_sr as f32 / target_sr as f32;
                                let out_frames = ((samples.len() / channels) as f32 / ratio) as usize;
                                let mut resampled = Vec::with_capacity(out_frames * channels);
                                
                                for i in 0..out_frames {
                                    let in_idx = (i as f32 * ratio) as usize;
                                    let in_idx = in_idx.min((samples.len() / channels).saturating_sub(1));
                                    for c in 0..channels {
                                        resampled.push(samples[in_idx * channels + c]);
                                    }
                                }
                                samples = resampled;
                            }
                            
                            // Queue depth is the honest measure of how much
                            // runway the output has before it starves.
                            let frames = samples.len() / 2;
                            pending_out = Some(samples);

                            {
                                let mut state = PLAYER_STATE.lock().unwrap();
                                let sr = if state.target_sample_rate == 0 {
                                    48000
                                } else {
                                    state.target_sample_rate
                                };
                                let queued_frames =
                                    (audio_tx.len() as u64 + 1) * frames as u64;
                                state.buffered_ms =
                                    ((queued_frames * 1000) / sr as u64) as u32;
                                // Waiting on the network with little runway is
                                // buffering; a fetch with a healthy queue is
                                // just prefetching and must not say so.
                                state.buffering = crate::cloud::media_source::fetches_in_flight() > 0
                                    && state.buffered_ms < 500;

                                // Enough banked to be heard without stuttering.
                                if state.gate_output && state.buffered_ms >= PREBUFFER_MS {
                                    state.gate_output = false;
                                }

                                // What is audible, not what has been decoded:
                                // the queue runs seconds ahead of the output,
                                // and a progress bar that reports the decoder
                                // makes every seek land in the wrong place.
                                if let Some(t) = tb {
                                    let time = t.calc_time(packet.ts());
                                    let decoded = (time.seconds * 1000
                                        + (time.frac * 1000.0) as u64)
                                        as u32;
                                    state.decoded_ms = decoded;
                                    state.position_ms =
                                        decoded.saturating_sub(state.buffered_ms);
                                }
                            }
                        }
                    }
                } else if ended {
                    // End of track, or a read that failed past retrying.
                    // Clear every flag that would otherwise leave the UI
                    // reporting a stall that nothing will ever resolve: the
                    // gate, because nothing is left to lift it, and the
                    // buffering flag, because it is only ever refreshed from
                    // inside this loop.
                    read_failures = 0;
                    let mut state = PLAYER_STATE.lock().unwrap();
                    state.is_playing = false;
                    state.gate_output = false;
                    state.buffering = false;
                    state.buffered_ms = 0;
                    drop(state);
                    current_format = None;
                    current_decoder = None;
                }
            }
        }
    });
}

/// Builds and starts the output stream, replacing any existing one.
///
/// Oboe's builder is type-state: each setter consumes the builder and returns
/// a differently-typed one, so this has to be a single chain. `set_callback`
/// only becomes available once direction, channels and format are fixed, and
/// it checks them against the callback's `FrameType`.
#[cfg(target_os = "android")]
fn open_output_stream() {
    let rx = match AUDIO_RX.lock().unwrap().clone() {
        Some(rx) => rx,
        None => return,
    };

    fn make_callback(rx: crossbeam_channel::Receiver<Vec<f32>>) -> PlayerCallback {
        PlayerCallback {
            receiver: rx,
            current_buffer: Vec::new(),
            buffer_idx: 0,
            // The decoder resamples to the stream rate before sending, so
            // the filters are designed for the output rate.
            eq: GraphicEq::new(48000.0),
            // A rebuilt stream starts silent and ramps in, so a recovery is
            // heard as a fade rather than a bang.
            fade_gain: 0.0,
            duck: 1.0,
            last: (0.0, 0.0),
        }
    }

    // Drop the old stream first: holding two exclusive streams open is
    // exactly what AAudio refuses.
    *ACTIVE_STREAM.lock().unwrap() = None;

    // Exclusive + LowLatency is the path worth having: it is what gets
    // closest to the hardware. Oboe may silently downgrade sharing mode, so
    // a failure here is not fatal.
    let opened = AudioStreamBuilder::default()
        .set_performance_mode(PerformanceMode::LowLatency)
        .set_sharing_mode(SharingMode::Exclusive)
        .set_audio_api(AudioApi::AAudio)
        .set_output()
        .set_stereo()
        .set_f32()
        .set_callback(make_callback(rx.clone()))
        .open_stream();

    let opened = match opened {
        Ok(stream) => Some(stream),
        Err(e) => {
            eprintln!(
                "[bitdrop] exclusive stream unavailable ({e:?}); falling back to shared"
            );
            // Shared mode with no low-latency demand works on far more
            // devices, including every pre-Android-14 phone.
            AudioStreamBuilder::default()
                .set_performance_mode(PerformanceMode::None)
                .set_sharing_mode(SharingMode::Shared)
                .set_output()
                .set_stereo()
                .set_f32()
                .set_callback(make_callback(rx))
                .open_stream()
                .map_err(|e| eprintln!("[bitdrop] no audio output: {e:?}"))
                .ok()
        }
    };

    if let Some(mut stream) = opened {
        let rate = stream.get_sample_rate() as u32;
        {
            let mut state = PLAYER_STATE.lock().unwrap();
            state.target_sample_rate = rate;
            // The new callback starts at zero gain; give it somewhere to go.
            set_ramp(&mut state, 1.0, FADE_MS);
        }
        let _ = stream.start();
        *ACTIVE_STREAM.lock().unwrap() = Some(stream);
        STREAM_LOST.store(false, Ordering::SeqCst);
        STREAM_RESTARTS.fetch_add(1, Ordering::Relaxed);
    }
}

/// Watches for an output stream that has stopped pulling and rebuilds it.
///
/// A disconnected AAudio stream is the single most common way for this app to
/// go silent while looking perfectly healthy: the decoder keeps running, the
/// position keeps advancing, the notification still says playing, and no
/// sound comes out. Oboe reports some of these through `on_error_after_close`
/// and simply stops calling back for the rest, so the frame counter is the
/// authority — if the output has not asked for a sample in a second while
/// playback is live, the stream is gone whatever it claims.
#[cfg(target_os = "android")]
fn start_stream_watchdog() {
    thread::spawn(|| {
        let mut last_frames = CONSUMED_FRAMES.load(Ordering::Relaxed);
        let mut stalled_ticks = 0u32;
        loop {
            thread::sleep(Duration::from_millis(500));

            if STREAM_LOST.load(Ordering::SeqCst) {
                eprintln!("[bitdrop] reopening output stream after loss");
                open_output_stream();
                last_frames = CONSUMED_FRAMES.load(Ordering::Relaxed);
                stalled_ticks = 0;
                continue;
            }

            let playing = PLAYER_STATE.lock().unwrap().is_playing;
            let frames = CONSUMED_FRAMES.load(Ordering::Relaxed);

            if playing && frames == last_frames {
                stalled_ticks += 1;
                // Two ticks, so a single scheduling hiccup does not tear down
                // a working stream.
                if stalled_ticks >= 2 {
                    eprintln!("[bitdrop] output stalled; reopening stream");
                    open_output_stream();
                    stalled_ticks = 0;
                }
            } else {
                stalled_ticks = 0;
            }
            last_frames = frames;
        }
    });
}

/// Hands a track to the loader thread.
///
/// Deliberately does not touch the ramp: the track already playing carries on
/// until the new one is open and ready, and only then is it faded out. Fading
/// here instead would put the whole open — a probe, and for cloud tracks a
/// network round trip — into audible silence.
fn request_load(cmd: DecoderCmd) {
    LOAD_GENERATION.fetch_add(1, Ordering::SeqCst);
    PLAYER_STATE.lock().unwrap().loading = true;
    if let Some(sender) = LOAD_SENDER.lock().unwrap().as_ref() {
        let _ = sender.send(cmd);
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn engine_play(path: String) {
    request_load(DecoderCmd::Play(path));
}

/// Plays a track streamed from cloud storage.
///
/// `url` is a direct download endpoint that answers HTTP Range requests, and
/// `auth_token` is the OAuth access token to send as a bearer header. Chunks
/// land in `cache_dir`, so playback survives a dropped connection and a replay
/// costs no further network. `ext` only seeds the format hint.
#[flutter_rust_bridge::frb(sync)]
pub fn engine_play_cloud(
    file_id: String,
    url: String,
    auth_token: Option<String>,
    total_size: u64,
    cache_dir: String,
    ext: String,
) {
    request_load(DecoderCmd::PlayCloud {
        file_id,
        url,
        auth_token,
        total_size,
        cache_dir,
        ext,
    });
}

#[flutter_rust_bridge::frb(sync)]
pub fn engine_pause() {
    if let Some(sender) = CMD_SENDER.lock().unwrap().as_ref() {
        let _ = sender.send(DecoderCmd::Pause);
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn engine_resume() {
    if let Some(sender) = CMD_SENDER.lock().unwrap().as_ref() {
        let _ = sender.send(DecoderCmd::Resume);
    }
}

/// Seeks, fading out and back in around the jump.
///
/// The ramp starts here rather than on the decode thread so it begins the
/// moment the finger lifts; the decode thread then waits it out before it
/// flushes. The ring still holds seconds of audio from before the jump, so
/// without the flush the user hears the old position after landing, and
/// without the ramp cutting the ring mid-waveform clicks.
///
/// `position_ms` is published immediately: the decoder will not confirm the
/// landing until it has read ahead again, and a progress bar that waits for
/// that feels broken.
#[flutter_rust_bridge::frb(sync)]
pub fn engine_seek(position_ms: u32) {
    {
        let mut state = PLAYER_STATE.lock().unwrap();
        state.position_ms = position_ms;
        if state.is_playing {
            set_ramp(&mut state, 0.0, SEEK_FADE_MS);
        }
    }
    if let Some(sender) = CMD_SENDER.lock().unwrap().as_ref() {
        let _ = sender.send(DecoderCmd::Seek(position_ms));
    }
}

/// What the output is waiting on, for the UI's buffering state.
pub struct EngineBufferState {
    /// Playback is stalled on the network, as opposed to merely paused.
    pub buffering: bool,
    /// Decoded audio queued ahead of the output.
    pub buffered_ms: u32,
    /// Byte-range requests currently in flight.
    pub fetches_in_flight: u32,
    /// Bytes pulled from the network this session.
    pub bytes_fetched: u64,
    /// Times the output stream has been opened, including the first. Anything
    /// above one means it was lost and rebuilt.
    pub stream_opens: u32,
}

/// What the engine is really doing with the samples right now.
///
/// Every quality claim the UI makes is built from this. Nothing here is
/// inferred: the source fields come from the decoder and the output rate from
/// the stream the device actually granted.
pub struct EngineOutputState {
    pub source_codec: String,
    pub source_sample_rate: u32,
    pub source_bits: u32,
    pub source_channels: u32,
    /// The rate the output stream was opened at. A mismatch with the source
    /// rate means the engine is resampling.
    pub output_sample_rate: u32,
    /// True when the EQ chain is altering samples.
    pub dsp_active: bool,
    pub has_track: bool,
}

/// A span of the current track that is already on disk.
pub struct CachedRangeMs {
    pub start_ms: u32,
    pub end_ms: u32,
}

/// Which parts of the current track would play without touching the network.
///
/// Byte offsets are mapped to time proportionally. That is exact for the
/// constant-rate formats this matters for and close enough for the rest; it
/// drives a progress bar, not a seek target.
#[flutter_rust_bridge::frb(sync)]
pub fn engine_cached_ranges() -> Vec<CachedRangeMs> {
    let duration_ms = PLAYER_STATE.lock().unwrap().duration_ms as u64;
    if duration_ms == 0 {
        return Vec::new();
    }

    let (total, ranges) = crate::cloud::media_source::cached_byte_ranges();
    if total == 0 {
        return Vec::new();
    }

    ranges
        .into_iter()
        .map(|(start, end)| CachedRangeMs {
            start_ms: ((start * duration_ms) / total) as u32,
            end_ms: ((end * duration_ms) / total) as u32,
        })
        .collect()
}

#[flutter_rust_bridge::frb(sync)]
pub fn engine_output_state() -> EngineOutputState {
    let state = PLAYER_STATE.lock().unwrap();
    EngineOutputState {
        source_codec: state.source_codec.clone(),
        source_sample_rate: state.source_sample_rate,
        source_bits: state.source_bits,
        source_channels: state.source_channels,
        output_sample_rate: state.target_sample_rate,
        // Preamp counts: it is a gain change like any other.
        dsp_active: state.eq_enabled
            && (state.eq_gains.iter().any(|g| *g != 0.0) || state.eq_preamp != 0.0),
        has_track: !state.current_track_id.is_empty(),
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn engine_buffer_state() -> EngineBufferState {
    let state = PLAYER_STATE.lock().unwrap();
    EngineBufferState {
        // All three mean the same thing to a listener: nothing is coming out
        // and the engine is working on it. Opening a source, refilling after
        // a swap or a seek, and stalling on the network are different causes
        // of one state.
        buffering: state.loading || state.gate_output || state.buffering,
        buffered_ms: state.buffered_ms,
        fetches_in_flight: crate::cloud::media_source::fetches_in_flight() as u32,
        bytes_fetched: crate::cloud::media_source::bytes_fetched() as u64,
        stream_opens: stream_opens(),
    }
}

#[cfg(target_os = "android")]
fn stream_opens() -> u32 {
    STREAM_RESTARTS.load(Ordering::Relaxed) as u32
}

/// Desktop keeps one CPAL stream for the life of the process.
#[cfg(not(target_os = "android"))]
fn stream_opens() -> u32 {
    1
}

#[flutter_rust_bridge::frb(sync)]
pub fn engine_get_position() -> u32 {
    PLAYER_STATE.lock().unwrap().position_ms
}

#[flutter_rust_bridge::frb(sync)]
pub fn engine_is_playing() -> bool {
    PLAYER_STATE.lock().unwrap().is_playing
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
    init_engine();
}
pub fn play_audio_file_android(path: String) -> Result<String, String> { Ok("".to_string()) }

#[flutter_rust_bridge::frb(sync)]
pub fn engine_set_eq(gains: Vec<f32>) {
    let mut state = PLAYER_STATE.lock().unwrap();
    for i in 0..10.min(gains.len()) {
        state.eq_gains[i] = gains[i];
    }
    if gains.len() > 10 {
        state.eq_preamp = gains[10];
    } else {
        state.eq_preamp = 0.0;
    }
    state.eq_updated = true;
}

#[flutter_rust_bridge::frb(sync)]
pub fn engine_set_eq_enabled(enabled: bool) {
    let mut state = PLAYER_STATE.lock().unwrap();
    state.eq_enabled = enabled;
}

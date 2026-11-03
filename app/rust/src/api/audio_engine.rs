#[cfg(target_os = "android")]
use oboe::{
    AudioApi, AudioOutputCallback, AudioOutputStreamSafe, AudioStream, AudioStreamAsync,
    AudioStreamBase, AudioStreamBuilder, DataCallbackResult, Output, PerformanceMode, SharingMode,
    Stereo,
};
use std::fs::File;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::Mutex;
use std::thread;
use std::time::Duration;
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::io::{MediaSource, MediaSourceStream};
use symphonia::core::probe::Hint;

use crate::cloud::media_source::CloudMediaSource;
pub use crate::dsp::{
    downmix_to_stereo, BoundaryKind, BoundaryMarker, DspConfigSnapshot, DspPipelineV2, EqBandSpec,
    TripleBuffer, VisualizerFrameData, EQ_HIGH_PASS, EQ_HIGH_SHELF, EQ_LOW_PASS, EQ_LOW_SHELF,
    EQ_PEAK, ISO_10_BAND, MAX_EQ_BANDS,
};
use rubato::Resampler;

/// Capacity for the lock-free audio ring buffer: 768,000 floats (~3MB memory),
/// equivalent to 2 seconds of 192kHz stereo audio or 8 seconds of 48kHz stereo audio.
pub const RING_BUFFER_CAPACITY: usize = 768_000;

/// Capacity for the lock-free boundary event side queue.
pub const BOUNDARY_QUEUE_CAPACITY: usize = 32;

/// Lock-free real-time flags accessed by audio callbacks without mutex contention.
pub static CALLBACK_IS_PLAYING: AtomicBool = AtomicBool::new(false);
pub static CALLBACK_GATE_OUTPUT: AtomicBool = AtomicBool::new(false);
pub static CALLBACK_FLUSH_REQUESTED: AtomicBool = AtomicBool::new(false);
pub static CALLBACK_FADE_TARGET: AtomicU32 = AtomicU32::new(0x3f800000); // 1.0f32
pub static CALLBACK_FADE_STEP: AtomicU32 = AtomicU32::new(0);
pub static CALLBACK_FRAMES_PLAYED: AtomicU64 = AtomicU64::new(0);
pub static DECODER_FRAMES_PUSHED: AtomicU64 = AtomicU64::new(0);
pub static TRACK_ENDED_FLAG: AtomicBool = AtomicBool::new(false);
pub static DECODE_LOAD_PERMILLE: AtomicU32 = AtomicU32::new(0);

lazy_static::lazy_static! {
    /// Lock-free Triple Buffer for zero-allocation, wait-free DSP snapshots.
    pub static ref DSP_TRIPLE_BUFFER: TripleBuffer<DspConfigSnapshot> =
        TripleBuffer::new(DspConfigSnapshot::default());
}

/// Enables hardware Flush-to-Zero (FTZ) and Denormals-are-Zero (DAZ) mode.
/// On ARM64 (Android), this sets bits 24 (FZ) and 19 (DN) of FPCR.
/// On x86_64, this sets FTZ (bit 15) and DAZ (bit 6) flags in MXCSR.
/// Prevents catastrophic CPU denormal microcode exceptions during filter decays and fades.
#[inline(always)]
pub fn enable_hardware_flush_to_zero() {
    #[cfg(target_arch = "aarch64")]
    unsafe {
        let mut fpcr: u64;
        std::arch::asm!("mrs {}, fpcr", out(reg) fpcr, options(nomem, nostack));
        fpcr |= (1 << 24) | (1 << 19);
        std::arch::asm!("msr fpcr, {}", in(reg) fpcr, options(nomem, nostack));
    }
    #[cfg(target_arch = "x86_64")]
    unsafe {
        let mut mxcsr: u32 = 0;
        std::arch::asm!("stmxcsr [{}]", in(reg) &mut mxcsr, options(nostack));
        mxcsr |= 0x8000 | 0x0040;
        std::arch::asm!("ldmxcsr [{}]", in(reg) &mxcsr, options(nostack));
    }
    #[cfg(target_arch = "x86")]
    unsafe {
        let mut mxcsr: u32 = 0;
        std::arch::asm!("stmxcsr [{}]", in(reg) &mut mxcsr, options(nostack));
        mxcsr |= 0x8000 | 0x0040;
        std::arch::asm!("ldmxcsr [{}]", in(reg) &mxcsr, options(nostack));
    }
}

#[derive(Clone, Debug)]
pub enum EngineEvent {
    PlaybackState {
        is_playing: bool,
        is_buffering: bool,
    },
    TrackStarted {
        file_id: String,
    },
    TrackEnded {
        file_id: String,
    },
    PositionUpdate {
        position_ms: u32,
        duration_ms: u32,
    },
    BufferTelemetry {
        buffered_ms: u32,
        fetches_in_flight: u32,
        bytes_fetched: u64,
    },
    LimiterTelemetry {
        gr_millidb: u32,
        clipped_samples: u64,
    },
}

lazy_static::lazy_static! {
    static ref PLAYER_STATE: Mutex<PlayerState> = Mutex::new(PlayerState::default());
    static ref CMD_SENDER: Mutex<Option<crossbeam_channel::Sender<DecoderCmd>>> = Mutex::new(None);
    /// Opening a source is slow and belongs off the decode thread; see the
    /// loader thread in `init_engine`.
    static ref LOAD_SENDER: Mutex<Option<crossbeam_channel::Sender<DecoderCmd>>> = Mutex::new(None);
    static ref EVENT_SINK: Mutex<Option<crate::frb_generated::StreamSink<EngineEvent>>> = Mutex::new(None);
}

/// Bumped on every play request. The loader stamps each open with the value
/// it started under and drops the result if a newer request has landed since,
/// so a slow track that the user already skipped past never takes over.
static LOAD_GENERATION: AtomicU64 = AtomicU64::new(0);

#[cfg(target_os = "android")]
lazy_static::lazy_static! {
    static ref ACTIVE_STREAM: Mutex<Option<AudioStreamAsync<Output, PlayerCallback>>> =
        Mutex::new(None);
    /// Direct consumer handles held across routing changes without mutex contention.
    static ref AUDIO_CONSUMER: Mutex<Option<rtrb::Consumer<f32>>> =
        Mutex::new(None);
    static ref BOUNDARY_CONSUMER: Mutex<Option<rtrb::Consumer<BoundaryMarker>>> =
        Mutex::new(None);
    static ref TRIGGERED_PRODUCER: Mutex<Option<rtrb::Producer<BoundaryMarker>>> =
        Mutex::new(None);
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
#[cfg_attr(not(target_os = "android"), allow(dead_code))]
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

lazy_static::lazy_static! {}
#[derive(Clone, Default)]
pub struct PlayerState {
    pub target_sample_rate: u32,
    pub flush_requested: bool,
    pub is_playing: bool,
    pub position_ms: u32,
    pub duration_ms: u32,
    pub current_track_id: String,
    pub hardware_sample_rate: u32,
    pub hardware_format: String,

    pub eq_enabled: bool,
    pub eq_gains: [f32; 10],
    pub eq_preamp: f32,
    pub eq_specs: Option<Vec<EqBandSpec>>,
    pub auto_gain: f32,
    pub balance: f32,
    pub mono: bool,
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

/// Ramp either side of a seek. Overlapped 20ms raised-cosine / smooth micro-fade
/// across the ring buffer to eliminate pops while keeping seek latency ~120-130ms.
const SEEK_FADE_MS: u32 = 20;

/// Ramp for pausing and for concealing an underrun. Below the threshold
/// where a gain change is heard as anything but a clean stop.
pub const DUCK_MS: u32 = 30;

/// How much decoded audio to bank before a new track or a landed seek is
/// allowed to be heard. This is the whole difference between "it starts" and
/// "it stutters, then starts".
const PREBUFFER_MS: u32 = 500;

/// Per-frame gain change that walks a ramp of `ms` at `sample_rate`.
pub fn ramp_step(ms: u32, sample_rate: u32) -> f32 {
    let sr = if sample_rate == 0 { 48000 } else { sample_rate };
    1.0 / (ms.max(1) as f32 * sr as f32 / 1000.0)
}

/// Points the output ramp at `target`, to be reached over `ms`.
fn set_ramp(state: &mut PlayerState, target: f32, ms: u32) {
    state.fade_step = ramp_step(ms, state.target_sample_rate);
    state.fade_target = target;
    CALLBACK_FADE_TARGET.store(target.to_bits(), Ordering::Relaxed);
    CALLBACK_FADE_STEP.store(state.fade_step.to_bits(), Ordering::Relaxed);
}

/// Publishes the current EQ and DSP configuration into the lock-free Triple Buffer.
pub fn publish_dsp_config(state: &PlayerState) {
    let mut snap = DspConfigSnapshot {
        sample_rate: if state.target_sample_rate > 0 {
            state.target_sample_rate as f64
        } else {
            48000.0
        },
        eq_enabled: state.eq_enabled,
        preamp_db: state.eq_preamp as f64,
        auto_gain: state.auto_gain as f64,
        balance: state.balance as f64,
        mono: state.mono,
        ..Default::default()
    };
    if let Some(specs) = &state.eq_specs {
        snap.is_parametric = true;
        let count = specs.len().min(MAX_EQ_BANDS);
        snap.spec_count = count;
        snap.specs[..count].copy_from_slice(&specs[..count]);
    } else {
        snap.is_parametric = false;
        snap.graphic_gains = state.eq_gains;
    }
    DSP_TRIPLE_BUFFER.publish(snap);
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
    SetNextTrack(String),
    SetNextCloud {
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
    let format_opts = symphonia::core::formats::FormatOptions {
        enable_gapless: true,
        ..Default::default()
    };
    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &format_opts, &Default::default())
        .ok()?;

    let format = probed.format;
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
    renderer: crate::renderer::OutputRenderer,
}

#[cfg(target_os = "android")]
impl Drop for PlayerCallback {
    fn drop(&mut self) {
        if let Some(c) = self.renderer.consumer.take() {
            *AUDIO_CONSUMER.lock().unwrap() = Some(c);
        }
        if let Some(bc) = self.renderer.boundary_consumer.take() {
            *BOUNDARY_CONSUMER.lock().unwrap() = Some(bc);
        }
        if let Some(tp) = self.renderer.triggered_producer.take() {
            *TRIGGERED_PRODUCER.lock().unwrap() = Some(tp);
        }
    }
}

#[cfg(target_os = "android")]
impl AudioOutputCallback for PlayerCallback {
    type FrameType = (f32, Stereo);

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
        CONSUMED_FRAMES.fetch_add(audio_data.len() as u64, Ordering::Relaxed);
        let slice: &mut [f32] = unsafe {
            std::slice::from_raw_parts_mut(
                audio_data.as_mut_ptr() as *mut f32,
                audio_data.len() * 2,
            )
        };
        match self.renderer.render_interleaved(slice, 2) {
            crate::renderer::RenderAction::Continue => DataCallbackResult::Continue,
            crate::renderer::RenderAction::Stop => DataCallbackResult::Stop,
        }
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
    let (loaded_tx, loaded_rx) = crossbeam_channel::bounded::<(u64, String, Box<OpenedTrack>)>(2);

    let (audio_tx, audio_rx) = rtrb::RingBuffer::<f32>::new(RING_BUFFER_CAPACITY);
    let (boundary_tx, boundary_rx) =
        rtrb::RingBuffer::<BoundaryMarker>::new(BOUNDARY_QUEUE_CAPACITY);
    let (triggered_tx, mut triggered_rx) =
        rtrb::RingBuffer::<BoundaryMarker>::new(BOUNDARY_QUEUE_CAPACITY);
    let (next_loaded_tx, next_loaded_rx) =
        crossbeam_channel::bounded::<(String, Box<OpenedTrack>)>(1);

    #[cfg(not(target_os = "android"))]
    {
        let host = cpal::default_host();
        if let Some(device) = host.default_output_device() {
            if let Ok(config) = device.default_output_config() {
                let _sample_format = config.sample_format();
                let config: cpal::StreamConfig = config.into();
                PLAYER_STATE.lock().unwrap().target_sample_rate = config.sample_rate.0;
                let channels = config.channels as usize;

                let mut renderer = crate::renderer::OutputRenderer::new(
                    config.sample_rate.0 as f64,
                    Some(audio_rx),
                    Some(boundary_rx),
                    Some(triggered_tx),
                );

                let stream = device.build_output_stream(
                    &config,
                    move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                        let _ = renderer.render_interleaved(data, channels);
                    },
                    |err| eprintln!("an error occurred on stream: {}", err),
                    None,
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
        *AUDIO_CONSUMER.lock().unwrap() = Some(audio_rx);
        *BOUNDARY_CONSUMER.lock().unwrap() = Some(boundary_rx);
        *TRIGGERED_PRODUCER.lock().unwrap() = Some(triggered_tx);
        open_output_stream(None);
        start_stream_watchdog();
    }

    // Control Thread: drains triggered boundaries and pushes reactive EngineEvents to Dart via StreamSink
    thread::spawn(move || {
        let mut last_playing = false;
        let mut last_buffering = false;
        let mut tick_count: u32 = 0;

        loop {
            thread::sleep(Duration::from_millis(50));
            tick_count = tick_count.wrapping_add(1);

            // 1. Drain triggered boundary events from audio callback
            while triggered_rx.slots() > 0 {
                if let Ok(chunk) = triggered_rx.read_chunk(1) {
                    let marker = chunk.as_slices().0[0];
                    chunk.commit_all();
                    let file_id = marker.file_id_str().to_string();
                    if let Ok(guard) = EVENT_SINK.lock() {
                        if let Some(ref sink) = *guard {
                            match marker.kind {
                                BoundaryKind::TrackStarted | BoundaryKind::TrackChanged => {
                                    let _ = sink.add(EngineEvent::TrackStarted { file_id });
                                }
                                BoundaryKind::TrackEnded => {
                                    let _ = sink.add(EngineEvent::TrackEnded { file_id });
                                }
                            }
                        }
                    }
                } else {
                    break;
                }
            }

            // 2. State & Telemetry updates
            let is_playing = CALLBACK_IS_PLAYING.load(Ordering::Acquire);
            let is_buffering = {
                let state = PLAYER_STATE.lock().unwrap();
                state.buffering
            };

            if is_playing != last_playing || is_buffering != last_buffering {
                last_playing = is_playing;
                last_buffering = is_buffering;
                if let Ok(guard) = EVENT_SINK.lock() {
                    if let Some(ref sink) = *guard {
                        let _ = sink.add(EngineEvent::PlaybackState {
                            is_playing,
                            is_buffering,
                        });
                    }
                }
            }

            if tick_count.is_multiple_of(2) {
                let (pos_ms, dur_ms, buf_ms) = {
                    let state = PLAYER_STATE.lock().unwrap();
                    let pos = if TRACK_ENDED_FLAG.load(Ordering::Acquire) {
                        state.duration_ms
                    } else {
                        state.position_ms
                    };
                    (pos, state.duration_ms, state.buffered_ms)
                };

                let in_flight = crate::cloud::media_source::fetches_in_flight() as u32;
                let bytes_fetched = crate::cloud::media_source::bytes_fetched() as u64;
                let gr_db = crate::dsp::LIMITER_GR_MILLIDB.load(Ordering::Relaxed);
                let clipped = crate::dsp::LIMITER_CLIPPED_SAMPLES.load(Ordering::Relaxed);

                if let Ok(guard) = EVENT_SINK.lock() {
                    if let Some(ref sink) = *guard {
                        if is_playing {
                            let _ = sink.add(EngineEvent::PositionUpdate {
                                position_ms: pos_ms,
                                duration_ms: dur_ms,
                            });
                        }
                        let _ = sink.add(EngineEvent::BufferTelemetry {
                            buffered_ms: buf_ms,
                            fetches_in_flight: in_flight,
                            bytes_fetched,
                        });
                        let _ = sink.add(EngineEvent::LimiterTelemetry {
                            gr_millidb: gr_db,
                            clipped_samples: clipped,
                        });
                    }
                }
            }
        }
    });

    // Opening a source means a container probe and, for a cloud track, a
    // network round trip — anywhere from a moment to a couple of seconds.
    // Doing that on the decode thread stops the audio it is still feeding,
    // and that stop *is* the gap between tracks. Here the old track plays on
    // until the new one is genuinely ready to take over, so the only silence
    // the listener gets is the fade that was asked for.
    thread::spawn(move || {
        while let Ok(cmd) = load_rx.recv() {
            let generation = LOAD_GENERATION.load(Ordering::SeqCst);
            let is_next = matches!(
                cmd,
                DecoderCmd::SetNextTrack(_) | DecoderCmd::SetNextCloud { .. }
            );

            let opened = match cmd {
                DecoderCmd::Play(path) | DecoderCmd::SetNextTrack(path) => {
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
                }
                | DecoderCmd::SetNextCloud {
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
                    Ok(source) => open_media_source(Box::new(source), &ext).map(|t| (file_id, t)),
                    Err(e) => {
                        eprintln!("[bitdrop] could not open cloud track {}: {}", file_id, e);
                        None
                    }
                },
                _ => None,
            };

            if is_next {
                if let Some((id, track)) = opened {
                    let _ = next_loaded_tx.send((id, Box::new(track)));
                }
                continue;
            }

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
        enable_hardware_flush_to_zero();
        let mut audio_producer = audio_tx;
        let mut boundary_producer = boundary_tx;
        let mut decoder_frames_pushed: u64 = 0;
        let mut current_track_id_str: String = String::new();

        let mut current_format: Option<Box<dyn symphonia::core::formats::FormatReader>> = None;
        let mut current_decoder: Option<Box<dyn symphonia::core::codecs::Decoder>> = None;
        let mut current_track_id: u32 = 0;
        let mut tb: Option<symphonia::core::units::TimeBase> = None;

        let mut pending_out: Option<Vec<f32>> = None;
        let mut current_resampler: Option<(u32, u32, rubato::Async<f64>)> = None;
        let mut resample_in_buf: Vec<f64> = Vec::new();
        let mut next_track: Option<(String, Box<OpenedTrack>)> = None;
        let mut seek_target_frame: Option<u64> = None;

        /// Consecutive failed reads before a track is given up on. Enough to
        /// ride out a dropped connection, few enough that a genuinely broken
        /// source does not hang playback.
        const MAX_READ_FAILURES: u32 = 5;
        let mut read_failures: u32 = 0;

        loop {
            // Check for pre-loaded next track staged for gapless transition
            if let Ok((id, opened)) = next_loaded_rx.try_recv() {
                next_track = Some((id, opened));
            }

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
                    DecoderCmd::Play(_)
                    | DecoderCmd::PlayCloud { .. }
                    | DecoderCmd::SetNextTrack(_)
                    | DecoderCmd::SetNextCloud { .. } => {}
                    DecoderCmd::Pause => {
                        PLAYER_STATE.lock().unwrap().is_playing = false;
                        CALLBACK_IS_PLAYING.store(false, Ordering::Release);
                    }
                    DecoderCmd::Resume => {
                        let mut state = PLAYER_STATE.lock().unwrap();
                        // Ramp back rather than reappearing at full level.
                        set_ramp(&mut state, 1.0, DUCK_MS * 3);
                        state.is_playing = true;
                        CALLBACK_IS_PLAYING.store(true, Ordering::Release);
                    }
                    DecoderCmd::Seek(ms) => {
                        let was_playing = CALLBACK_IS_PLAYING.load(Ordering::Acquire);
                        if was_playing {
                            thread::sleep(Duration::from_millis(SEEK_FADE_MS as u64 + 5));
                        }

                        next_track = None;
                        pending_out = None;
                        resample_in_buf.clear();
                        if let Some((_, _, ref mut resampler)) = current_resampler {
                            resampler.reset();
                        }

                        let cur_sr = {
                            let state = PLAYER_STATE.lock().unwrap();
                            if state.target_sample_rate > 0 {
                                state.target_sample_rate
                            } else {
                                48000
                            }
                        };
                        seek_target_frame = Some((ms as u64 * cur_sr as u64) / 1000);

                        {
                            let mut state = PLAYER_STATE.lock().unwrap();
                            state.flush_requested = true;
                            CALLBACK_FLUSH_REQUESTED.store(true, Ordering::Release);
                            TRACK_ENDED_FLAG.store(false, Ordering::Release);
                            state.buffered_ms = 0;
                            state.position_ms = ms;
                            state.decoded_ms = ms;
                            state.gate_output = true;
                            CALLBACK_GATE_OUTPUT.store(true, Ordering::Release);
                            set_ramp(&mut state, 1.0, SEEK_FADE_MS);
                        }

                        crate::cloud::media_source::abort_active_fetches();

                        if let (Some(format), Some(t)) = (current_format.as_mut(), tb) {
                            let ts = (ms as u64 * t.denom as u64) / (1000 * t.numer as u64);
                            let _ = format.seek(
                                symphonia::core::formats::SeekMode::Accurate,
                                symphonia::core::formats::SeekTo::TimeStamp {
                                    ts,
                                    track_id: current_track_id,
                                },
                            );
                            if let Some(d) = current_decoder.as_mut() {
                                d.reset();
                            }
                        } else {
                            let mut state = PLAYER_STATE.lock().unwrap();
                            state.gate_output = false;
                            CALLBACK_GATE_OUTPUT.store(false, Ordering::Release);
                        }
                    }
                    DecoderCmd::Stop => {
                        next_track = None;
                        seek_target_frame = None;
                        current_format = None;
                        current_decoder = None;
                        pending_out = None;
                        resample_in_buf.clear();
                        current_resampler = None;
                        let mut state = PLAYER_STATE.lock().unwrap();
                        state.flush_requested = true;
                        CALLBACK_FLUSH_REQUESTED.store(true, Ordering::Release);
                        state.is_playing = false;
                        CALLBACK_IS_PLAYING.store(false, Ordering::Release);
                        TRACK_ENDED_FLAG.store(false, Ordering::Release);
                        state.gate_output = false;
                        CALLBACK_GATE_OUTPUT.store(false, Ordering::Release);
                        state.buffering = false;
                        state.loading = false;
                        crate::cloud::media_source::abort_active_fetches();
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
                    if was_playing {
                        thread::sleep(Duration::from_millis(FADE_MS as u64 + 30));
                    }

                    let opened = *opened;
                    tb = opened.time_base;
                    current_track_id = opened.track_id;
                    current_decoder = Some(opened.decoder);
                    current_format = Some(opened.format);
                    current_track_id_str = id.clone();
                    pending_out = None;
                    resample_in_buf.clear();
                    current_resampler = None;
                    next_track = None;
                    seek_target_frame = None;

                    let mut state = PLAYER_STATE.lock().unwrap();
                    state.flush_requested = true;
                    CALLBACK_FLUSH_REQUESTED.store(true, Ordering::Release);
                    TRACK_ENDED_FLAG.store(false, Ordering::Release);
                    state.is_playing = true;
                    CALLBACK_IS_PLAYING.store(true, Ordering::Release);
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
                    CALLBACK_GATE_OUTPUT.store(true, Ordering::Release);

                    #[cfg(target_os = "android")]
                    let track_sr = opened.sample_rate;
                    #[cfg(target_os = "android")]
                    let cur_target = state.target_sample_rate;

                    publish_dsp_config(&state);
                    drop(state);

                    #[cfg(target_os = "android")]
                    if track_sr > 0 && track_sr != cur_target {
                        eprintln!("[bitdrop] track rate {track_sr} != stream rate {cur_target}; rebuilding exclusive stream");
                        open_output_stream(Some(track_sr));
                    }

                    let mut state = PLAYER_STATE.lock().unwrap();
                    set_ramp(&mut state, 1.0, FADE_MS);

                    // Push TrackStarted boundary marker
                    let _ = boundary_producer.push(BoundaryMarker::track_started(
                        decoder_frames_pushed,
                        &current_track_id_str,
                    ));
                }
            }

            let is_playing = CALLBACK_IS_PLAYING.load(Ordering::Acquire);
            if !is_playing || current_format.is_none() {
                thread::sleep(Duration::from_millis(20));
                continue;
            }

            // Deliver whatever last round decoded before pulling more.
            if let Some(buf) = pending_out.take() {
                let slots = audio_producer.slots();
                let to_write = buf.len().min(slots);
                if to_write > 0 {
                    if let Ok(mut chunk) = audio_producer.write_chunk(to_write) {
                        let (s1, s2) = chunk.as_mut_slices();
                        let s1_len = s1.len();
                        s1.copy_from_slice(&buf[..s1_len]);
                        if !s2.is_empty() {
                            s2.copy_from_slice(&buf[s1_len..to_write]);
                        }
                        chunk.commit_all();
                        let pushed = (to_write / 2) as u64;
                        decoder_frames_pushed += pushed;
                        DECODER_FRAMES_PUSHED.store(decoder_frames_pushed, Ordering::Release);
                    }
                }
                if to_write < buf.len() {
                    pending_out = Some(buf[to_write..].to_vec());
                    thread::sleep(Duration::from_millis(10));
                    continue;
                }
            }

            if let (Some(format), Some(decoder)) =
                (current_format.as_mut(), current_decoder.as_mut())
            {
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
                            let channels = audio_buf.spec().channels.count();

                            let mut sample_buf = SampleBuffer::<f32>::new(
                                audio_buf.capacity() as u64,
                                *audio_buf.spec(),
                            );
                            sample_buf.copy_interleaved_ref(audio_buf);

                            // DOWNMIX TO STEREO via ITU-R BS.775
                            let mut samples = downmix_to_stereo(sample_buf.samples(), channels);

                            // Frame-exact seek trimming: discard leading pre-roll frames before seek target
                            if let Some(target_frame) = seek_target_frame {
                                if let Some(t) = tb {
                                    let cur_sr =
                                        PLAYER_STATE.lock().unwrap().source_sample_rate.max(1);
                                    let packet_frame =
                                        (packet.ts() * t.numer as u64 * cur_sr as u64)
                                            / t.denom as u64;
                                    if packet_frame < target_frame {
                                        let frames_to_skip = (target_frame - packet_frame) as usize;
                                        let packet_frames = samples.len() / 2;
                                        if frames_to_skip < packet_frames {
                                            samples.drain(0..(frames_to_skip * 2));
                                            seek_target_frame = None;
                                        } else {
                                            samples.clear();
                                        }
                                    } else {
                                        seek_target_frame = None;
                                    }
                                } else {
                                    seek_target_frame = None;
                                }
                            }

                            // High-quality Sinc Resampling via rubato 256-sinc
                            if track_sr != target_sr && target_sr > 0 {
                                let needs_new_resampler = match &current_resampler {
                                    Some((in_sr, out_sr, _)) => {
                                        *in_sr != track_sr || *out_sr != target_sr
                                    }
                                    None => true,
                                };
                                if needs_new_resampler {
                                    let ratio = target_sr as f64 / track_sr as f64;
                                    let params = rubato::SincInterpolationParameters {
                                        sinc_len: 256,
                                        f_cutoff: Some(0.95),
                                        oversampling_factor: 256,
                                        interpolation: rubato::SincInterpolationType::Cubic,
                                        window: rubato::WindowFunction::BlackmanHarris2,
                                    };
                                    let new_resampler = rubato::Async::<f64>::new_sinc(
                                        ratio,
                                        1.0,
                                        &params,
                                        1024,
                                        2,
                                        rubato::FixedAsync::Input,
                                    );
                                    match new_resampler {
                                        Ok(r) => current_resampler = Some((track_sr, target_sr, r)),
                                        Err(e) => {
                                            eprintln!("[bitdrop] failed to initialize rubato 256-sinc resampler: {:?}", e);
                                            current_resampler = None;
                                        }
                                    }
                                }

                                if let Some((_, _, ref mut resampler)) = current_resampler {
                                    let samples_f64: Vec<f64> =
                                        samples.iter().map(|&s| s as f64).collect();
                                    resample_in_buf.extend_from_slice(&samples_f64);
                                    let chunk_size = resampler.input_frames_next();
                                    let chunk_samples = chunk_size * 2;
                                    let mut resampled_out = Vec::new();

                                    while resample_in_buf.len() >= chunk_samples {
                                        if let Ok(slice) = rubato::audioadapter_buffers::direct::InterleavedSlice::new(
                                            &resample_in_buf[..chunk_samples],
                                            2,
                                            chunk_size,
                                        ) {
                                            match resampler.process(&slice, None) {
                                                Ok(out) => resampled_out.extend(out.take_data()),
                                                Err(e) => eprintln!("[bitdrop] resampler error during process: {:?}", e),
                                            }
                                        }
                                        resample_in_buf.drain(0..chunk_samples);
                                    }
                                    samples = resampled_out.into_iter().map(|s| s as f32).collect();
                                }
                            }

                            if !samples.is_empty() {
                                let slots = audio_producer.slots();
                                let to_write = samples.len().min(slots);
                                if to_write > 0 {
                                    if let Ok(mut chunk) = audio_producer.write_chunk(to_write) {
                                        let (s1, s2) = chunk.as_mut_slices();
                                        let s1_len = s1.len();
                                        s1.copy_from_slice(&samples[..s1_len]);
                                        if !s2.is_empty() {
                                            s2.copy_from_slice(&samples[s1_len..to_write]);
                                        }
                                        chunk.commit_all();
                                        let pushed = (to_write / 2) as u64;
                                        decoder_frames_pushed += pushed;
                                        DECODER_FRAMES_PUSHED
                                            .store(decoder_frames_pushed, Ordering::Release);
                                    }
                                }
                                if to_write < samples.len() {
                                    pending_out = Some(samples[to_write..].to_vec());
                                }
                            }

                            {
                                let mut state = PLAYER_STATE.lock().unwrap();
                                let sr = if state.target_sample_rate == 0 {
                                    48000
                                } else {
                                    state.target_sample_rate
                                };
                                let queued_samples =
                                    audio_producer.buffer().capacity() - audio_producer.slots();
                                let queued_frames = queued_samples / 2;
                                state.buffered_ms =
                                    ((queued_frames as u64 * 1000) / sr as u64) as u32;

                                state.buffering = crate::cloud::media_source::fetches_in_flight()
                                    > 0
                                    && state.buffered_ms < 500;

                                if state.gate_output && state.buffered_ms >= PREBUFFER_MS {
                                    state.gate_output = false;
                                    CALLBACK_GATE_OUTPUT.store(false, Ordering::Release);
                                }

                                if let Some(t) = tb {
                                    let time = t.calc_time(packet.ts());
                                    let decoded =
                                        (time.seconds * 1000 + (time.frac * 1000.0) as u64) as u32;
                                    state.decoded_ms = decoded;
                                    state.position_ms = decoded.saturating_sub(state.buffered_ms);
                                }
                            }
                        }
                    }
                } else if ended {
                    read_failures = 0;
                    if let Some((_, _, ref mut resampler)) = current_resampler {
                        if !resample_in_buf.is_empty() {
                            let chunk_size = resampler.input_frames_next();
                            let chunk_samples = chunk_size * 2;
                            resample_in_buf.resize(chunk_samples, 0.0);
                            if let Ok(slice) =
                                rubato::audioadapter_buffers::direct::InterleavedSlice::new(
                                    &resample_in_buf,
                                    2,
                                    chunk_size,
                                )
                            {
                                if let Ok(out) = resampler.process(&slice, None) {
                                    let remaining: Vec<f32> =
                                        out.take_data().into_iter().map(|s| s as f32).collect();
                                    let slots = audio_producer.slots();
                                    let to_write = remaining.len().min(slots);
                                    if to_write > 0 {
                                        if let Ok(mut chunk) = audio_producer.write_chunk(to_write)
                                        {
                                            let (s1, s2) = chunk.as_mut_slices();
                                            let s1_len = s1.len();
                                            s1.copy_from_slice(&remaining[..s1_len]);
                                            if !s2.is_empty() {
                                                s2.copy_from_slice(&remaining[s1_len..to_write]);
                                            }
                                            chunk.commit_all();
                                            let pushed = (to_write / 2) as u64;
                                            decoder_frames_pushed += pushed;
                                            DECODER_FRAMES_PUSHED
                                                .store(decoder_frames_pushed, Ordering::Release);
                                        }
                                    }
                                }
                            }
                            resample_in_buf.clear();
                        }
                    }

                    // Check if next track is staged for gapless transition
                    let cur_sr = PLAYER_STATE.lock().unwrap().source_sample_rate;
                    if let Some((next_id, next_opened)) = next_track.take() {
                        if next_opened.sample_rate == cur_sr {
                            // TRUE GAPLESS TRANSITION:
                            // Push TrackChanged marker at current pushed frame count.
                            let _ = boundary_producer.push(BoundaryMarker::track_changed(
                                decoder_frames_pushed,
                                &next_id,
                            ));

                            tb = next_opened.time_base;
                            current_track_id = next_opened.track_id;
                            current_decoder = Some(next_opened.decoder);
                            current_format = Some(next_opened.format);
                            current_track_id_str = next_id.clone();
                            pending_out = None;
                            resample_in_buf.clear();
                            current_resampler = None;
                            seek_target_frame = None;

                            let mut state = PLAYER_STATE.lock().unwrap();
                            state.duration_ms = next_opened.duration_ms;
                            state.current_track_id = next_id;
                            state.source_codec = next_opened.codec;
                            state.source_sample_rate = next_opened.sample_rate;
                            state.source_bits = next_opened.bits_per_sample;
                            state.source_channels = next_opened.channels;
                            state.decoded_ms = 0;
                            drop(state);

                            continue;
                        } else {
                            let marker = BoundaryMarker::track_ended(
                                decoder_frames_pushed,
                                &current_track_id_str,
                            );
                            let _ = boundary_producer.push(marker);
                            let mut state = PLAYER_STATE.lock().unwrap();
                            state.buffering = false;
                            state.buffered_ms = 0;
                            drop(state);
                            current_format = None;
                            current_decoder = None;
                        }
                    } else {
                        // Standard EOF: drain all buffered audio with TrackEnded
                        let marker = BoundaryMarker::track_ended(
                            decoder_frames_pushed,
                            &current_track_id_str,
                        );
                        let _ = boundary_producer.push(marker);

                        let mut state = PLAYER_STATE.lock().unwrap();
                        state.buffering = false;
                        state.buffered_ms = 0;
                        drop(state);
                        current_format = None;
                        current_decoder = None;
                    }
                }
            }
        }
    });
}

/// Builds and starts the output stream, replacing any existing one.
#[cfg(target_os = "android")]
fn open_output_stream(sample_rate: Option<u32>) {
    *ACTIVE_STREAM.lock().unwrap() = None;

    let (consumer, boundary_consumer, triggered_producer) = {
        let mut c_guard = AUDIO_CONSUMER.lock().unwrap();
        let mut b_guard = BOUNDARY_CONSUMER.lock().unwrap();
        let mut t_guard = TRIGGERED_PRODUCER.lock().unwrap();
        match (c_guard.take(), b_guard.take()) {
            (Some(c), Some(b)) => (c, b, t_guard.take()),
            _ => return,
        }
    };

    fn make_callback(
        consumer: rtrb::Consumer<f32>,
        boundary_consumer: rtrb::Consumer<BoundaryMarker>,
        triggered_producer: Option<rtrb::Producer<BoundaryMarker>>,
    ) -> PlayerCallback {
        let mut renderer = crate::renderer::OutputRenderer::new(
            48000.0,
            Some(consumer),
            Some(boundary_consumer),
            triggered_producer,
        );
        renderer.fade_gain = 0.0;
        PlayerCallback { renderer }
    }

    let mut builder = AudioStreamBuilder::default()
        .set_performance_mode(PerformanceMode::LowLatency)
        .set_sharing_mode(SharingMode::Exclusive)
        .set_audio_api(AudioApi::AAudio)
        .set_output()
        .set_stereo()
        .set_f32();

    if let Some(sr) = sample_rate {
        if sr > 0 {
            builder = builder.set_sample_rate(sr as i32);
        }
    }

    let opened = builder
        .set_callback(make_callback(
            consumer,
            boundary_consumer,
            triggered_producer,
        ))
        .open_stream();

    let opened = match opened {
        Ok(stream) => {
            eprintln!(
                "[bitdrop] opened exclusive stream: rate={}",
                stream.get_sample_rate()
            );
            Some(stream)
        }
        Err(e) => {
            eprintln!(
                "[bitdrop] exclusive stream at {:?} unavailable ({e:?}); falling back to shared",
                sample_rate
            );
            let (consumer, boundary_consumer, triggered_producer) = {
                let mut c_guard = AUDIO_CONSUMER.lock().unwrap();
                let mut b_guard = BOUNDARY_CONSUMER.lock().unwrap();
                let mut t_guard = TRIGGERED_PRODUCER.lock().unwrap();
                match (c_guard.take(), b_guard.take()) {
                    (Some(c), Some(b)) => (c, b, t_guard.take()),
                    _ => return,
                }
            };
            let mut shared_builder = AudioStreamBuilder::default()
                .set_performance_mode(PerformanceMode::None)
                .set_sharing_mode(SharingMode::Shared)
                .set_output()
                .set_stereo()
                .set_f32();
            if let Some(sr) = sample_rate {
                if sr > 0 {
                    shared_builder = shared_builder.set_sample_rate(sr as i32);
                }
            }
            shared_builder
                .set_callback(make_callback(
                    consumer,
                    boundary_consumer,
                    triggered_producer,
                ))
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
            state.hardware_sample_rate = rate;
            state.hardware_format = "PCM_FLOAT".to_string();
            state.eq_updated = true;
            publish_dsp_config(&state);
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

            let current_sr = {
                let state = PLAYER_STATE.lock().unwrap();
                if state.source_sample_rate > 0 {
                    Some(state.source_sample_rate)
                } else {
                    None
                }
            };

            if STREAM_LOST.load(Ordering::SeqCst) {
                eprintln!(
                    "[bitdrop] reopening output stream after loss (rate={:?})",
                    current_sr
                );
                open_output_stream(current_sr);
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
                    eprintln!(
                        "[bitdrop] output stalled; reopening stream (rate={:?})",
                        current_sr
                    );
                    open_output_stream(current_sr);
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
pub fn engine_set_next_track(path: String) {
    if let Some(sender) = LOAD_SENDER.lock().unwrap().as_ref() {
        let _ = sender.send(DecoderCmd::SetNextTrack(path));
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn engine_set_next_cloud(
    file_id: String,
    url: String,
    auth_token: Option<String>,
    total_size: u64,
    cache_dir: String,
    ext: String,
) {
    if let Some(sender) = LOAD_SENDER.lock().unwrap().as_ref() {
        let _ = sender.send(DecoderCmd::SetNextCloud {
            file_id,
            url,
            auth_token,
            total_size,
            cache_dir,
            ext,
        });
    }
}

#[flutter_rust_bridge::frb]
pub fn engine_events_stream(
    sink: crate::frb_generated::StreamSink<EngineEvent>,
) -> Result<(), String> {
    let mut guard = EVENT_SINK.lock().map_err(|e| e.to_string())?;
    *guard = Some(sink);
    Ok(())
}

#[flutter_rust_bridge::frb(sync)]
pub fn engine_pause() {
    {
        let mut state = PLAYER_STATE.lock().unwrap();
        state.is_playing = false;
    }
    CALLBACK_IS_PLAYING.store(false, Ordering::Release);
    if let Some(sender) = CMD_SENDER.lock().unwrap().as_ref() {
        let _ = sender.send(DecoderCmd::Pause);
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn engine_resume() {
    {
        let mut state = PLAYER_STATE.lock().unwrap();
        state.is_playing = true;
    }
    CALLBACK_IS_PLAYING.store(true, Ordering::Release);
    TRACK_ENDED_FLAG.store(false, Ordering::Release);
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
    TRACK_ENDED_FLAG.store(false, Ordering::Release);
    CALLBACK_FLUSH_REQUESTED.store(true, Ordering::Release);
    crate::cloud::media_source::abort_active_fetches();
    if let Some(sender) = CMD_SENDER.lock().unwrap().as_ref() {
        let _ = sender.send(DecoderCmd::Seek(position_ms));
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn engine_stop() {
    {
        let mut state = PLAYER_STATE.lock().unwrap();
        state.is_playing = false;
        state.gate_output = false;
        state.buffering = false;
        state.buffered_ms = 0;
    }
    CALLBACK_IS_PLAYING.store(false, Ordering::Release);
    CALLBACK_FLUSH_REQUESTED.store(true, Ordering::Release);
    TRACK_ENDED_FLAG.store(false, Ordering::Release);
    crate::cloud::media_source::abort_active_fetches();
    if let Some(sender) = CMD_SENDER.lock().unwrap().as_ref() {
        let _ = sender.send(DecoderCmd::Stop);
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
    pub hardware_sample_rate: u32,
    pub hardware_format: String,
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
    let (duration_ms, track_id) = {
        let state = PLAYER_STATE.lock().unwrap();
        (state.duration_ms as u64, state.current_track_id.clone())
    };
    if duration_ms == 0 {
        return Vec::new();
    }

    let (total, ranges) = crate::cloud::media_source::cached_byte_ranges(if track_id.is_empty() {
        None
    } else {
        Some(&track_id)
    });
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
    let has_custom_specs = state
        .eq_specs
        .as_ref()
        .map_or(false, |specs| specs.iter().any(|s| s.gain_db.abs() > 0.01));
    let has_graphic_gains = state.eq_gains.iter().any(|g| g.abs() > 0.01);
    let dsp_active =
        state.eq_enabled && (has_custom_specs || has_graphic_gains || state.eq_preamp.abs() > 0.01);

    EngineOutputState {
        source_codec: state.source_codec.clone(),
        source_sample_rate: state.source_sample_rate,
        source_bits: state.source_bits,
        source_channels: state.source_channels,
        output_sample_rate: state.target_sample_rate,
        dsp_active,
        has_track: !state.current_track_id.is_empty(),
        hardware_sample_rate: state.hardware_sample_rate,
        hardware_format: state.hardware_format.clone(),
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn engine_buffer_state() -> EngineBufferState {
    let state = PLAYER_STATE.lock().unwrap();
    EngineBufferState {
        buffering: state.loading || state.gate_output || state.buffering,
        buffered_ms: state.buffered_ms,
        fetches_in_flight: crate::cloud::media_source::fetches_in_flight() as u32,
        bytes_fetched: crate::cloud::media_source::bytes_fetched() as u64,
        stream_opens: stream_opens(),
    }
}

/// Comprehensive engine telemetry snapshot backed by measured hardware and network data.
#[derive(Clone, Debug, Default)]
pub struct EngineDiagnosticsData {
    pub buffer_ahead_seconds: f64,
    pub pcm_fill_percent: f64,
    pub underrun_count: u32,
    pub speed_mbps: f64,
    pub active_range_requests: u32,
    pub requests_per_minute: u32,
    pub request_budget_per_minute: u32,
    pub cache_hit_rate: f64,
    pub cache_size_bytes: u64,
    pub current_file_cached_percent: u32,
    pub decode_load_percent: f64,
    pub time_to_first_byte_ms: u32,
    pub bytes_downloaded: u64,
    pub last_error: Option<String>,
}

#[flutter_rust_bridge::frb(sync)]
pub fn engine_get_visualizer_frame() -> VisualizerFrameData {
    let is_playing = CALLBACK_IS_PLAYING.load(Ordering::Acquire);
    crate::dsp::compute_visualizer_frame(is_playing)
}

#[flutter_rust_bridge::frb(sync)]
pub fn engine_get_diagnostics() -> EngineDiagnosticsData {
    let state = PLAYER_STATE.lock().unwrap();
    let buffer_ahead_seconds = state.buffered_ms as f64 / 1000.0;
    let sr = if state.target_sample_rate > 0 {
        state.target_sample_rate as f64
    } else {
        48000.0
    };
    let queued_samples = (buffer_ahead_seconds * sr * 2.0) as usize;
    let pcm_fill_percent =
        ((queued_samples as f64 / RING_BUFFER_CAPACITY as f64) * 100.0).clamp(0.0, 100.0);

    let underrun_count = crate::renderer::ENGINE_UNDERRUNS.load(Ordering::Relaxed);
    let speed_mbps = crate::cloud::media_source::measured_throughput_bps() as f64 / 1_000_000.0;
    let active_range_requests = crate::cloud::media_source::fetches_in_flight() as u32;
    let requests_per_minute = crate::cloud::media_source::requests_per_minute();
    let request_budget_per_minute = 12000;
    let cache_hit_rate = crate::cloud::media_source::cache_hit_rate();
    let bytes_downloaded = crate::cloud::media_source::bytes_fetched() as u64;
    let time_to_first_byte_ms = crate::cloud::media_source::last_ttfb_ms();
    let cache_size_bytes = crate::api::cloud_library::get_total_cache_bytes();

    let current_file_cached_percent = if state.duration_ms > 0 && !state.current_track_id.is_empty()
    {
        let (total_bytes, ranges) =
            crate::cloud::media_source::cached_byte_ranges(Some(&state.current_track_id));
        if total_bytes > 0 {
            let cached_sum: u64 = ranges.iter().map(|(s, e)| e.saturating_sub(*s)).sum();
            ((cached_sum * 100) / total_bytes).min(100) as u32
        } else {
            0
        }
    } else {
        0
    };

    let decode_load_percent = DECODE_LOAD_PERMILLE.load(Ordering::Relaxed) as f64 / 10.0;

    let last_error = if state.buffering && active_range_requests == 0 {
        Some("Network stalled waiting for chunks".to_string())
    } else {
        None
    };

    EngineDiagnosticsData {
        buffer_ahead_seconds,
        pcm_fill_percent,
        underrun_count,
        speed_mbps,
        active_range_requests,
        requests_per_minute,
        request_budget_per_minute,
        cache_hit_rate,
        cache_size_bytes,
        current_file_cached_percent,
        decode_load_percent,
        time_to_first_byte_ms,
        bytes_downloaded,
        last_error,
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
    if TRACK_ENDED_FLAG.load(Ordering::Acquire) {
        return PLAYER_STATE.lock().unwrap().duration_ms;
    }
    PLAYER_STATE.lock().unwrap().position_ms
}

#[flutter_rust_bridge::frb(sync)]
pub fn engine_is_playing() -> bool {
    CALLBACK_IS_PLAYING.load(Ordering::Acquire)
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
    init_engine();
}
pub fn play_audio_file_android(_path: String) -> Result<String, String> {
    Ok("".to_string())
}

#[flutter_rust_bridge::frb(sync)]
pub fn engine_set_eq(gains: Vec<f32>) {
    let mut state = PLAYER_STATE.lock().unwrap();
    if !gains.is_empty() && (gains[0] - (-999.0)).abs() < 0.01 {
        let count = (gains.get(1).copied().unwrap_or(0.0) as usize).min(MAX_EQ_BANDS);
        let mut specs = Vec::with_capacity(count);
        for i in 0..count {
            let idx = 2 + i * 4;
            if idx + 3 < gains.len() {
                specs.push(EqBandSpec {
                    kind: gains[idx] as u8,
                    freq: gains[idx + 1],
                    gain_db: gains[idx + 2],
                    q: gains[idx + 3],
                });
            }
        }
        let end_idx = 2 + count * 4;
        state.eq_preamp = gains.get(end_idx).copied().unwrap_or(0.0);
        state.balance = gains.get(end_idx + 1).copied().unwrap_or(0.0);
        state.mono = gains.get(end_idx + 2).copied().unwrap_or(0.0) > 0.5;
        state.eq_specs = Some(specs);
    } else {
        state.eq_specs = None;
        for i in 0..10.min(gains.len()) {
            state.eq_gains[i] = gains[i];
        }
        if gains.len() > 10 {
            state.eq_preamp = gains[10];
        } else {
            state.eq_preamp = 0.0;
        }
        if gains.len() > 11 {
            state.balance = gains[11];
        } else {
            state.balance = 0.0;
        }
        if gains.len() > 12 {
            state.mono = gains[12] > 0.5;
        } else {
            state.mono = false;
        }
    }
    state.eq_updated = true;
    publish_dsp_config(&state);
}

#[flutter_rust_bridge::frb(sync)]
pub fn engine_set_eq_enabled(enabled: bool) {
    let mut state = PLAYER_STATE.lock().unwrap();
    state.eq_enabled = enabled;
    state.eq_updated = true;
    publish_dsp_config(&state);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_flush_to_zero_hardware_execution() {
        enable_hardware_flush_to_zero();
        // Subnormal number test: multiplying a tiny number by a fraction
        // in FTZ mode flushes to zero instead of producing denormals.
        let tiny = 1e-40f32;
        let result = tiny * 0.5f32;
        // Should not panic or crash
        let _ = result;
    }

    #[test]
    fn test_stereo_biquad_and_eq() {
        let mut dsp = DspPipelineV2::new(48000.0);
        dsp.eq_enabled = true;
        let gains = [3.0, 2.0, 1.0, 0.0, -1.0, -2.0, -3.0, 0.0, 1.0, 2.0];
        dsp.update_graphic_gains(&gains, 0.0, 0.0, 1.0, 0.0, false);
        assert_eq!(dsp.active_bands(), 10);

        // Process test frames
        for _ in 0..100 {
            let (l, r) = dsp.process_stereo(0.5, -0.5);
            assert!(l.is_finite());
            assert!(r.is_finite());
        }

        // Test parametric band configuration (e.g. AutoEQ profile with shelves + peaks)
        let specs = [
            EqBandSpec {
                kind: EQ_LOW_SHELF,
                freq: 105.0,
                gain_db: 5.5,
                q: 0.71,
            },
            EqBandSpec {
                kind: EQ_PEAK,
                freq: 1000.0,
                gain_db: -2.0,
                q: 1.4,
            },
            EqBandSpec {
                kind: EQ_HIGH_SHELF,
                freq: 10000.0,
                gain_db: -3.0,
                q: 0.71,
            },
        ];
        dsp.install_parameters(&specs, -3.5, 0.0, 1.0, 0.0, false);
        assert_eq!(dsp.active_bands(), 3);

        let (pl, pr) = dsp.process_stereo(0.5, -0.5);
        assert!(pl.is_finite());
        assert!(pr.is_finite());
        // Preamp of -3.5 dB attenuates the signal below 0.5
        assert!(pl.abs() < 0.5);
    }

    #[test]
    fn test_rtrb_bulk_ring_buffer() {
        let (mut prod, mut cons) = rtrb::RingBuffer::<f32>::new(1024);
        assert_eq!(prod.slots(), 1024);
        assert_eq!(cons.slots(), 0);

        let input_data = vec![0.1f32; 256];
        if let Ok(mut chunk) = prod.write_chunk(input_data.len()) {
            let (s1, s2) = chunk.as_mut_slices();
            let s1_len = s1.len();
            s1.copy_from_slice(&input_data[..s1_len]);
            if !s2.is_empty() {
                s2.copy_from_slice(&input_data[s1_len..]);
            }
            chunk.commit_all();
        }

        assert_eq!(cons.slots(), 256);
        if let Ok(chunk) = cons.read_chunk(256) {
            let (s1, s2) = chunk.as_slices();
            assert_eq!(s1.len() + s2.len(), 256);
            chunk.commit_all();
        }
        assert_eq!(cons.slots(), 0);
    }

    #[test]
    fn test_rubato_sinc_resampler() {
        let in_sr = 96000;
        let out_sr = 48000;
        let ratio = out_sr as f64 / in_sr as f64;
        let params =
            rubato::SincInterpolationParameters::new(64, rubato::WindowFunction::BlackmanHarris2);
        let mut resampler =
            rubato::Async::<f32>::new_sinc(ratio, 1.0, &params, 1024, 2, rubato::FixedAsync::Input)
                .expect("Resampler initialization");

        let input_samples = vec![0.25f32; 1024 * 2]; // 1024 stereo frames
        let slice =
            rubato::audioadapter_buffers::direct::InterleavedSlice::new(&input_samples, 2, 1024)
                .expect("InterleavedSlice");

        let out = resampler.process(&slice, None).expect("Resample process");
        let resampled = out.take_data();
        // Since ratio is 0.5 (96k -> 48k), 1024 input frames yield approximately 512 stereo frames (1024 samples)
        assert!(resampled.len() >= 1000 && resampled.len() <= 1040);
    }

    #[test]
    fn test_downmix_to_stereo_all_layouts() {
        // Mono -> Stereo
        let mono = vec![0.5f32; 10];
        let stereo = downmix_to_stereo(&mono, 1);
        assert_eq!(stereo.len(), 20);
        assert_eq!(stereo[0], 0.5);
        assert_eq!(stereo[1], 0.5);

        // Stereo passthrough
        let orig_stereo = vec![0.3f32, 0.7f32];
        let stereo_pass = downmix_to_stereo(&orig_stereo, 2);
        assert_eq!(stereo_pass, orig_stereo);

        // 5.1 (FL, FR, FC, LFE, SL, SR)
        // 1 frame of 6 channels: FL=1.0, FR=1.0, FC=0.0, LFE=0.0, SL=0.0, SR=0.0
        let surround = vec![1.0, 1.0, 0.0, 0.0, 0.0, 0.0];
        let downmixed = downmix_to_stereo(&surround, 6);
        assert_eq!(downmixed.len(), 2);
        // L = 1.0 * 0.3204 = 0.3204
        assert!((downmixed[0] - 0.3204).abs() < 1e-4);
        assert!((downmixed[1] - 0.3204).abs() < 1e-4);
    }

    #[test]
    fn test_offline_render_no_cutoff_ending() {
        // Golden Test 4: Verify that the decoder + SPSC ring buffer + boundary queue
        // renders 100% of the audio frames right to the very last sample without cutting off the end.

        let golden_path = PathBuf::from("/tmp/bitdrop_golden_flacs/01 - O Sajna.flac");
        let mut source_frames: Vec<(f32, f32)> = Vec::new();

        if golden_path.exists() {
            let file = File::open(&golden_path).expect("Open golden test FLAC");
            let mss = MediaSourceStream::new(Box::new(file), Default::default());
            let hint = Hint::new();
            let mut probed = symphonia::default::get_probe()
                .format(&hint, mss, &Default::default(), &Default::default())
                .expect("Probe golden FLAC");
            let track = probed.format.default_track().expect("Default track");
            let mut decoder = symphonia::default::get_codecs()
                .make(&track.codec_params, &DecoderOptions::default())
                .expect("Decoder");
            let track_id = track.id;

            // Decode up to 50,000 frames
            while let Ok(packet) = probed.format.next_packet() {
                if packet.track_id() == track_id {
                    if let Ok(audio_buf) = decoder.decode(&packet) {
                        let channels = audio_buf.spec().channels.count();
                        let mut sbuf = SampleBuffer::<f32>::new(
                            audio_buf.capacity() as u64,
                            *audio_buf.spec(),
                        );
                        sbuf.copy_interleaved_ref(audio_buf);
                        let stereo = downmix_to_stereo(sbuf.samples(), channels);
                        for i in 0..(stereo.len() / 2) {
                            source_frames.push((stereo[i * 2], stereo[i * 2 + 1]));
                        }
                        if source_frames.len() >= 50_000 {
                            break;
                        }
                    }
                }
            }
        } else {
            // Deterministic synthetic stream
            for i in 0..65536 {
                let l = ((i as f32) * 0.01).sin();
                let r = ((i as f32) * 0.02).cos();
                source_frames.push((l, r));
            }
        }

        assert!(!source_frames.is_empty(), "Source frames must not be empty");
        let total_source_frames = source_frames.len();
        let expected_last_frame = *source_frames.last().unwrap();

        // 1. Setup SPSC PCM audio ring buffer & boundary marker queue
        let (mut audio_prod, mut audio_cons) = rtrb::RingBuffer::<f32>::new(16384);
        let (mut boundary_prod, mut boundary_cons) = rtrb::RingBuffer::<BoundaryMarker>::new(32);

        let mut rendered_frames: Vec<(f32, f32)> = Vec::with_capacity(total_source_frames);
        let mut source_idx = 0;
        let mut decoder_pushed_frames = 0u64;
        let mut callback_frames_played = 0u64;
        let mut track_ended_fired = false;
        let mut eof_reached = false;

        let mut dsp = DspPipelineV2::new(48000.0);
        dsp.eq_enabled = false; // Bypass mode for bit-exact sample matching

        // Simulate concurrent interleaved execution of decoder thread and real-time audio callback
        let mut iterations = 0;
        while (!track_ended_fired || audio_cons.slots() > 0) && iterations < 1_000_000 {
            iterations += 1;

            // --- DECODER THREAD STEP ---
            if !eof_reached {
                let avail_slots = audio_prod.slots();
                let frames_to_push = (avail_slots / 2)
                    .min(total_source_frames - source_idx)
                    .min(1024);
                if frames_to_push > 0 {
                    if let Ok(mut chunk) = audio_prod.write_chunk(frames_to_push * 2) {
                        let (s1, s2) = chunk.as_mut_slices();
                        let mut pushed = 0;
                        for i in 0..frames_to_push {
                            let (l, r) = source_frames[source_idx + i];
                            if pushed < s1.len() {
                                s1[pushed] = l;
                                s1[pushed + 1] = r;
                            } else {
                                let idx2 = pushed - s1.len();
                                s2[idx2] = l;
                                s2[idx2 + 1] = r;
                            }
                            pushed += 2;
                        }
                        chunk.commit_all();
                        source_idx += frames_to_push;
                        decoder_pushed_frames += frames_to_push as u64;
                    }
                }

                if source_idx >= total_source_frames {
                    // Decoder reached EOF! Push TrackEnded marker with exact frame count.
                    // DO NOT STOP PLAYING!
                    eof_reached = true;
                    let marker = BoundaryMarker::track_ended(decoder_pushed_frames, "golden_track");
                    boundary_prod.push(marker).expect("Push boundary marker");
                }
            }

            // --- AUDIO CALLBACK STEP (e.g. 256 frames per buffer) ---
            let frames_needed = 256;
            let avail_samples = audio_cons.slots();
            let frames_to_read = (avail_samples / 2).min(frames_needed);

            if frames_to_read > 0 {
                if let Ok(chunk) = audio_cons.read_chunk(frames_to_read * 2) {
                    let (s1, s2) = chunk.as_slices();
                    let mut read_idx = 0;
                    let s1_len = s1.len();
                    for _ in 0..frames_to_read {
                        let (l, r) = if read_idx + 1 < s1_len {
                            (s1[read_idx], s1[read_idx + 1])
                        } else if read_idx < s1_len {
                            (s1[read_idx], s2[0])
                        } else {
                            let s2_idx = read_idx - s1_len;
                            (s2[s2_idx], s2[s2_idx + 1])
                        };
                        read_idx += 2;
                        let (out_l, out_r) = dsp.process_stereo(l as f64, r as f64);
                        rendered_frames.push((out_l as f32, out_r as f32));
                    }
                    chunk.commit_all();
                }
                callback_frames_played += frames_to_read as u64;
            }

            // Check boundary markers in audio callback
            while boundary_cons.slots() > 0 {
                if let Ok(chunk) = boundary_cons.read_chunk(1) {
                    let marker = chunk.as_slices().0[0];
                    if callback_frames_played >= marker.trigger_at_frame {
                        chunk.commit_all();
                        if marker.kind == BoundaryKind::TrackEnded {
                            track_ended_fired = true;
                        }
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            }

            if track_ended_fired && audio_cons.slots() == 0 {
                break;
            }
        }

        assert!(
            track_ended_fired,
            "TrackEnded must fire when all frames are played"
        );
        assert_eq!(
            rendered_frames.len(),
            total_source_frames,
            "Rendered frames must exactly equal source frames (NO CUTOFF)"
        );
        let actual_last_frame = *rendered_frames.last().unwrap();
        assert_eq!(
            actual_last_frame.0.to_bits(),
            expected_last_frame.0.to_bits(),
            "L channel last frame bit-exact match"
        );
        assert_eq!(
            actual_last_frame.1.to_bits(),
            expected_last_frame.1.to_bits(),
            "R channel last frame bit-exact match"
        );
        assert_eq!(
            audio_cons.slots(),
            0,
            "All frames in ring buffer must be consumed"
        );

        eprintln!("=======================================================");
        eprintln!("        Golden Test 4: No Cutoff Ending Verified       ");
        eprintln!("=======================================================");
        eprintln!(" Source Frames   : {}", total_source_frames);
        eprintln!(" Rendered Frames : {}", rendered_frames.len());
        eprintln!(
            " Last Frame Match: 100% Bit-Exact ({:?})",
            actual_last_frame
        );
        eprintln!(" Unplayed Frames : 0 (Zero frames dropped at track end)");
        eprintln!(" Status          : PASS (100% Track Completion Verified)");
        eprintln!("=======================================================\n");
    }

    #[test]
    fn test_gapless_album_boundary() {
        // Golden Test 5: True Gapless Playback & Seamless Track Transition
        // Verifies zero dropped samples, zero padding zeros, and phase continuity
        // across the album track boundary.
        use crate::renderer::OutputRenderer;

        let sample_rate = 48000.0;
        let total_frames = 96000; // 2 seconds
        let boundary_frame = 48000; // exactly 1 second

        // Continuous reference 440 Hz sine wave
        let freq = 440.0;
        let mut reference = Vec::with_capacity(total_frames);
        for n in 0..total_frames {
            let t = (n as f64) / sample_rate;
            let val = (2.0 * std::f64::consts::PI * freq * t).sin() as f32;
            reference.push((val, val)); // Stereo: identical L & R
        }

        // Split into Track 1 and Track 2
        let track1_frames = &reference[..boundary_frame];
        let track2_frames = &reference[boundary_frame..];

        // Reset global atomic engine state for test isolation
        CALLBACK_IS_PLAYING.store(true, Ordering::SeqCst);
        CALLBACK_GATE_OUTPUT.store(false, Ordering::SeqCst);
        CALLBACK_FLUSH_REQUESTED.store(false, Ordering::SeqCst);
        CALLBACK_FADE_TARGET.store(1.0f32.to_bits(), Ordering::SeqCst);
        CALLBACK_FADE_STEP.store(1.0f32.to_bits(), Ordering::SeqCst);
        CALLBACK_FRAMES_PLAYED.store(0, Ordering::SeqCst);
        TRACK_ENDED_FLAG.store(false, Ordering::SeqCst);

        // Setup ring buffers
        let (mut audio_prod, audio_cons) = rtrb::RingBuffer::<f32>::new(16384);
        let (mut boundary_prod, boundary_cons) = rtrb::RingBuffer::<BoundaryMarker>::new(32);
        let (triggered_prod, mut triggered_cons) = rtrb::RingBuffer::<BoundaryMarker>::new(32);

        let mut renderer = OutputRenderer::new(
            sample_rate,
            Some(audio_cons),
            Some(boundary_cons),
            Some(triggered_prod),
        );
        renderer.dsp.eq_enabled = false; // Bit-exact bypass mode

        // Push Track 1 start boundary marker
        boundary_prod
            .push(BoundaryMarker::track_started(0, "track_1"))
            .expect("Push start");

        let mut track1_pushed = 0;
        let mut track2_pushed = 0;
        let mut track_changed_pushed = false;
        let mut track_ended_pushed = false;

        let mut rendered_frames: Vec<(f32, f32)> = Vec::with_capacity(total_frames);
        let mut render_buf = [0.0f32; 512]; // 256 stereo frames per callback

        let mut iterations = 0;
        while iterations < 2_000_000 && rendered_frames.len() < total_frames {
            iterations += 1;

            // --- PRODUCER (DECODER) STEP ---
            // 1. Push Track 1
            if track1_pushed < track1_frames.len() {
                let avail = audio_prod.slots() / 2;
                let to_push = avail.min(track1_frames.len() - track1_pushed).min(512);
                if to_push > 0 {
                    if let Ok(mut chunk) = audio_prod.write_chunk(to_push * 2) {
                        let (s1, s2) = chunk.as_mut_slices();
                        let mut p = 0;
                        for i in 0..to_push {
                            let (l, r) = track1_frames[track1_pushed + i];
                            if p < s1.len() {
                                s1[p] = l;
                                s1[p + 1] = r;
                            } else {
                                let idx = p - s1.len();
                                s2[idx] = l;
                                s2[idx + 1] = r;
                            }
                            p += 2;
                        }
                        chunk.commit_all();
                        track1_pushed += to_push;
                    }
                }
            } else if !track_changed_pushed {
                // Gapless boundary! Track 1 finished pushing, immediately stage Track 2 boundary marker
                boundary_prod
                    .push(BoundaryMarker::track_changed(
                        boundary_frame as u64,
                        "track_2",
                    ))
                    .expect("Push changed");
                track_changed_pushed = true;
            }

            // 2. Seamlessly push Track 2 into the SAME audio ring buffer
            if track_changed_pushed && track2_pushed < track2_frames.len() {
                let avail = audio_prod.slots() / 2;
                let to_push = avail.min(track2_frames.len() - track2_pushed).min(512);
                if to_push > 0 {
                    if let Ok(mut chunk) = audio_prod.write_chunk(to_push * 2) {
                        let (s1, s2) = chunk.as_mut_slices();
                        let mut p = 0;
                        for i in 0..to_push {
                            let (l, r) = track2_frames[track2_pushed + i];
                            if p < s1.len() {
                                s1[p] = l;
                                s1[p + 1] = r;
                            } else {
                                let idx = p - s1.len();
                                s2[idx] = l;
                                s2[idx + 1] = r;
                            }
                            p += 2;
                        }
                        chunk.commit_all();
                        track2_pushed += to_push;
                    }
                }
            } else if track_changed_pushed
                && track2_pushed >= track2_frames.len()
                && !track_ended_pushed
            {
                // EOF of Track 2: push track ended marker
                boundary_prod
                    .push(BoundaryMarker::track_ended(total_frames as u64, "track_2"))
                    .expect("Push ended");
                track_ended_pushed = true;
            }

            // --- CONSUMER (AUDIO CALLBACK) STEP ---
            let frames_left = total_frames - rendered_frames.len();
            let avail_frames = renderer
                .consumer
                .as_ref()
                .map(|c| c.slots() / 2)
                .unwrap_or(0);
            let frames_to_render = frames_left.min(avail_frames).min(256);

            if frames_to_render > 0 {
                let out_slice = &mut render_buf[..frames_to_render * 2];
                renderer.render_interleaved(out_slice, 2);

                for i in 0..frames_to_render {
                    rendered_frames.push((out_slice[i * 2], out_slice[i * 2 + 1]));
                }
            }
        }

        assert_eq!(
            rendered_frames.len(),
            total_frames,
            "Rendered frames count must match reference exactly"
        );

        // Collect all triggered boundary events
        let mut triggered_events = Vec::new();
        while let Ok(m) = triggered_cons.pop() {
            triggered_events.push(m);
        }

        assert_eq!(
            triggered_events.len(),
            3,
            "All 3 boundary markers must be triggered"
        );
        assert_eq!(triggered_events[0].kind, BoundaryKind::TrackStarted);
        assert_eq!(triggered_events[0].file_id_str(), "track_1");
        assert_eq!(triggered_events[0].trigger_at_frame, 0);

        assert_eq!(triggered_events[1].kind, BoundaryKind::TrackChanged);
        assert_eq!(triggered_events[1].file_id_str(), "track_2");
        assert_eq!(triggered_events[1].trigger_at_frame, boundary_frame as u64);

        assert_eq!(triggered_events[2].kind, BoundaryKind::TrackEnded);
        assert_eq!(triggered_events[2].file_id_str(), "track_2");
        assert_eq!(triggered_events[2].trigger_at_frame, total_frames as u64);

        // Verify sample continuity across boundary (frame 47995 .. 48005)
        for i in (boundary_frame - 5)..(boundary_frame + 5) {
            let ref_frame = reference[i];
            let rend_frame = rendered_frames[i];
            assert!(
                (rend_frame.0 - ref_frame.0).abs() < 1e-4,
                "Frame {} L channel discontinuity: ref {} != rend {}",
                i,
                ref_frame.0,
                rend_frame.0
            );
            assert!(
                (rend_frame.1 - ref_frame.1).abs() < 1e-4,
                "Frame {} R channel discontinuity: ref {} != rend {}",
                i,
                ref_frame.1,
                rend_frame.1
            );
        }

        // Verify 1st derivative (slope) continuity across boundary
        let slope_ref = reference[boundary_frame].0 - reference[boundary_frame - 1].0;
        let slope_rend = rendered_frames[boundary_frame].0 - rendered_frames[boundary_frame - 1].0;
        assert!(
            (slope_rend - slope_ref).abs() < 1e-4,
            "Derivative discontinuity across gapless boundary: ref slope {} != rend slope {}",
            slope_ref,
            slope_rend
        );

        eprintln!("=======================================================");
        eprintln!("        Golden Test 5: Gapless Boundary Verified       ");
        eprintln!("=======================================================");
        eprintln!(" Total Rendered Frames: {}", rendered_frames.len());
        eprintln!(" Boundary Frame       : {}", boundary_frame);
        eprintln!(" Discontinuity Delta  : < 1e-4 (Continuous Phase & Slope)");
        eprintln!(" Events Dispatched    : Started -> Changed -> Ended (3/3)");
        eprintln!(" Status               : PASS (True Gapless Playback Verified)");
        eprintln!("=======================================================\n");
    }

    #[test]
    fn test_engine_diagnostics_aggregation() {
        {
            let mut state = PLAYER_STATE.lock().unwrap();
            state.buffered_ms = 4500;
            state.target_sample_rate = 48000;
            state.duration_ms = 240000;
            state.current_track_id = "diag_track".to_string();
            state.buffering = false;
        }

        let diag = engine_get_diagnostics();
        assert!((diag.buffer_ahead_seconds - 4.5).abs() < 1e-4);
        assert!(diag.pcm_fill_percent >= 0.0 && diag.pcm_fill_percent <= 100.0);
        assert_eq!(diag.request_budget_per_minute, 12000);
        assert!(diag.cache_hit_rate >= 0.0 && diag.cache_hit_rate <= 1.0);
        assert!(diag.speed_mbps >= 0.0);
        assert!(diag.decode_load_percent >= 0.0 && diag.decode_load_percent <= 100.0);

        let vis = engine_get_visualizer_frame();
        assert_eq!(vis.spectrum.len(), crate::dsp::VISUALIZER_BANDS);
    }
}

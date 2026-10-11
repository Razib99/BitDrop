#[cfg(target_os = "android")]
use oboe::{
    AudioApi, AudioOutputCallback, AudioOutputStreamSafe, AudioStream, AudioStreamAsync,
    AudioStreamBase,
    AudioStreamBuilder, DataCallbackResult, Output, PerformanceMode, SharingMode, Stereo,
};
use std::sync::{Arc, Mutex};
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
}

#[cfg(target_os = "android")]
lazy_static::lazy_static! {
    static ref ACTIVE_STREAM: Mutex<Option<AudioStreamAsync<Output, PlayerCallback>>> =
        Mutex::new(None);
}



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

/// How long a track-change ramp takes. Long enough to be inaudible as a
/// click, short enough not to feel like a crossfade.
pub const FADE_MS: u32 = 120;


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
}

#[cfg(target_os = "android")]
impl AudioOutputCallback for PlayerCallback {
    // Oboe hands stereo f32 frames over as (left, right) pairs, not as an
    // interleaved flat slice. The decoder's buffers are interleaved, so this
    // callback is where the two representations meet.
    type FrameType = (f32, Stereo);

    fn on_audio_ready(
        &mut self,
        _stream: &mut dyn AudioOutputStreamSafe,
        audio_data: &mut [(f32, f32)],
    ) -> DataCallbackResult {
        // One short lock, then nothing else blocking: this runs on the
        // real-time audio thread and must not allocate or wait.
        let (is_playing, eq_enabled, eq_updated, gains, preamp, fade_target, fade_step) = {
            let mut state = PLAYER_STATE.lock().unwrap();
            let up = state.eq_updated;
            state.eq_updated = false;
            (
                state.is_playing,
                state.eq_enabled,
                up,
                state.eq_gains,
                state.eq_preamp,
                state.fade_target,
                state.fade_step,
            )
        };

        if eq_updated {
            self.eq.update_gains(&gains, preamp);
        }

        if !is_playing {
            for frame in audio_data.iter_mut() {
                *frame = (0.0, 0.0);
            }
            return DataCallbackResult::Continue;
        }

        for frame in audio_data.iter_mut() {
            // Refill from the decoder when the current buffer runs out. A
            // miss means underrun: write silence rather than block.
            if self.buffer_idx + 1 >= self.current_buffer.len() {
                match self.receiver.try_recv() {
                    Ok(next) => {
                        self.current_buffer = next;
                        self.buffer_idx = 0;
                    }
                    Err(_) => {
                        *frame = (0.0, 0.0);
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

            if self.fade_gain < fade_target {
                self.fade_gain = (self.fade_gain + fade_step).min(fade_target);
            } else if self.fade_gain > fade_target {
                self.fade_gain = (self.fade_gain - fade_step).max(fade_target);
            }

            *frame = (l * self.fade_gain, r * self.fade_gain);
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
        state.fade_step = 1.0 / (FADE_MS as f32 * 48.0);
    }

    let (cmd_tx, cmd_rx) = crossbeam_channel::unbounded::<DecoderCmd>();
    *CMD_SENDER.lock().unwrap() = Some(cmd_tx);

    let (audio_tx, audio_rx) = crossbeam_channel::bounded::<Vec<f32>>(20);

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
                // Lives across callbacks: the ramp spans several buffers.
                let mut fade_gain: f32 = 1.0;
                
                let stream = device.build_output_stream(
                    &config,
                    move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                        let (is_playing, eq_enabled, eq_updated, gains, preamp,
                             fade_target, fade_step) = {
                            let mut state = PLAYER_STATE.lock().unwrap();
                            let up = state.eq_updated;
                            state.eq_updated = false;
                            (state.is_playing, state.eq_enabled, up, state.eq_gains,
                             state.eq_preamp, state.fade_target, state.fade_step)
                        };
                        
                        if eq_updated {
                            eq.update_gains(&gains, preamp);
                        }

                        {
                            let mut state = PLAYER_STATE.lock().unwrap();
                            if state.flush_requested {
                                state.flush_requested = false;
                                current_buffer.clear();
                                buffer_idx = 0;
                                while let Ok(_) = audio_rx.try_recv() {}
                            }
                        }

                        if !is_playing {
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
                                    for sample in &mut data[out_idx..] { *sample = 0.0; }
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
                                if fade_gain < fade_target {
                                    fade_gain = (fade_gain + fade_step).min(fade_target);
                                } else if fade_gain > fade_target {
                                    fade_gain = (fade_gain - fade_step).max(fade_target);
                                }
                                l *= fade_gain;
                                r *= fade_gain;

                                data[out_idx] = l;
                                if channels > 1 {
                                    data[out_idx + 1] = r;
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
        // Oboe's builder is type-state: each setter consumes the builder and
        // returns a differently-typed one, so this has to be a single chain.
        // set_callback is only available once direction, channels and format
        // are fixed, and it checks them against the callback's FrameType.
        fn make_callback(rx: crossbeam_channel::Receiver<Vec<f32>>) -> PlayerCallback {
            PlayerCallback {
                receiver: rx,
                current_buffer: Vec::new(),
                buffer_idx: 0,
                // The decoder resamples to the stream rate before sending, so
                // the filters are designed for the output rate.
                eq: GraphicEq::new(48000.0),
                fade_gain: 1.0,
            }
        }

        // Exclusive + LowLatency is the path worth having: it is what gets
        // closest to the hardware. Oboe may silently downgrade sharing mode,
        // so a failure here is not fatal.
        let opened = AudioStreamBuilder::default()
            .set_performance_mode(PerformanceMode::LowLatency)
            .set_sharing_mode(SharingMode::Exclusive)
            .set_audio_api(AudioApi::AAudio)
            .set_output()
            .set_stereo()
            .set_f32()
            .set_callback(make_callback(audio_rx.clone()))
            .open_stream();

        let opened = match opened {
            Ok(stream) => Some(stream),
            Err(e) => {
                eprintln!("[bitdrop] exclusive stream unavailable ({e:?}); \
                           falling back to shared");
                // Shared mode with no low-latency demand works on far more
                // devices, including every pre-Android-14 phone.
                AudioStreamBuilder::default()
                    .set_performance_mode(PerformanceMode::None)
                    .set_sharing_mode(SharingMode::Shared)
                    .set_output()
                    .set_stereo()
                    .set_f32()
                    .set_callback(make_callback(audio_rx.clone()))
                    .open_stream()
                    .map_err(|e| eprintln!("[bitdrop] no audio output: {e:?}"))
                    .ok()
            }
        };

        if let Some(mut stream) = opened {
            PLAYER_STATE.lock().unwrap().target_sample_rate =
                stream.get_sample_rate() as u32;
            let _ = stream.start();
            *ACTIVE_STREAM.lock().unwrap() = Some(stream);
        }
    }

    thread::spawn(move || {
        let mut current_format: Option<Box<dyn symphonia::core::formats::FormatReader>> = None;
        let mut current_decoder: Option<Box<dyn symphonia::core::codecs::Decoder>> = None;
        let mut current_track_id: u32 = 0;
        let mut tb: Option<symphonia::core::units::TimeBase> = None;

        loop {
            // Check for commands
            if let Ok(cmd) = cmd_rx.try_recv() {
                match cmd {
                    DecoderCmd::Play(path) => {
                        // Let the ramp reach silence before cutting the
                        // old track, then flush and ramp the new one in.
                        if PLAYER_STATE.lock().unwrap().is_playing {
                            thread::sleep(std::time::Duration::from_millis(
                                FADE_MS as u64 + 20,
                            ));
                        }
                        {
                            let mut state = PLAYER_STATE.lock().unwrap();
                            state.flush_requested = true;
                            state.position_ms = 0;
                        }
                        let ext = std::path::Path::new(&path)
                            .extension()
                            .and_then(|e| e.to_str())
                            .unwrap_or("")
                            .to_string();

                        match File::open(&path) {
                            Ok(file) => match open_media_source(Box::new(file), &ext) {
                                Some(opened) => {
                                    tb = opened.time_base;
                                    current_track_id = opened.track_id;
                                    current_decoder = Some(opened.decoder);
                                    current_format = Some(opened.format);

                                    let mut state = PLAYER_STATE.lock().unwrap();
                                    state.is_playing = true;
                                    state.position_ms = 0;
                                    state.duration_ms = opened.duration_ms;
                                    state.current_track_id = path.clone();
                                    state.fade_target = 1.0;
                                    state.source_codec = opened.codec.clone();
                                    state.source_sample_rate = opened.sample_rate;
                                    state.source_bits = opened.bits_per_sample;
                                    state.source_channels = opened.channels;
                                }
                                None => eprintln!("[bitdrop] could not decode {}", path),
                            },
                            Err(e) => eprintln!("[bitdrop] could not open {}: {}", path, e),
                        }
                    },
                    DecoderCmd::PlayCloud { file_id, url, auth_token, total_size, cache_dir, ext } => {
                        // Let the ramp reach silence before cutting the
                        // old track, then flush and ramp the new one in.
                        if PLAYER_STATE.lock().unwrap().is_playing {
                            thread::sleep(std::time::Duration::from_millis(
                                FADE_MS as u64 + 20,
                            ));
                        }
                        {
                            let mut state = PLAYER_STATE.lock().unwrap();
                            state.flush_requested = true;
                            state.position_ms = 0;
                        }

                        // Build the streaming source on this thread: it owns a
                        // tokio runtime and blocks inside Read/Seek, so it must
                        // not be constructed on the audio callback thread.
                        match CloudMediaSource::new(
                            file_id.clone(),
                            url,
                            auth_token,
                            total_size,
                            PathBuf::from(cache_dir),
                        ) {
                            Ok(source) => match open_media_source(Box::new(source), &ext) {
                                Some(opened) => {
                                    tb = opened.time_base;
                                    current_track_id = opened.track_id;
                                    current_decoder = Some(opened.decoder);
                                    current_format = Some(opened.format);

                                    let mut state = PLAYER_STATE.lock().unwrap();
                                    state.is_playing = true;
                                    state.position_ms = 0;
                                    state.duration_ms = opened.duration_ms;
                                    state.current_track_id = file_id.clone();
                                    state.fade_target = 1.0;
                                    state.source_codec = opened.codec.clone();
                                    state.source_sample_rate = opened.sample_rate;
                                    state.source_bits = opened.bits_per_sample;
                                    state.source_channels = opened.channels;
                                }
                                None => {
                                    eprintln!("[bitdrop] could not decode cloud track {}", file_id)
                                }
                            },
                            Err(e) => {
                                eprintln!("[bitdrop] could not open cloud track {}: {}", file_id, e)
                            }
                        }
                    },
                    DecoderCmd::Pause => {
                        PLAYER_STATE.lock().unwrap().is_playing = false;
                    },
                    DecoderCmd::Resume => {
                        PLAYER_STATE.lock().unwrap().is_playing = true;
                    },
                    DecoderCmd::Seek(ms) => {
                        if PLAYER_STATE.lock().unwrap().is_playing {
                            thread::sleep(std::time::Duration::from_millis(
                                FADE_MS as u64 + 20,
                            ));
                        }
                        {
                            let mut state = PLAYER_STATE.lock().unwrap();
                            state.flush_requested = true;
                            // Nothing decoded ahead any more, so say so rather
                            // than leaving a stale buffer reading on screen.
                            state.buffered_ms = 0;
                        }
                        if let (Some(format), Some(t)) = (current_format.as_mut(), tb) {
                            let ts = (ms as u64 * t.denom as u64) / (1000 * t.numer as u64);
                            let _ = format.seek(symphonia::core::formats::SeekMode::Coarse, symphonia::core::formats::SeekTo::TimeStamp { ts, track_id: current_track_id });
                            let mut state = PLAYER_STATE.lock().unwrap();
                            state.position_ms = ms;
                            state.fade_target = 1.0;
                        } else {
                            PLAYER_STATE.lock().unwrap().fade_target = 1.0;
                        }
                    },
                    DecoderCmd::Stop => {
                        current_format = None;
                        current_decoder = None;
                        PLAYER_STATE.lock().unwrap().is_playing = false;
                    }
                }
            }

            let is_playing = PLAYER_STATE.lock().unwrap().is_playing;
            if !is_playing || current_format.is_none() {
                thread::sleep(std::time::Duration::from_millis(50));
                continue;
            }

            if let (Some(format), Some(decoder)) = (current_format.as_mut(), current_decoder.as_mut()) {
                if let Ok(packet) = format.next_packet() {
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
                            let _ = audio_tx.send(samples);

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
                            }
                            
                            // Update position based on packet timestamp
                            if let Some(t) = tb {
                                let time = t.calc_time(packet.ts());
                                PLAYER_STATE.lock().unwrap().position_ms = (time.seconds * 1000 + (time.frac * 1000.0) as u64) as u32;
                            }
                        }
                    }
                } else {
                    // EOF
                    PLAYER_STATE.lock().unwrap().is_playing = false;
                    current_format = None;
                    current_decoder = None;
                }
            }
        }
    });
}

/// Begins a track change: ramp to silence here, swap on the decode thread.
///
/// Flushing immediately would cut mid-waveform and click. The decode thread
/// waits for the ramp before it swaps, then ramps back in.
fn begin_switch() -> bool {
    let mut state = PLAYER_STATE.lock().unwrap();
    let was_playing = state.is_playing;
    if was_playing {
        state.fade_target = 0.0;
    } else {
        // Nothing audible to fade; start silent and ramp in.
        state.fade_target = 1.0;
    }
    was_playing
}

#[flutter_rust_bridge::frb(sync)]
pub fn engine_play(path: String) {
    begin_switch();
    if let Some(sender) = CMD_SENDER.lock().unwrap().as_ref() {
        let _ = sender.send(DecoderCmd::Play(path));
    }
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
    begin_switch();
    if let Some(sender) = CMD_SENDER.lock().unwrap().as_ref() {
        let _ = sender.send(DecoderCmd::PlayCloud {
            file_id,
            url,
            auth_token,
            total_size,
            cache_dir,
            ext,
        });
    }
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
/// The ring still holds audio from before the jump, so without a flush the
/// user hears a moment of the old position after landing. Without the ramp,
/// cutting the ring mid-waveform clicks.
#[flutter_rust_bridge::frb(sync)]
pub fn engine_seek(position_ms: u32) {
    {
        let mut state = PLAYER_STATE.lock().unwrap();
        state.flush_requested = true;
        state.position_ms = position_ms;
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
        buffering: state.buffering,
        buffered_ms: state.buffered_ms,
        fetches_in_flight: crate::cloud::media_source::fetches_in_flight() as u32,
        bytes_fetched: crate::cloud::media_source::bytes_fetched() as u64,
    }
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

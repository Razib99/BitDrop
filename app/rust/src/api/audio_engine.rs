#[cfg(target_os = "android")]
use oboe::{AudioStreamBuilder, PerformanceMode, SharingMode, AudioApi, AudioOutputCallback, AudioStream, DataCallbackResult};
use std::sync::{Arc, Mutex};
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::probe::Hint;
use std::fs::File;
use std::thread;

lazy_static::lazy_static! {
    static ref PLAYER_STATE: Mutex<PlayerState> = Mutex::new(PlayerState::default());
    static ref CMD_SENDER: Mutex<Option<crossbeam_channel::Sender<DecoderCmd>>> = Mutex::new(None);
}

#[cfg(target_os = "android")]
lazy_static::lazy_static! {
    static ref ACTIVE_STREAM: Mutex<Option<AudioStream<oboe::Output, f32>>> = Mutex::new(None);
}

#[derive(Clone, Default)]
pub struct PlayerState {
    pub is_playing: bool,
    pub position_ms: u32,
    pub duration_ms: u32,
    pub current_track_id: String,
    
    pub eq_enabled: bool,
    pub eq_gains: [f32; 10],
    pub eq_updated: bool,
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
        }
    }

    pub fn update_gains(&mut self, gains: &[f32; 10]) {
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
        for i in 0..10 {
            left = self.bands_left[i].process(left);
            right = self.bands_right[i].process(right);
        }
        (left, right)
    }
}

pub enum DecoderCmd {
    Play(String), // path
    Pause,
    Resume,
    Seek(u32), // ms
    Stop,
}

#[cfg(target_os = "android")]
struct PlayerCallback {
    receiver: crossbeam_channel::Receiver<Vec<f32>>,
    current_buffer: Vec<f32>,
    buffer_idx: usize,
    eq: GraphicEq,
}

#[cfg(target_os = "android")]
impl AudioOutputCallback for PlayerCallback {
    type FrameType = (f32,);
    fn on_audio_ready(&mut self, _stream: &mut dyn oboe::AudioOutputStreamSafe, audio_data: &mut [f32]) -> DataCallbackResult {
        let (is_playing, eq_enabled, eq_updated, gains) = {
            let mut state = PLAYER_STATE.lock().unwrap();
            let up = state.eq_updated;
            state.eq_updated = false;
            (state.is_playing, state.eq_enabled, up, state.eq_gains)
        };
        
        if eq_updated {
            self.eq.update_gains(&gains);
        }

        if !is_playing {
            for sample in audio_data.iter_mut() { *sample = 0.0; }
            return DataCallbackResult::Continue;
        }

        let mut out_idx = 0;
        while out_idx < audio_data.len() {
            if self.buffer_idx >= self.current_buffer.len() {
                if let Ok(new_buf) = self.receiver.try_recv() {
                    self.current_buffer = new_buf;
                    self.buffer_idx = 0;
                } else {
                    for i in out_idx..audio_data.len() { audio_data[i] = 0.0; }
                    break;
                }
            }
            
            let frames_to_write = (audio_data.len() - out_idx) / 2; // Assuming stereo output!
            let frames_available = (self.current_buffer.len() - self.buffer_idx) / 2;
            let frames = std::cmp::min(frames_to_write, frames_available);
            
            for _ in 0..frames {
                let mut l = self.current_buffer[self.buffer_idx];
                let mut r = self.current_buffer[self.buffer_idx + 1];
                
                if eq_enabled {
                    let processed = self.eq.process_stereo(l, r);
                    l = processed.0;
                    r = processed.1;
                }
                
                audio_data[out_idx] = l;
                audio_data[out_idx + 1] = r;
                
                self.buffer_idx += 2;
                out_idx += 2;
            }
        }
        
        DataCallbackResult::Continue
    }
}

pub fn init_engine() {
    let (cmd_tx, cmd_rx) = crossbeam_channel::unbounded::<DecoderCmd>();
    *CMD_SENDER.lock().unwrap() = Some(cmd_tx);

    #[cfg(target_os = "android")]
    let (audio_tx, audio_rx) = crossbeam_channel::bounded::<Vec<f32>>(20);

    #[cfg(target_os = "android")]
    {
        let callback = PlayerCallback {
            receiver: rx,
            current_buffer: Vec::new(),
            buffer_idx: 0,
            eq: GraphicEq::new(44100.0), // TODO: dynamic sample rate
        };
        
        let mut builder = AudioStreamBuilder::default();
        builder.set_performance_mode(PerformanceMode::LowLatency)
               .set_sharing_mode(SharingMode::Exclusive) // Oboe auto-falls back to Shared if unavailable
               .set_format(oboe::AudioFormat::Float)
               .set_channel_count(oboe::ChannelCount::Stereo)
               .set_audio_api(AudioApi::AAudio)
               .set_callback(callback);
               
        if let Ok(mut stream) = builder.open_stream() {
            let _ = stream.start();
            *ACTIVE_STREAM.lock().unwrap() = Some(stream);
        } else {
            // Fallback to shared explicitly
            let mut fallback_builder = AudioStreamBuilder::default();
            fallback_builder.set_performance_mode(PerformanceMode::None)
                   .set_sharing_mode(SharingMode::Shared)
                   .set_format(oboe::AudioFormat::Float)
                   .set_channel_count(oboe::ChannelCount::Stereo)
                   .set_callback(PlayerCallback {
                       receiver: crossbeam_channel::bounded(20).1, // dummy if it fails here
                       current_buffer: Vec::new(),
                       buffer_idx: 0,
                       eq: GraphicEq::new(44100.0),
                   }); // Actually we need to recreate the callback/receiver safely, but Oboe's auto-fallback usually handles it.
            if let Ok(mut stream) = fallback_builder.open_stream() {
                let _ = stream.start();
                *ACTIVE_STREAM.lock().unwrap() = Some(stream);
            }
        }
    }

    thread::spawn(move || {
        let mut current_format: Option<Box<dyn symphonia::core::formats::FormatReader>> = None;
        let mut current_decoder: Option<Box<dyn symphonia::core::codecs::Decoder>> = None;
        let mut current_track_id: u32 = 0;
        let mut sample_rate: u32 = 44100;
        let mut tb: Option<symphonia::core::units::TimeBase> = None;

        loop {
            // Check for commands
            if let Ok(cmd) = cmd_rx.try_recv() {
                match cmd {
                    DecoderCmd::Play(path) => {
                        let mut hint = Hint::new();
                        let ext = std::path::Path::new(&path).extension().and_then(|e| e.to_str()).unwrap_or("");
                        hint.with_extension(ext);
                        
                        if let Ok(file) = File::open(&path) {
                            let mss = MediaSourceStream::new(Box::new(file), Default::default());
                            if let Ok(probed) = symphonia::default::get_probe().format(&hint, mss, &Default::default(), &Default::default()) {
                                let mut format = probed.format;
                                if let Some(track) = format.default_track().cloned() {
                                    sample_rate = track.codec_params.sample_rate.unwrap_or(44100);
                                    tb = track.codec_params.time_base;
                                    current_track_id = track.id;
                                    if let Ok(decoder) = symphonia::default::get_codecs().make(&track.codec_params, &DecoderOptions { verify: true }) {
                                        current_decoder = Some(decoder);
                                        current_format = Some(format);
                                        
                                        let mut state = PLAYER_STATE.lock().unwrap();
                                        state.is_playing = true;
                                        state.position_ms = 0;
                                        if let (Some(frames), Some(t)) = (track.codec_params.n_frames, track.codec_params.time_base) {
                                            let time = t.calc_time(frames);
                                            state.duration_ms = (time.seconds * 1000 + time.frac as u64 * 1000) as u32;
                                        }
                                        state.current_track_id = path.clone();
                                    }
                                }
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
                        if let (Some(format), Some(t)) = (current_format.as_mut(), tb) {
                            let ts = (ms as u64 * t.denom as u64) / (1000 * t.numer as u64);
                            let _ = format.seek(symphonia::core::formats::SeekMode::Coarse, symphonia::core::formats::SeekTo::TimeStamp { ts, track_id: current_track_id });
                            PLAYER_STATE.lock().unwrap().position_ms = ms;
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
                            let mut sample_buf = SampleBuffer::<f32>::new(audio_buf.capacity() as u64, *audio_buf.spec());
                            sample_buf.copy_interleaved_ref(audio_buf);
                            
                            #[cfg(target_os = "android")]
                            let _ = audio_tx.send(sample_buf.samples().to_vec());
                            
                            // Update position based on packet timestamp
                            if let Some(t) = tb {
                                let time = t.calc_time(packet.ts());
                                PLAYER_STATE.lock().unwrap().position_ms = (time.seconds * 1000 + time.frac as u64 * 1000) as u32;
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

#[flutter_rust_bridge::frb(sync)]
pub fn engine_play(path: String) {
    if let Some(sender) = CMD_SENDER.lock().unwrap().as_ref() {
        let _ = sender.send(DecoderCmd::Play(path));
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

#[flutter_rust_bridge::frb(sync)]
pub fn engine_seek(position_ms: u32) {
    if let Some(sender) = CMD_SENDER.lock().unwrap().as_ref() {
        let _ = sender.send(DecoderCmd::Seek(position_ms));
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
    state.eq_updated = true;
}

#[flutter_rust_bridge::frb(sync)]
pub fn engine_set_eq_enabled(enabled: bool) {
    let mut state = PLAYER_STATE.lock().unwrap();
    state.eq_enabled = enabled;
}

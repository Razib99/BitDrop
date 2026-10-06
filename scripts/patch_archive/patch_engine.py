import re

with open("app/rust/src/api/audio_engine.rs", "r") as f:
    content = f.read()

# 1. Update PlayerState to hold EQ settings
state_struct = """#[derive(Clone, Default)]
pub struct PlayerState {
    pub is_playing: bool,
    pub position_ms: u32,
    pub duration_ms: u32,
    pub current_track_id: String,
    
    pub eq_enabled: bool,
    pub eq_gains: [f32; 10],
    pub eq_updated: bool,
}"""
content = re.sub(r"#\[derive\(Clone, Default\)\]\npub struct PlayerState \{.*?\n\}", state_struct, content, flags=re.DOTALL)

# 2. Biquad & GraphicEq definition
eq_code = """
#[derive(Clone, Copy, Default)]
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
"""

content = content.replace("pub enum DecoderCmd {", eq_code + "\npub enum DecoderCmd {")

# 3. Add `eq` to PlayerCallback
callback_def = """#[cfg(target_os = "android")]
struct PlayerCallback {
    receiver: crossbeam_channel::Receiver<Vec<f32>>,
    current_buffer: Vec<f32>,
    buffer_idx: usize,
    eq: GraphicEq,
}"""
content = re.sub(r"#\[cfg\(target_os = \"android\"\)]\nstruct PlayerCallback \{.*?\n\}", callback_def, content, flags=re.DOTALL)

# 4. Modify `on_audio_ready`
audio_ready_body = """    type FrameType = (f32,);
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
    }"""
content = re.sub(r"    type FrameType = \(f32,\);\n    fn on_audio_ready.*?DataCallbackResult::Continue\n    \}", audio_ready_body, content, flags=re.DOTALL)

# 5. Set channel count in builder, and initialize GraphicEq
init_engine_hook = """        let callback = PlayerCallback {
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
               .set_audio_api(AudioApi::AAudio)"""
content = re.sub(r"        let callback = PlayerCallback \{.*?\.set_audio_api\(AudioApi::AAudio\)", init_engine_hook, content, flags=re.DOTALL)

# 6. Fallback builder init GraphicEq
fallback_hook = """            let mut fallback_builder = AudioStreamBuilder::default();
            fallback_builder.set_performance_mode(PerformanceMode::None)
                   .set_sharing_mode(SharingMode::Shared)
                   .set_format(oboe::AudioFormat::Float)
                   .set_channel_count(oboe::ChannelCount::Stereo)
                   .set_callback(PlayerCallback {
                       receiver: crossbeam_channel::bounded(20).1, // dummy if it fails here
                       current_buffer: Vec::new(),
                       buffer_idx: 0,
                       eq: GraphicEq::new(44100.0),
                   });"""
content = re.sub(r"            let mut fallback_builder = AudioStreamBuilder::default\(\);\n.*?\}\);", fallback_hook, content, flags=re.DOTALL)

with open("app/rust/src/api/audio_engine.rs", "w") as f:
    f.write(content)


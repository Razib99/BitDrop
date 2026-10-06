#[cfg(target_os = "android")]
use oboe::{AudioStreamBuilder, PerformanceMode, SharingMode, AudioApi, AudioOutputCallback, AudioStream, DataCallbackResult};
use std::sync::{Arc, Mutex};
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::probe::Hint;
use std::fs::File;
use std::thread;

#[cfg(target_os = "android")]
lazy_static::lazy_static! {
    static ref ACTIVE_STREAM: Mutex<Option<AudioStream<oboe::Output, f32>>> = Mutex::new(None);
}

#[cfg(target_os = "android")]
struct PlayerCallback {
    receiver: crossbeam_channel::Receiver<Vec<f32>>,
    current_buffer: Vec<f32>,
    buffer_idx: usize,
}

#[cfg(target_os = "android")]
impl AudioOutputCallback for PlayerCallback {
    type FrameType = (f32,); // We'll write interleaved floats directly

    fn on_audio_ready(&mut self, _stream: &mut dyn oboe::AudioOutputStreamSafe, audio_data: &mut [f32]) -> DataCallbackResult {
        for sample in audio_data.iter_mut() {
            if self.buffer_idx >= self.current_buffer.len() {
                if let Ok(new_buf) = self.receiver.try_recv() {
                    self.current_buffer = new_buf;
                    self.buffer_idx = 0;
                } else {
                    // Underrun
                    *sample = 0.0;
                    continue;
                }
            }
            *sample = self.current_buffer[self.buffer_idx];
            self.buffer_idx += 1;
        }
        DataCallbackResult::Continue
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn play_audio_file_android(path: String) -> Result<String, String> {
    #[cfg(not(target_os = "android"))]
    {
        Ok(format!("Playback is only implemented via Oboe for Android in Spike 4. Ignored path: {}", path))
    }

    #[cfg(target_os = "android")]
    {
        // 1. Probe the file
        let mut hint = Hint::new();
        let ext = std::path::Path::new(&path).extension().and_then(|e| e.to_str()).unwrap_or("");
        hint.with_extension(ext);
        
        let file = Box::new(File::open(&path).map_err(|e| e.to_string())?);
        let mss = MediaSourceStream::new(file, Default::default());
        
        let mut probed = symphonia::default::get_probe()
            .format(&hint, mss, &Default::default(), &Default::default())
            .map_err(|e| e.to_string())?;
            
        let mut format = probed.format;
        let track = format.default_track().ok_or("No default track")?.clone();
        
        let sample_rate = track.codec_params.sample_rate.unwrap_or(44100);
        let channels = track.codec_params.channels.map(|c| c.count()).unwrap_or(2) as u32;
        let track_id = track.id;
        
        let mut decoder = symphonia::default::get_codecs()
            .make(&track.codec_params, &DecoderOptions { verify: true })
            .map_err(|e| format!("Decoder init failed: {:?}", e))?;
            
        // 2. Setup Channel for decoder -> audio callback
        let (tx, rx) = crossbeam_channel::bounded::<Vec<f32>>(10);
        
        // 3. Spawn Decoder Thread
        thread::spawn(move || {
            while let Ok(packet) = format.next_packet() {
                if packet.track_id() == track_id {
                    if let Ok(audio_buf) = decoder.decode(&packet) {
                        let mut sample_buf = SampleBuffer::<f32>::new(audio_buf.capacity() as u64, *audio_buf.spec());
                        sample_buf.copy_interleaved_ref(audio_buf);
                        
                        if tx.send(sample_buf.samples().to_vec()).is_err() {
                            break; // Callback disconnected
                        }
                    }
                }
            }
        });
        
        // 4. Setup Oboe Stream
        let callback = PlayerCallback {
            receiver: rx,
            current_buffer: Vec::new(),
            buffer_idx: 0,
        };
        
        let mut builder = AudioStreamBuilder::default();
        builder.set_performance_mode(PerformanceMode::LowLatency)
               .set_sharing_mode(SharingMode::Exclusive)
               .set_sample_rate(sample_rate as i32)
               .set_channel_count(channels as i32)
               .set_format(oboe::AudioFormat::Float)
               .set_audio_api(AudioApi::AAudio)
               .set_callback(callback);
               
        let mut stream = builder.open_stream().map_err(|e| format!("Oboe open failed: {:?}", e))?;
        stream.start().map_err(|e| format!("Oboe start failed: {:?}", e))?;
        
        // Save stream to prevent drop
        *ACTIVE_STREAM.lock().unwrap() = Some(stream);
        
        Ok(format!("Playing {} at {}Hz, {}Ch via AAudio/Exclusive!", path, sample_rate, channels))
    }
}

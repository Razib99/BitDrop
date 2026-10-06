import re

with open("app/rust/src/api/audio_engine.rs", "r") as f:
    content = f.read()

# 1. Add CPAL active stream global
cpal_globals = """
#[cfg(not(target_os = "android"))]
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

#[cfg(not(target_os = "android"))]
lazy_static::lazy_static! {
    static ref CPAL_STREAM: Mutex<Option<cpal::Stream>> = Mutex::new(None);
}
"""
content = re.sub(r"(lazy_static::lazy_static! \{\s*static ref ACTIVE_STREAM:[^\}]+\}\s*)", r"\1\n" + cpal_globals, content)

# 2. Setup the CPAL initialization in `init_audio_engine`
# Before:
#    #[cfg(target_os = "android")]
#    let (audio_tx, audio_rx) = crossbeam_channel::bounded::<Vec<f32>>(20);
# We need to change the audio_tx variable to be used generally. It's actually `tx` and `rx` inside `init_audio_engine`!

cpal_init = """
    #[cfg(not(target_os = "android"))]
    {
        let host = cpal::default_host();
        if let Some(device) = host.default_output_device() {
            if let Ok(config) = device.default_output_config() {
                let sample_format = config.sample_format();
                let config: cpal::StreamConfig = config.into();
                let channels = config.channels as usize;
                
                let mut current_buffer: Vec<f32> = Vec::new();
                let mut buffer_idx = 0;
                let mut eq = GraphicEq::new(config.sample_rate.0 as f32);
                
                let stream = device.build_output_stream(
                    &config,
                    move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                        let (is_playing, eq_enabled, eq_updated, gains) = {
                            let mut state = PLAYER_STATE.lock().unwrap();
                            let up = state.eq_updated;
                            state.eq_updated = false;
                            (state.is_playing, state.eq_enabled, up, state.eq_gains)
                        };
                        
                        if eq_updated {
                            eq.update_gains(&gains);
                        }

                        if !is_playing {
                            for sample in data.iter_mut() { *sample = 0.0; }
                            return;
                        }
                        
                        let mut out_idx = 0;
                        while out_idx < data.len() {
                            if buffer_idx >= current_buffer.len() {
                                if let Ok(new_buf) = rx.try_recv() {
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
                                    let (fl, fr) = eq.process(l, r);
                                    l = fl;
                                    r = fr;
                                }
                                
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
                    *CPAL_STREAM.lock().unwrap() = Some(stream);
                }
            }
        }
    }
"""

content = re.sub(r"(let \(audio_tx, audio_rx\) = crossbeam_channel::bounded::<Vec<f32>>\(20\);)", r"\1\n" + cpal_init, content)

with open("app/rust/src/api/audio_engine.rs", "w") as f:
    f.write(content)

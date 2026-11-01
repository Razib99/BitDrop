use std::sync::atomic::Ordering;
use crate::api::audio_engine::{
    enable_hardware_flush_to_zero, ramp_step,
    CALLBACK_FADE_STEP, CALLBACK_FADE_TARGET, CALLBACK_FLUSH_REQUESTED,
    CALLBACK_FRAMES_PLAYED, CALLBACK_GATE_OUTPUT, CALLBACK_IS_PLAYING,
    DSP_TRIPLE_BUFFER, TRACK_ENDED_FLAG, DUCK_MS,
};
use crate::dsp::{BoundaryKind, BoundaryMarker, DspPipelineV2};

#[derive(Debug, PartialEq, Eq)]
pub enum RenderAction {
    Continue,
    Stop,
}

pub struct OutputRenderer {
    pub consumer: Option<rtrb::Consumer<f32>>,
    pub boundary_consumer: Option<rtrb::Consumer<BoundaryMarker>>,
    pub triggered_producer: Option<rtrb::Producer<BoundaryMarker>>,
    pub dsp: DspPipelineV2,
    pub fade_gain: f32,
    pub duck: f32,
    pub last: (f32, f32),
}

impl OutputRenderer {
    pub fn new(
        sample_rate: f64,
        consumer: Option<rtrb::Consumer<f32>>,
        boundary_consumer: Option<rtrb::Consumer<BoundaryMarker>>,
        triggered_producer: Option<rtrb::Producer<BoundaryMarker>>,
    ) -> Self {
        Self {
            consumer,
            boundary_consumer,
            triggered_producer,
            dsp: DspPipelineV2::new(sample_rate),
            fade_gain: 1.0,
            duck: 1.0,
            last: (0.0, 0.0),
        }
    }

    /// Renders interleaved PCM audio into `out_slice`.
    /// `channels` is typically 2 (stereo).
    pub fn render_interleaved(&mut self, out_slice: &mut [f32], channels: usize) -> RenderAction {
        enable_hardware_flush_to_zero();

        // 1. Read real-time atomic state flags - ZERO mutex locks on the audio thread!
        let is_playing = CALLBACK_IS_PLAYING.load(Ordering::Acquire);
        let gated = CALLBACK_GATE_OUTPUT.load(Ordering::Acquire);
        let flush = CALLBACK_FLUSH_REQUESTED.swap(false, Ordering::AcqRel);
        let fade_target = f32::from_bits(CALLBACK_FADE_TARGET.load(Ordering::Relaxed));
        let fade_step = f32::from_bits(CALLBACK_FADE_STEP.load(Ordering::Relaxed));

        // 2. Fetch pre-computed DSP snapshot from lock-free Triple Buffer
        if let Some(snap) = DSP_TRIPLE_BUFFER.read_new() {
            self.dsp.eq_enabled = snap.eq_enabled;
            if snap.sample_rate > 0.0 && (self.dsp.sample_rate - snap.sample_rate).abs() > 0.5 {
                self.dsp.set_sample_rate(snap.sample_rate);
            }
            if snap.is_parametric {
                self.dsp.install_parameters(
                    &snap.specs[..snap.spec_count],
                    snap.preamp_db,
                    0.0,
                    1.0,
                    snap.balance,
                    snap.mono,
                );
            } else {
                self.dsp.update_graphic_gains(
                    &snap.graphic_gains,
                    snap.preamp_db,
                    0.0,
                    1.0,
                    snap.balance,
                    snap.mono,
                );
            }
        }

        let consumer = match self.consumer.as_mut() {
            Some(c) => c,
            None => return RenderAction::Stop,
        };

        // 3. Handle immediate ring-buffer flush
        if flush {
            let slots = consumer.slots();
            if slots > 0 {
                if let Ok(chunk) = consumer.read_chunk(slots) {
                    chunk.commit_all();
                }
            }
            if let Some(bc) = self.boundary_consumer.as_mut() {
                let b_slots = bc.slots();
                if b_slots > 0 {
                    if let Ok(chunk) = bc.read_chunk(b_slots) {
                        chunk.commit_all();
                    }
                }
            }
            TRACK_ENDED_FLAG.store(false, Ordering::Release);
        }

        let rate = self.dsp.sample_rate as u32;
        let duck_step = ramp_step(DUCK_MS, rate);
        let (want, step) = if !is_playing {
            (0.0, duck_step)
        } else if gated {
            (0.0, fade_step)
        } else {
            (fade_target, fade_step)
        };

        if want <= 0.0 && self.fade_gain <= 0.0 {
            out_slice.fill(0.0);
            return RenderAction::Continue;
        }

        let frames_needed = out_slice.len() / channels;
        let samples_needed = frames_needed * 2;
        let avail_samples = consumer.slots();
        let samples_to_read = samples_needed.min(avail_samples);
        let frames_to_read = samples_to_read / 2;

        if frames_to_read > 0 {
            if let Ok(chunk) = consumer.read_chunk(frames_to_read * 2) {
                let (s1, s2) = chunk.as_slices();
                let mut read_idx = 0;
                let s1_len = s1.len();

                for i in 0..frames_to_read {
                    let (mut l, mut r) = if read_idx + 1 < s1_len {
                        (s1[read_idx], s1[read_idx + 1])
                    } else if read_idx < s1_len {
                        (s1[read_idx], s2[0])
                    } else {
                        let s2_idx = read_idx - s1_len;
                        (s2[s2_idx], s2[s2_idx + 1])
                    };
                    read_idx += 2;

                    let (out_l, out_r) = self.dsp.process_stereo(l as f64, r as f64);
                    l = out_l as f32;
                    r = out_r as f32;

                    if self.fade_gain < want {
                        self.fade_gain = (self.fade_gain + step).min(want);
                    } else if self.fade_gain > want {
                        self.fade_gain = (self.fade_gain - step).max(want);
                    }
                    self.duck = (self.duck + duck_step).min(1.0);

                    self.last = (l, r);
                    let g = self.fade_gain * self.duck;
                    out_slice[i * channels] = l * g;
                    if channels > 1 {
                        out_slice[i * channels + 1] = r * g;
                    }
                    for c in 2..channels {
                        out_slice[i * channels + c] = 0.0;
                    }
                }
                chunk.commit_all();
            }

            let played = CALLBACK_FRAMES_PLAYED.fetch_add(frames_to_read as u64, Ordering::SeqCst) + frames_to_read as u64;

            // Check boundary markers
            if let Some(bc) = self.boundary_consumer.as_mut() {
                while bc.slots() > 0 {
                    if let Ok(chunk) = bc.read_chunk(1) {
                        let marker = chunk.as_slices().0[0];
                        if played >= marker.trigger_at_frame {
                            chunk.commit_all();
                            if marker.kind == BoundaryKind::TrackEnded {
                                CALLBACK_IS_PLAYING.store(false, Ordering::Release);
                                TRACK_ENDED_FLAG.store(true, Ordering::Release);
                            }
                            if let Some(tp) = self.triggered_producer.as_mut() {
                                let _ = tp.push(marker);
                            }
                        } else {
                            break;
                        }
                    } else {
                        break;
                    }
                }
            }
        } else {
            // Buffer is empty - check if boundary marker triggered at EOF
            let played = CALLBACK_FRAMES_PLAYED.load(Ordering::SeqCst);
            if let Some(bc) = self.boundary_consumer.as_mut() {
                while bc.slots() > 0 {
                    if let Ok(chunk) = bc.read_chunk(1) {
                        let marker = chunk.as_slices().0[0];
                        if played >= marker.trigger_at_frame {
                            chunk.commit_all();
                            if marker.kind == BoundaryKind::TrackEnded {
                                CALLBACK_IS_PLAYING.store(false, Ordering::Release);
                                TRACK_ENDED_FLAG.store(true, Ordering::Release);
                            }
                            if let Some(tp) = self.triggered_producer.as_mut() {
                                let _ = tp.push(marker);
                            }
                        } else {
                            break;
                        }
                    } else {
                        break;
                    }
                }
            }
        }

        // Underrun concealment: if fewer frames were available than needed, decay last sample to silence smoothly
        for i in frames_to_read..frames_needed {
            self.duck = (self.duck - duck_step).max(0.0);
            let g = self.fade_gain * self.duck;
            out_slice[i * channels] = self.last.0 * g;
            if channels > 1 {
                out_slice[i * channels + 1] = self.last.1 * g;
            }
            for c in 2..channels {
                out_slice[i * channels + c] = 0.0;
            }
        }

        RenderAction::Continue
    }
}

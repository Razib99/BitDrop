use crate::api::audio_engine::{
    enable_hardware_flush_to_zero, ramp_step, CALLBACK_FADE_STEP, CALLBACK_FADE_TARGET,
    CALLBACK_FLUSH_REQUESTED, CALLBACK_FRAMES_PLAYED, CALLBACK_GATE_OUTPUT, CALLBACK_IS_PLAYING,
    DSP_TRIPLE_BUFFER, DUCK_MS, TRACK_ENDED_FLAG,
};
use crate::dsp::{
    BoundaryKind, BoundaryMarker, DspPipelineV2, VISUALIZER_CLIPPING, VISUALIZER_HEAD,
    VISUALIZER_PEAK_L_MILLIDB, VISUALIZER_PEAK_R_MILLIDB, VISUALIZER_RING_SIZE, VISUALIZER_SAMPLES,
};
use std::sync::atomic::{AtomicU32, Ordering};

pub static ENGINE_UNDERRUNS: AtomicU32 = AtomicU32::new(0);

#[derive(Debug, PartialEq, Eq)]
pub enum RenderAction {
    Continue,
    Stop,
}

pub struct OutputRenderer {
    dsp_config: Option<crate::dsp::TripleConsumer<crate::dsp::DspConfigSnapshot>>,
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
            dsp_config: DSP_TRIPLE_BUFFER.take_consumer(),
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
        let flush = CALLBACK_FLUSH_REQUESTED.load(Ordering::Acquire);
        let fade_target = f32::from_bits(CALLBACK_FADE_TARGET.load(Ordering::Relaxed));
        let fade_step = f32::from_bits(CALLBACK_FADE_STEP.load(Ordering::Relaxed));

        // 2. Fetch pre-computed DSP snapshot from lock-free Triple Buffer
        if let Some(snap) = self
            .dsp_config
            .as_mut()
            .and_then(|reader| reader.read_new())
        {
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
                    CALLBACK_FRAMES_PLAYED.fetch_add((slots / 2) as u64, Ordering::SeqCst);
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
            CALLBACK_FLUSH_REQUESTED.store(false, Ordering::Release);
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
            VISUALIZER_PEAK_L_MILLIDB.store(-90000, Ordering::Relaxed);
            VISUALIZER_PEAK_R_MILLIDB.store(-90000, Ordering::Relaxed);
            return RenderAction::Continue;
        }

        let frames_needed = out_slice.len() / channels;
        let samples_needed = frames_needed * 2;
        let avail_samples = consumer.slots();
        let samples_to_read = samples_needed.min(avail_samples);
        let frames_to_read = samples_to_read / 2;

        let mut block_max_l: f32 = 0.0;
        let mut block_max_r: f32 = 0.0;

        if frames_to_read > 0 {
            if let Ok(chunk) = consumer.read_chunk(frames_to_read * 2) {
                let (s1, s2) = chunk.as_slices();
                let mut read_idx = 0;
                let s1_len = s1.len();
                let mut vis_head = VISUALIZER_HEAD.load(Ordering::Relaxed);

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
                    let rendered_l = l * g;
                    let rendered_r = r * g;

                    out_slice[i * channels] = rendered_l;
                    if channels > 1 {
                        out_slice[i * channels + 1] = rendered_r;
                    }
                    for c in 2..channels {
                        out_slice[i * channels + c] = 0.0;
                    }

                    // Track peaks for visualizer
                    let abs_l = rendered_l.abs();
                    let abs_r = rendered_r.abs();
                    if abs_l > block_max_l {
                        block_max_l = abs_l;
                    }
                    if abs_r > block_max_r {
                        block_max_r = abs_r;
                    }

                    // Record mono sample for visualizer FFT
                    let mono = (rendered_l + rendered_r) * 0.5;
                    VISUALIZER_SAMPLES[vis_head].store(mono.to_bits(), Ordering::Relaxed);
                    vis_head = (vis_head + 1) % VISUALIZER_RING_SIZE;
                }
                VISUALIZER_HEAD.store(vis_head, Ordering::Release);
                chunk.commit_all();
            }

            let played = CALLBACK_FRAMES_PLAYED.fetch_add(frames_to_read as u64, Ordering::SeqCst)
                + frames_to_read as u64;

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

        // Export decayed peak meters and clipping to visualizer atomics
        let cur_l_db = if block_max_l > 1e-5 {
            20.0 * block_max_l.log10()
        } else {
            -90.0
        };
        let cur_r_db = if block_max_r > 1e-5 {
            20.0 * block_max_r.log10()
        } else {
            -90.0
        };

        let prev_l_db = (VISUALIZER_PEAK_L_MILLIDB.load(Ordering::Relaxed) as f32) / 1000.0;
        let prev_r_db = (VISUALIZER_PEAK_R_MILLIDB.load(Ordering::Relaxed) as f32) / 1000.0;

        let new_l_db = if cur_l_db >= prev_l_db {
            cur_l_db
        } else {
            prev_l_db - 1.5
        };
        let new_r_db = if cur_r_db >= prev_r_db {
            cur_r_db
        } else {
            prev_r_db - 1.5
        };

        VISUALIZER_PEAK_L_MILLIDB.store(
            (new_l_db.clamp(-90.0, 6.0) * 1000.0) as i32,
            Ordering::Relaxed,
        );
        VISUALIZER_PEAK_R_MILLIDB.store(
            (new_r_db.clamp(-90.0, 6.0) * 1000.0) as i32,
            Ordering::Relaxed,
        );

        if block_max_l >= 0.999 || block_max_r >= 0.999 {
            VISUALIZER_CLIPPING.store(true, Ordering::Relaxed);
        }

        // Underrun concealment: if fewer frames were available than needed, decay last sample to silence smoothly
        if frames_to_read < frames_needed && is_playing && !gated {
            ENGINE_UNDERRUNS.fetch_add(1, Ordering::Relaxed);
        }
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

impl Drop for OutputRenderer {
    fn drop(&mut self) {
        if let Some(reader) = self.dsp_config.take() {
            DSP_TRIPLE_BUFFER.return_consumer(reader);
        }
        crate::api::audio_engine::return_audio_consumers(
            self.consumer.take(),
            self.boundary_consumer.take(),
            self.triggered_producer.take(),
        );
    }
}

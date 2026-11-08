//! Golden Audio CI Suite: Mandatory Gates 1, 2, 3, 4, 5
//!
//! Evaluates the BitDrop Engine v2 64-bit float precision DSP pipeline and transport against:
//! - Gate 1: Frequency response within ±0.05 dB of mathematical f64 reference across 44.1, 48, 96, 192 kHz.
//! - Gate 2: Zero clipping across all presets with auto-preamp and limiter enabled on 0 dBFS input.
//! - Gate 3: Cryptographic SHA-256 bit-exact identity during neutral bypass.
//! - Gate 4: Offline render to exact last frame without truncation.
//! - Gate 5: Gapless album boundary sample-level continuity with zero dropped or padded frames.

use rust_lib_bitdrop::api::audio_engine::{
    CALLBACK_FADE_STEP, CALLBACK_FADE_TARGET, CALLBACK_FLUSH_REQUESTED, CALLBACK_FRAMES_PLAYED,
    CALLBACK_GATE_OUTPUT, CALLBACK_IS_PLAYING, DSP_TRIPLE_BUFFER, TRACK_ENDED_FLAG,
};
use rust_lib_bitdrop::dsd::decimator::DsdDecimator;
use rust_lib_bitdrop::dsd::dop::DopFramer;
use rust_lib_bitdrop::dsd::dsf::DsfReader;
use rust_lib_bitdrop::dsp::{
    downmix_to_stereo, BoundaryKind, BoundaryMarker, DspConfigSnapshot, DspPipelineV2, EqBandSpec,
    LookaheadLimiterF64, StereoBiquadF64, BUTTERWORTH_Q, DOP_BYPASS_LOCKOUT, EQ_HIGH_SHELF,
    EQ_LOW_SHELF, EQ_PEAK, OCTAVE_PEAK_Q, TRUE_PEAK_COEFFS_4X,
};
use rust_lib_bitdrop::renderer::OutputRenderer;
use rust_lib_bitdrop::usb_dac::streaming::PcmFormat;
use sha2::{Digest, Sha256};
use std::fs::File;
use std::path::Path;
use std::sync::atomic::Ordering;
use std::sync::Mutex;
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

static SUITE_MUTEX: Mutex<()> = Mutex::new(());

#[test]
fn gate_1_eq_frequency_response() {
    let sample_rates = [44100.0, 48000.0, 96000.0, 192000.0];
    let test_freqs = [
        20.0, 31.0, 40.0, 62.0, 100.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0,
        12000.0, 16000.0, 20000.0,
    ];

    for &fs in &sample_rates {
        // 1. Single Peaking Filter (+6 dB at 1 kHz)
        let mut peak_bq = StereoBiquadF64::default();
        peak_bq.set_coeffs(EQ_PEAK, 1000.0, fs, OCTAVE_PEAK_Q, 6.0);

        for &f in &test_freqs {
            if f >= fs * 0.49 {
                continue;
            }
            let w = 2.0 * std::f64::consts::PI * f / fs;
            let (h_re, h_im) = peak_bq.complex_response(w);
            let mag_db = 10.0 * (h_re * h_re + h_im * h_im).log10();

            // Direct mathematical reference evaluation of transfer function H(e^{jw})
            let cos_w = w.cos();
            let sin_w = w.sin();
            let cos_2w = (2.0 * w).cos();
            let sin_2w = (2.0 * w).sin();
            let n_re = peak_bq.b0 + peak_bq.b1 * cos_w + peak_bq.b2 * cos_2w;
            let n_im = -(peak_bq.b1 * sin_w + peak_bq.b2 * sin_2w);
            let d_re = 1.0 + peak_bq.a1 * cos_w + peak_bq.a2 * cos_2w;
            let d_im = -(peak_bq.a1 * sin_w + peak_bq.a2 * sin_2w);
            let ref_mag_db =
                10.0 * ((n_re * n_re + n_im * n_im) / (d_re * d_re + d_im * d_im)).log10();

            assert!(
                (mag_db - ref_mag_db).abs() <= 0.05,
                "Gate 1 failed on Peaking at f={} fs={}: diff={}",
                f,
                fs,
                (mag_db - ref_mag_db).abs()
            );
        }

        // 2. Low Shelf Filter (+6 dB at 105 Hz)
        let mut ls_bq = StereoBiquadF64::default();
        ls_bq.set_coeffs(EQ_LOW_SHELF, 105.0, fs, BUTTERWORTH_Q, 6.0);

        for &f in &test_freqs {
            if f >= fs * 0.49 {
                continue;
            }
            let w = 2.0 * std::f64::consts::PI * f / fs;
            let (h_re, h_im) = ls_bq.complex_response(w);
            let mag_db = 10.0 * (h_re * h_re + h_im * h_im).log10();

            let cos_w = w.cos();
            let sin_w = w.sin();
            let cos_2w = (2.0 * w).cos();
            let sin_2w = (2.0 * w).sin();
            let n_re = ls_bq.b0 + ls_bq.b1 * cos_w + ls_bq.b2 * cos_2w;
            let n_im = -(ls_bq.b1 * sin_w + ls_bq.b2 * sin_2w);
            let d_re = 1.0 + ls_bq.a1 * cos_w + ls_bq.a2 * cos_2w;
            let d_im = -(ls_bq.a1 * sin_w + ls_bq.a2 * sin_2w);
            let ref_mag_db =
                10.0 * ((n_re * n_re + n_im * n_im) / (d_re * d_re + d_im * d_im)).log10();

            assert!(
                (mag_db - ref_mag_db).abs() <= 0.05,
                "Gate 1 failed on Low Shelf at f={} fs={}: diff={}",
                f,
                fs,
                (mag_db - ref_mag_db).abs()
            );
        }

        // 3. High Shelf Filter (+4 dB at 8 kHz)
        let mut hs_bq = StereoBiquadF64::default();
        hs_bq.set_coeffs(EQ_HIGH_SHELF, 8000.0, fs, BUTTERWORTH_Q, 4.0);

        for &f in &test_freqs {
            if f >= fs * 0.49 {
                continue;
            }
            let w = 2.0 * std::f64::consts::PI * f / fs;
            let (h_re, h_im) = hs_bq.complex_response(w);
            let mag_db = 10.0 * (h_re * h_re + h_im * h_im).log10();

            let cos_w = w.cos();
            let sin_w = w.sin();
            let cos_2w = (2.0 * w).cos();
            let sin_2w = (2.0 * w).sin();
            let n_re = hs_bq.b0 + hs_bq.b1 * cos_w + hs_bq.b2 * cos_2w;
            let n_im = -(hs_bq.b1 * sin_w + hs_bq.b2 * sin_2w);
            let d_re = 1.0 + hs_bq.a1 * cos_w + hs_bq.a2 * cos_2w;
            let d_im = -(hs_bq.a1 * sin_w + hs_bq.a2 * sin_2w);
            let ref_mag_db =
                10.0 * ((n_re * n_re + n_im * n_im) / (d_re * d_re + d_im * d_im)).log10();

            assert!(
                (mag_db - ref_mag_db).abs() <= 0.05,
                "Gate 1 failed on High Shelf at f={} fs={}: diff={}",
                f,
                fs,
                (mag_db - ref_mag_db).abs()
            );
        }

        // 4. Complete 10-Band Graphic Bass Preset Cascade
        let mut dsp = DspPipelineV2::new(fs);
        dsp.eq_enabled = true;
        let gains: [f32; 10] = [6.0, 5.0, 3.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
        dsp.update_graphic_gains(&gains, 0.0, 0.0, 1.0, 0.0, false);

        for &f in &test_freqs {
            if f >= fs * 0.49 {
                continue;
            }
            let mag_db = dsp.target_bank.magnitude_db_at(f, fs);

            // Compute product of each individual band's complex response
            let w = 2.0 * std::f64::consts::PI * f / fs;
            let mut total_re = dsp.target_bank.preamp_linear;
            let mut total_im = 0.0f64;
            for i in 0..dsp.target_bank.active {
                let (h_re, h_im) = dsp.target_bank.bands[i].complex_response(w);
                let next_re = total_re * h_re - total_im * h_im;
                let next_im = total_re * h_im + total_im * h_re;
                total_re = next_re;
                total_im = next_im;
            }
            let ref_mag_db = 10.0 * (total_re * total_re + total_im * total_im).log10();

            assert!(
                (mag_db - ref_mag_db).abs() <= 0.05,
                "Gate 1 failed on Graphic cascade at f={} fs={}: diff={}",
                f,
                fs,
                (mag_db - ref_mag_db).abs()
            );
        }
    }
}

#[test]
fn gate_2_zero_clipping_all_presets() {
    let ceiling_linear = 10.0_f64.powf(-1.0 / 20.0); // -1.0 dBFS ceiling
    let sample_rates = [44100.0, 48000.0, 96000.0, 192000.0];

    enum PresetDef {
        Graphic(&'static [f32; 10]),
        Tone(f64, f64),
    }

    let presets: [(&str, PresetDef); 4] = [
        (
            "Graphic Bass (+6, +5, +3, +1 dB)",
            PresetDef::Graphic(&[6.0, 5.0, 3.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]),
        ),
        ("Simple Bass (+6 dB)", PresetDef::Tone(6.0, 0.0)),
        ("Simple Treble (+6 dB)", PresetDef::Tone(0.0, 6.0)),
        (
            "Extreme Bass (+12 dB)",
            PresetDef::Graphic(&[12.0, 12.0, 6.0, 3.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]),
        ),
    ];

    for &fs in &sample_rates {
        for (name, preset) in &presets {
            let mut dsp = DspPipelineV2::new(fs);
            dsp.eq_enabled = true;
            dsp.auto_preamp_enabled = true;

            match preset {
                PresetDef::Graphic(gains) => {
                    dsp.update_graphic_gains(gains, 0.0, 0.0, 1.0, 0.0, false);
                }
                PresetDef::Tone(bass, treble) => {
                    dsp.update_tone_controls(*bass, *treble, 0.0, 0.0, 1.0, 0.0, false);
                }
            }

            // Test 1: Full-scale 0.0 dBFS Sine Sweep from 20 Hz to 20,000 Hz
            let sweep_samples = (fs * 0.5).round() as usize; // 500 ms sweep
            let mut max_sweep_out = 0.0f64;
            for i in 0..sweep_samples {
                let t = i as f64 / fs;
                let freq = 20.0 * (1000.0_f64).powf(t / 0.5);
                let s = (2.0 * std::f64::consts::PI * freq * t).sin(); // 0 dBFS input
                let (out_l, out_r) = dsp.process_stereo(s, s);

                assert!(
                    out_l.abs() <= 1.0,
                    "Gate 2: Sample clipped on {} (L={}) at fs={}",
                    name,
                    out_l,
                    fs
                );
                assert!(
                    out_r.abs() <= 1.0,
                    "Gate 2: Sample clipped on {} (R={}) at fs={}",
                    name,
                    out_r,
                    fs
                );
                max_sweep_out = max_sweep_out.max(out_l.abs()).max(out_r.abs());
            }

            // Bounded by limiter ceiling (-1.0 dBFS)
            assert!(
                max_sweep_out <= ceiling_linear + 1e-5,
                "Gate 2: Peak {} exceeded limiter ceiling {} on {} at fs={}",
                max_sweep_out,
                ceiling_linear,
                name,
                fs
            );

            // Test 2: Multitone Transient Burst (+6 dBFS synthetic overload test)
            let burst_samples = 2048;
            for i in 0..burst_samples {
                let t = i as f64 / fs;
                let s1 = (2.0 * std::f64::consts::PI * 31.0 * t).sin();
                let s2 = (2.0 * std::f64::consts::PI * 62.0 * t).sin();
                let s3 = (2.0 * std::f64::consts::PI * 125.0 * t).sin();
                let s = ((s1 + s2 + s3) / 3.0) * 1.5; // intentional 1.5 peak burst
                let (out_l, out_r) = dsp.process_stereo(s, s);

                assert!(
                    out_l.abs() <= 1.0,
                    "Gate 2: Multitone burst clipped (L={}) on {} at fs={}",
                    out_l,
                    name,
                    fs
                );
                assert!(
                    out_r.abs() <= 1.0,
                    "Gate 2: Multitone burst clipped (R={}) on {} at fs={}",
                    out_r,
                    name,
                    fs
                );
            }
        }
    }

    // Test 3: Real Golden FLAC Files if available in /tmp/bitdrop_golden_flacs/
    let golden_dir = Path::new("/tmp/bitdrop_golden_flacs");
    if golden_dir.exists() {
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

        let gains: [f32; 10] = [6.0, 5.0, 3.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
        for flac_name in &flac_files {
            let flac_path = golden_dir.join(flac_name);
            if !flac_path.exists() {
                continue;
            }

            let file = match File::open(&flac_path) {
                Ok(f) => f,
                Err(_) => continue,
            };

            let mss = MediaSourceStream::new(Box::new(file), Default::default());
            let hint = Hint::new();
            let format_opts = FormatOptions::default();
            let metadata_opts = MetadataOptions::default();
            let mut probed = match symphonia::default::get_probe().format(
                &hint,
                mss,
                &format_opts,
                &metadata_opts,
            ) {
                Ok(p) => p,
                Err(_) => continue,
            };

            let track = match probed
                .format
                .tracks()
                .iter()
                .find(|t| t.codec_params.codec != symphonia::core::codecs::CODEC_TYPE_NULL)
            {
                Some(t) => t,
                None => continue,
            };

            let sample_rate = track.codec_params.sample_rate.unwrap_or(44100);
            let mut decoder = match symphonia::default::get_codecs()
                .make(&track.codec_params, &DecoderOptions::default())
            {
                Ok(d) => d,
                Err(_) => continue,
            };

            let mut track_dsp = DspPipelineV2::new(sample_rate as f64);
            track_dsp.eq_enabled = true;
            track_dsp.auto_preamp_enabled = true;
            track_dsp.update_graphic_gains(&gains, 0.0, 0.0, 1.0, 0.0, false);

            let mut sample_buf = None;
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
                        assert!(out_l.abs() <= 1.0, "FLAC sample clipped on {}", flac_name);
                        assert!(out_r.abs() <= 1.0, "FLAC sample clipped on {}", flac_name);
                    }
                }
            }
        }
    }
}

#[test]
fn gate_3_bit_exact_bypass_hash() {
    let test_rates = [44100.0, 48000.0, 96000.0, 192000.0];

    for &fs in &test_rates {
        let mut dsp = DspPipelineV2::new(fs);
        dsp.eq_enabled = false;
        dsp.replay_gain_db = 0.0;
        dsp.balance = 0.0;
        dsp.mono = false;
        dsp.software_volume = 1.0;

        assert!(
            dsp.is_bit_exact_neutral(),
            "Gate 3: DspPipelineV2 should report bit-exact neutral state at fs={}",
            fs
        );

        // Generate 10,000 stereo frames of pseudo-random non-zero audio samples
        let n_frames = 10_000;
        let mut input_frames = Vec::with_capacity(n_frames);
        let mut state: u64 = 0x123456789abcdef0 ^ (fs as u64);

        for _ in 0..n_frames {
            // Xorshift64 PRNG
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            let l = ((state as f64) / (u64::MAX as f64)) * 2.0 - 1.0;

            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            let r = ((state as f64) / (u64::MAX as f64)) * 2.0 - 1.0;

            input_frames.push((l, r));
        }

        // Hash input stream with SHA-256
        let mut in_hasher = Sha256::new();
        for &(l, r) in &input_frames {
            in_hasher.update(l.to_le_bytes());
            in_hasher.update(r.to_le_bytes());
        }
        let input_hash = in_hasher.finalize();

        // Process frames through DSP pipeline
        let mut output_frames = Vec::with_capacity(n_frames);
        for &(l, r) in &input_frames {
            let (out_l, out_r) = dsp.process_stereo(l, r);
            output_frames.push((out_l, out_r));
        }

        // Hash output stream with SHA-256
        let mut out_hasher = Sha256::new();
        for &(out_l, out_r) in &output_frames {
            out_hasher.update(out_l.to_le_bytes());
            out_hasher.update(out_r.to_le_bytes());
        }
        let output_hash = out_hasher.finalize();

        // Assert cryptographic bit-exact identity
        assert_eq!(
            input_hash, output_hash,
            "Gate 3: SHA-256 hash mismatch during bypass at fs={}",
            fs
        );

        // Assert 100% bit identity for each IEEE 754 float
        for i in 0..n_frames {
            assert_eq!(
                input_frames[i].0.to_bits(),
                output_frames[i].0.to_bits(),
                "Gate 3: L-channel bit deviation at frame {} fs={}",
                i,
                fs
            );
            assert_eq!(
                input_frames[i].1.to_bits(),
                output_frames[i].1.to_bits(),
                "Gate 3: R-channel bit deviation at frame {} fs={}",
                i,
                fs
            );
        }
    }
}

#[test]
fn gate_4_offline_render_last_frame_exact() {
    let _lock = SUITE_MUTEX.lock().unwrap_or_else(|e| e.into_inner());

    // Reset global atomic engine state for test isolation
    CALLBACK_IS_PLAYING.store(true, Ordering::SeqCst);
    CALLBACK_GATE_OUTPUT.store(false, Ordering::SeqCst);
    CALLBACK_FLUSH_REQUESTED.store(false, Ordering::SeqCst);
    CALLBACK_FADE_TARGET.store(1.0f32.to_bits(), Ordering::SeqCst);
    CALLBACK_FADE_STEP.store(1.0f32.to_bits(), Ordering::SeqCst);
    CALLBACK_FRAMES_PLAYED.store(0, Ordering::SeqCst);
    TRACK_ENDED_FLAG.store(false, Ordering::SeqCst);
    DSP_TRIPLE_BUFFER.publish(DspConfigSnapshot::default());

    let golden_dir = Path::new("/tmp/bitdrop_golden_flacs");
    let test_flac = golden_dir.join("01 - O Sajna.flac");
    let mut source_frames: Vec<(f32, f32)> = Vec::new();
    let mut sample_rate = 48000.0;

    if test_flac.exists() {
        if let Ok(file) = File::open(&test_flac) {
            let mss = MediaSourceStream::new(Box::new(file), Default::default());
            let hint = Hint::new();
            let format_opts = FormatOptions::default();
            let metadata_opts = MetadataOptions::default();
            if let Ok(mut probed) =
                symphonia::default::get_probe().format(&hint, mss, &format_opts, &metadata_opts)
            {
                if let Some(track) = probed
                    .format
                    .tracks()
                    .iter()
                    .find(|t| t.codec_params.codec != symphonia::core::codecs::CODEC_TYPE_NULL)
                {
                    let track_id = track.id;
                    if let Some(sr) = track.codec_params.sample_rate {
                        sample_rate = sr as f64;
                    }
                    if let Ok(mut decoder) = symphonia::default::get_codecs()
                        .make(&track.codec_params, &DecoderOptions::default())
                    {
                        let mut sample_buf = None;
                        while let Ok(packet) = probed.format.next_packet() {
                            if packet.track_id() != track_id {
                                continue;
                            }
                            if let Ok(decoded) = decoder.decode(&packet) {
                                let channels = decoded.spec().channels.count();
                                if sample_buf.is_none() {
                                    let spec = *decoded.spec();
                                    let duration = decoded.capacity() as u64;
                                    sample_buf = Some(SampleBuffer::<f32>::new(duration, spec));
                                }
                                if let Some(buf) = sample_buf.as_mut() {
                                    buf.copy_interleaved_ref(decoded);
                                    let stereo = downmix_to_stereo(buf.samples(), channels);
                                    let frames = stereo.len() / 2;
                                    for i in 0..frames {
                                        source_frames.push((stereo[i * 2], stereo[i * 2 + 1]));
                                    }
                                    if source_frames.len() >= 50_000 {
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if source_frames.is_empty() {
        // Deterministic synthetic stream (65,536 frames)
        for i in 0..65536 {
            let l = ((i as f32) * 0.01).sin();
            let r = ((i as f32) * 0.02).cos();
            source_frames.push((l, r));
        }
    }

    assert!(
        !source_frames.is_empty(),
        "Gate 4: Source frames must not be empty"
    );
    let total_source_frames = source_frames.len();
    let expected_last_frame = *source_frames.last().unwrap();

    // Setup SPSC PCM audio ring buffer & boundary marker queues
    let (mut audio_prod, audio_cons) = rtrb::RingBuffer::<f32>::new(16384);
    let (mut boundary_prod, boundary_cons) = rtrb::RingBuffer::<BoundaryMarker>::new(32);
    let (triggered_prod, mut triggered_cons) = rtrb::RingBuffer::<BoundaryMarker>::new(32);

    let mut renderer = OutputRenderer::new(
        sample_rate,
        Some(audio_cons),
        Some(boundary_cons),
        Some(triggered_prod),
    );
    renderer.dsp.eq_enabled = false; // Bit-exact neutral bypass

    let mut rendered_frames: Vec<(f32, f32)> = Vec::with_capacity(total_source_frames);
    let mut source_idx = 0;
    let mut eof_reached = false;
    let mut render_buf = [0.0f32; 512]; // 256 stereo frames

    let mut iterations = 0;
    while (!TRACK_ENDED_FLAG.load(Ordering::Acquire) || rendered_frames.len() < total_source_frames)
        && iterations < 1_000_000
    {
        iterations += 1;

        // --- DECODER THREAD STEP ---
        if !eof_reached {
            let avail_slots = audio_prod.slots();
            let frames_to_push = (avail_slots / 2)
                .min(total_source_frames - source_idx)
                .min(512);
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
                }
            }

            if source_idx >= total_source_frames {
                eof_reached = true;
                let marker =
                    BoundaryMarker::track_ended(total_source_frames as u64, "golden_track");
                boundary_prod.push(marker).expect("Push boundary marker");
            }
        }

        // --- OUTPUT RENDERER STEP ---
        let frames_left = total_source_frames - rendered_frames.len();
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
        } else if eof_reached && !TRACK_ENDED_FLAG.load(Ordering::Acquire) {
            let out_slice = &mut render_buf[..0];
            renderer.render_interleaved(out_slice, 2);
        }
    }

    assert!(
        TRACK_ENDED_FLAG.load(Ordering::Acquire),
        "Gate 4: TrackEnded must fire at EOF"
    );
    assert_eq!(
        rendered_frames.len(),
        total_source_frames,
        "Gate 4: Rendered frames must exactly equal source frames (no cut-off ending)"
    );
    let actual_last_frame = *rendered_frames.last().unwrap();
    assert_eq!(
        actual_last_frame.0.to_bits(),
        expected_last_frame.0.to_bits(),
        "Gate 4: L-channel last frame bit-exact match"
    );
    assert_eq!(
        actual_last_frame.1.to_bits(),
        expected_last_frame.1.to_bits(),
        "Gate 4: R-channel last frame bit-exact match"
    );
    assert_eq!(
        renderer.consumer.as_ref().unwrap().slots(),
        0,
        "Gate 4: All frames in ring buffer must be consumed"
    );

    let triggered = triggered_cons
        .pop()
        .expect("Gate 4: Triggered event must be present");
    assert_eq!(triggered.kind, BoundaryKind::TrackEnded);
    assert_eq!(triggered.trigger_at_frame, total_source_frames as u64);
    assert_eq!(triggered.file_id_str(), "golden_track");

    for i in 0..total_source_frames {
        assert_eq!(
            rendered_frames[i].0.to_bits(),
            source_frames[i].0.to_bits(),
            "Gate 4: Frame {} L bit deviation",
            i
        );
        assert_eq!(
            rendered_frames[i].1.to_bits(),
            source_frames[i].1.to_bits(),
            "Gate 4: Frame {} R bit deviation",
            i
        );
    }
}

#[test]
fn gate_5_gapless_boundary_continuity() {
    let _lock = SUITE_MUTEX.lock().unwrap_or_else(|e| e.into_inner());

    let sample_rate = 48000.0;
    let total_frames = 96000; // 2.0 seconds
    let boundary_frame = 48000; // 1.0 second album track transition

    // 1. Generate mathematical continuous 440 Hz reference sine wave
    let freq = 440.0;
    let mut reference = Vec::with_capacity(total_frames);
    for n in 0..total_frames {
        let t = (n as f64) / sample_rate;
        let val = (2.0 * std::f64::consts::PI * freq * t).sin() as f32;
        reference.push((val, val));
    }

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
    DSP_TRIPLE_BUFFER.publish(DspConfigSnapshot::default());

    // Setup SPSC ring buffers
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
        .push(BoundaryMarker::track_started(0, "album_track_1"))
        .expect("Push track 1 start marker");

    let mut track1_pushed = 0;
    let mut track2_pushed = 0;
    let mut track_changed_pushed = false;
    let mut track_ended_pushed = false;

    let mut rendered_frames: Vec<(f32, f32)> = Vec::with_capacity(total_frames);
    let mut render_buf = [0.0f32; 512]; // 256 stereo frames

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
            // Gapless boundary: Track 1 finished pushing, immediately stage Track 2 boundary marker
            boundary_prod
                .push(BoundaryMarker::track_changed(
                    boundary_frame as u64,
                    "album_track_2",
                ))
                .expect("Push track changed marker");
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
                .push(BoundaryMarker::track_ended(
                    total_frames as u64,
                    "album_track_2",
                ))
                .expect("Push track ended marker");
            track_ended_pushed = true;
        }

        // --- CONSUMER (OUTPUT RENDERER) STEP ---
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
        } else if track_ended_pushed && !TRACK_ENDED_FLAG.load(Ordering::Acquire) {
            let out_slice = &mut render_buf[..0];
            renderer.render_interleaved(out_slice, 2);
        }
    }

    assert_eq!(
        rendered_frames.len(),
        total_frames,
        "Gate 5: Total rendered frames must match reference exactly (zero dropped, zero padded)"
    );

    // Collect all triggered boundary events
    let mut triggered_events = Vec::new();
    while let Ok(m) = triggered_cons.pop() {
        triggered_events.push(m);
    }

    assert_eq!(
        triggered_events.len(),
        3,
        "Gate 5: Exactly 3 boundary markers must be triggered"
    );
    assert_eq!(triggered_events[0].kind, BoundaryKind::TrackStarted);
    assert_eq!(triggered_events[0].file_id_str(), "album_track_1");
    assert_eq!(triggered_events[0].trigger_at_frame, 0);

    assert_eq!(triggered_events[1].kind, BoundaryKind::TrackChanged);
    assert_eq!(triggered_events[1].file_id_str(), "album_track_2");
    assert_eq!(triggered_events[1].trigger_at_frame, boundary_frame as u64);

    assert_eq!(triggered_events[2].kind, BoundaryKind::TrackEnded);
    assert_eq!(triggered_events[2].file_id_str(), "album_track_2");
    assert_eq!(triggered_events[2].trigger_at_frame, total_frames as u64);

    // Verify sample continuity across boundary (frame boundary - 20 .. boundary + 20)
    for i in (boundary_frame - 20)..(boundary_frame + 20) {
        let ref_frame = reference[i];
        let rend_frame = rendered_frames[i];
        assert!(
            (rend_frame.0 - ref_frame.0).abs() < 1e-4,
            "Gate 5: Frame {} L channel discontinuity: ref {} != rend {}",
            i,
            ref_frame.0,
            rend_frame.0
        );
        assert!(
            (rend_frame.1 - ref_frame.1).abs() < 1e-4,
            "Gate 5: Frame {} R channel discontinuity: ref {} != rend {}",
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
        "Gate 5: Slope discontinuity across gapless boundary: ref {} != rend {}",
        slope_ref,
        slope_rend
    );

    // Bit-exact identity check across entire stream
    for i in 0..total_frames {
        assert_eq!(
            rendered_frames[i].0.to_bits(),
            reference[i].0.to_bits(),
            "Gate 5: Sample {} L channel bit deviation",
            i
        );
        assert_eq!(
            rendered_frames[i].1.to_bits(),
            reference[i].1.to_bits(),
            "Gate 5: Sample {} R channel bit deviation",
            i
        );
    }

    assert_eq!(
        renderer.consumer.as_ref().unwrap().slots(),
        0,
        "Gate 5: Ring buffer must be completely drained at end"
    );
    assert!(
        TRACK_ENDED_FLAG.load(Ordering::Acquire),
        "Gate 5: TrackEnded flag must be set"
    );
}

#[test]
fn flushed_frames_preserve_future_boundary_positions() {
    let _guard = SUITE_MUTEX.lock().unwrap();
    CALLBACK_FRAMES_PLAYED.store(0, Ordering::SeqCst);
    CALLBACK_IS_PLAYING.store(true, Ordering::Release);
    CALLBACK_GATE_OUTPUT.store(false, Ordering::Release);
    CALLBACK_FADE_TARGET.store(1.0f32.to_bits(), Ordering::Release);
    CALLBACK_FADE_STEP.store(1.0f32.to_bits(), Ordering::Release);
    TRACK_ENDED_FLAG.store(false, Ordering::Release);
    let (mut producer, consumer) = rtrb::RingBuffer::new(32);
    let (mut markers, boundary_consumer) = rtrb::RingBuffer::new(8);
    let mut renderer = OutputRenderer::new(48000.0, Some(consumer), Some(boundary_consumer), None);
    for _ in 0..8 {
        producer.push(0.25).unwrap();
    }
    markers.push(BoundaryMarker::track_ended(4, "old")).unwrap();
    CALLBACK_FLUSH_REQUESTED.store(true, Ordering::Release);
    renderer.render_interleaved(&mut [0.0; 4], 2);
    assert!(!CALLBACK_FLUSH_REQUESTED.load(Ordering::Acquire));
    assert_eq!(CALLBACK_FRAMES_PLAYED.load(Ordering::Acquire), 4);
    assert!(!TRACK_ENDED_FLAG.load(Ordering::Acquire));
    for _ in 0..4 {
        producer.push(0.25).unwrap();
    }
    markers.push(BoundaryMarker::track_ended(6, "new")).unwrap();
    renderer.render_interleaved(&mut [0.0; 4], 2);
    assert_eq!(CALLBACK_FRAMES_PLAYED.load(Ordering::Acquire), 6);
    assert!(TRACK_ENDED_FLAG.load(Ordering::Acquire));
}

#[test]
fn gate_7_multi_container_decode_and_sample_count_exactness() {
    let _lock = SUITE_MUTEX.lock().unwrap_or_else(|e| e.into_inner());

    let fixtures_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");

    // 1. WAV 32-bit float / 48 kHz (100 ms = 4800 frames)
    let wav_path = fixtures_dir.join("canonical_test.wav");
    assert!(
        wav_path.exists(),
        "canonical_test.wav must exist in fixtures"
    );

    let file = File::open(&wav_path).expect("Open canonical WAV");
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    hint.with_extension("wav");
    let format_opts = FormatOptions::default();
    let metadata_opts = MetadataOptions::default();
    let mut probed = symphonia::default::get_probe()
        .format(&hint, mss, &format_opts, &metadata_opts)
        .expect("Probe canonical WAV");

    let (track_id, codec_params) = {
        let track = probed.format.default_track().expect("Default track");
        assert_eq!(track.codec_params.sample_rate.unwrap(), 48000);
        assert_eq!(track.codec_params.channels.unwrap().count(), 2);
        (track.id, track.codec_params.clone())
    };

    let mut decoder = symphonia::default::get_codecs()
        .make(&codec_params, &DecoderOptions::default())
        .expect("Make WAV decoder");

    let mut decoded_frames: Vec<(f32, f32)> = Vec::new();
    let mut sample_buf = None;

    while let Ok(packet) = probed.format.next_packet() {
        if packet.track_id() != track_id {
            continue;
        }
        if let Ok(decoded) = decoder.decode(&packet) {
            if sample_buf.is_none() {
                sample_buf = Some(SampleBuffer::<f32>::new(
                    decoded.capacity() as u64,
                    *decoded.spec(),
                ));
            }
            if let Some(buf) = sample_buf.as_mut() {
                buf.copy_interleaved_ref(decoded);
                let samples = buf.samples();
                for chunk in samples.chunks(2) {
                    decoded_frames.push((chunk[0], chunk[1]));
                }
            }
        }
    }

    assert_eq!(
        decoded_frames.len(),
        4800,
        "Gate 7: Canonical WAV 100ms must yield exactly 4800 frames"
    );

    // Compute RMS error against mathematical reference
    let mut sq_err_sum = 0.0f64;
    for (n, frame) in decoded_frames.iter().enumerate() {
        let t = n as f64 / 48000.0;
        let ref_l = 0.5 * (2.0 * std::f64::consts::PI * 440.0 * t).sin();
        let ref_r = 0.5 * (2.0 * std::f64::consts::PI * 880.0 * t).cos();
        let err_l = frame.0 as f64 - ref_l;
        let err_r = frame.1 as f64 - ref_r;
        sq_err_sum += err_l * err_l + err_r * err_r;
    }
    let rms_err = (sq_err_sum / (decoded_frames.len() * 2) as f64).sqrt();
    assert!(
        rms_err < 1e-6,
        "Gate 7: Lossless WAV reconstruction RMS error must be < 1e-6, got: {}",
        rms_err
    );

    // 2. DSF DSD64 2.8224 MHz (100 ms = 282,240 samples per channel)
    let dsf_path = fixtures_dir.join("canonical_test.dsf");
    assert!(
        dsf_path.exists(),
        "canonical_test.dsf must exist in fixtures"
    );

    let dsf_file = File::open(&dsf_path).expect("Open canonical DSF");
    let mut dsf_reader =
        DsfReader::open(Box::new(dsf_file)).expect("Open DsfReader on canonical fixture");
    let header = *dsf_reader.header();
    assert_eq!(header.sample_rate, 2_822_400);
    assert_eq!(header.channel_num, 2);
    assert_eq!(header.sample_count, 282_240);

    let mut decimator =
        DsdDecimator::new(2_822_400, 176_400).expect("Create DsdDecimator for Gate 7");
    let mut dsd_l = [0u8; 4096];
    let mut dsd_r = [0u8; 4096];
    let mut total_pcm_frames = 0;

    while let Ok(bytes_read) = dsf_reader.read_stereo_bytes(&mut dsd_l, &mut dsd_r) {
        if bytes_read == 0 {
            break;
        }
        let mut pcm_l = Vec::new();
        let mut pcm_r = Vec::new();
        decimator.process_stereo(
            &dsd_l[..bytes_read],
            &dsd_r[..bytes_read],
            &mut pcm_l,
            &mut pcm_r,
        );
        total_pcm_frames += pcm_l.len();
    }
    assert_eq!(
        total_pcm_frames, 17640,
        "Gate 7: Canonical DSF 100ms must decimate to exactly 17,640 frames"
    );

    // 3. FLAC canonical test fixture
    let flac_path = fixtures_dir.join("canonical_test.flac");
    if flac_path.exists() {
        let flac_file = File::open(&flac_path).expect("Open canonical FLAC");
        let mss = MediaSourceStream::new(Box::new(flac_file), Default::default());
        let mut hint = Hint::new();
        hint.with_extension("flac");
        if let Ok(mut probed) = symphonia::default::get_probe().format(
            &hint,
            mss,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        ) {
            let (track_id, codec_params) = {
                let track = probed.format.default_track().expect("FLAC default track");
                (track.id, track.codec_params.clone())
            };
            if let Ok(mut decoder) =
                symphonia::default::get_codecs().make(&codec_params, &DecoderOptions::default())
            {
                let mut flac_frames = 0;
                while let Ok(packet) = probed.format.next_packet() {
                    if packet.track_id() != track_id {
                        continue;
                    }
                    if let Ok(decoded) = decoder.decode(&packet) {
                        flac_frames += decoded.frames();
                    }
                }
                assert!(flac_frames > 0, "Gate 7: FLAC must decode non-zero frames");
            }
        }
    }

    // 4. MP3 canonical test fixture
    let mp3_path = fixtures_dir.join("canonical_test.mp3");
    if mp3_path.exists() {
        let mp3_file = File::open(&mp3_path).expect("Open canonical MP3");
        let mss = MediaSourceStream::new(Box::new(mp3_file), Default::default());
        let mut hint = Hint::new();
        hint.with_extension("mp3");
        if let Ok(mut probed) = symphonia::default::get_probe().format(
            &hint,
            mss,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        ) {
            let (track_id, codec_params) = {
                let track = probed.format.default_track().expect("MP3 default track");
                assert_eq!(track.codec_params.sample_rate.unwrap(), 44100);
                (track.id, track.codec_params.clone())
            };
            if let Ok(mut decoder) =
                symphonia::default::get_codecs().make(&codec_params, &DecoderOptions::default())
            {
                let mut mp3_frames = 0;
                while let Ok(packet) = probed.format.next_packet() {
                    if packet.track_id() != track_id {
                        continue;
                    }
                    if let Ok(decoded) = decoder.decode(&packet) {
                        mp3_frames += decoded.frames();
                    }
                }
                assert!(mp3_frames > 0, "Gate 7: MP3 must decode non-zero frames");
            }
        }
    }
}

#[test]
fn gate_8_sample_accurate_gapless_transition_across_containers() {
    let _lock = SUITE_MUTEX.lock().unwrap_or_else(|e| e.into_inner());

    CALLBACK_IS_PLAYING.store(true, Ordering::SeqCst);
    CALLBACK_GATE_OUTPUT.store(false, Ordering::SeqCst);
    CALLBACK_FLUSH_REQUESTED.store(false, Ordering::SeqCst);
    CALLBACK_FADE_TARGET.store(1.0f32.to_bits(), Ordering::SeqCst);
    CALLBACK_FADE_STEP.store(1.0f32.to_bits(), Ordering::SeqCst);
    CALLBACK_FRAMES_PLAYED.store(0, Ordering::SeqCst);
    TRACK_ENDED_FLAG.store(false, Ordering::SeqCst);
    DSP_TRIPLE_BUFFER.publish(DspConfigSnapshot::default());

    let fs = 48000.0f64;
    let f_hz = 1000.0f64;
    let omega = 2.0 * std::f64::consts::PI * f_hz / fs;
    let phi_0 = 1.134f64; // arbitrary non-zero-crossing phase angle

    let n1 = 4096usize; // Track 1 frames
    let n2 = 4096usize; // Track 2 frames
    let total_frames = n1 + n2;

    // Track 1 frames (n = 0 .. n1 - 1)
    let mut track1_frames = Vec::with_capacity(n1);
    for n in 0..n1 {
        let val = (0.5 * (omega * n as f64 + phi_0).sin()) as f32;
        track1_frames.push((val, val));
    }

    // Track 2 continues phase exactly from n1
    let mut track2_frames = Vec::with_capacity(n2);
    for n in 0..n2 {
        let val = (0.5 * (omega * (n1 + n) as f64 + phi_0).sin()) as f32;
        track2_frames.push((val, val));
    }

    let (mut audio_prod, audio_cons) = rtrb::RingBuffer::<f32>::new(16384);
    let (mut boundary_prod, boundary_cons) = rtrb::RingBuffer::<BoundaryMarker>::new(32);
    let (triggered_prod, mut triggered_cons) = rtrb::RingBuffer::<BoundaryMarker>::new(32);

    let mut renderer = OutputRenderer::new(
        fs,
        Some(audio_cons),
        Some(boundary_cons),
        Some(triggered_prod),
    );

    // Push Track 1
    boundary_prod
        .push(BoundaryMarker::track_started(0, "gapless_track_1"))
        .unwrap();
    for frame in &track1_frames {
        audio_prod.push(frame.0).unwrap();
        audio_prod.push(frame.1).unwrap();
    }

    // Push boundary marker
    boundary_prod
        .push(BoundaryMarker::track_changed(n1 as u64, "gapless_track_2"))
        .unwrap();

    // Push Track 2
    for frame in &track2_frames {
        audio_prod.push(frame.0).unwrap();
        audio_prod.push(frame.1).unwrap();
    }

    // Push track ended marker
    boundary_prod
        .push(BoundaryMarker::track_ended(
            total_frames as u64,
            "gapless_track_2",
        ))
        .unwrap();

    // Render all frames
    let mut rendered: Vec<(f32, f32)> = Vec::with_capacity(total_frames);
    let mut chunk_buf = [0.0f32; 512];

    while rendered.len() < total_frames {
        let to_render = (total_frames - rendered.len()).min(256);
        let out_slice = &mut chunk_buf[..to_render * 2];
        renderer.render_interleaved(out_slice, 2);
        for i in 0..to_render {
            rendered.push((out_slice[i * 2], out_slice[i * 2 + 1]));
        }
    }

    assert_eq!(rendered.len(), total_frames);

    // Assert sample continuity across the boundary
    let y_boundary_prev = rendered[n1 - 1].0;
    let y_boundary_curr = rendered[n1].0;
    let expected_prev = (0.5 * (omega * (n1 - 1) as f64 + phi_0).sin()) as f32;
    let expected_curr = (0.5 * (omega * n1 as f64 + phi_0).sin()) as f32;

    assert!(
        (y_boundary_prev - expected_prev).abs() < 1e-6,
        "Gate 8: Pre-boundary sample mismatch: {} vs {}",
        y_boundary_prev,
        expected_prev
    );
    assert!(
        (y_boundary_curr - expected_curr).abs() < 1e-6,
        "Gate 8: Post-boundary sample mismatch: {} vs {}",
        y_boundary_curr,
        expected_curr
    );

    // Assert 1st derivative (slope) continuity across track boundary
    let delta_boundary = y_boundary_curr - y_boundary_prev;
    let delta_expected = expected_curr - expected_prev;
    let slope_diff = (delta_boundary - delta_expected).abs();

    assert!(
        slope_diff < 1e-6,
        "Gate 8: Slope discontinuity across track boundary: |{} - {}| = {} >= 1e-6",
        delta_boundary,
        delta_expected,
        slope_diff
    );

    // Check triggered boundary events
    let mut events = Vec::new();
    while let Ok(ev) = triggered_cons.pop() {
        events.push(ev);
    }
    assert_eq!(
        events.len(),
        3,
        "Gate 8: Exactly 3 boundary events must fire"
    );
    assert_eq!(events[0].trigger_at_frame, 0);
    assert_eq!(events[1].trigger_at_frame, n1 as u64);
    assert_eq!(events[2].trigger_at_frame, total_frames as u64);
}

#[test]
fn gate_9_ebu_sqam_inter_sample_clipping_torture_test() {
    let _lock = SUITE_MUTEX.lock().unwrap_or_else(|e| e.into_inner());

    let fs = 48000.0f64;
    let mut limiter = LookaheadLimiterF64::new(fs);

    // EBU SQAM Pathological Inter-Sample Clipping Signal:
    // f = fs / 4, phase = pi / 4, peak amplitude = sqrt(2) linear (+3.01 dBFS).
    // Sampled at discrete times n: x[n] = sqrt(2) * sin(n * pi/2 + pi/4)
    // Every single sample has |x[n]| = 1.0 (0.0 dBFS discrete peak),
    // but the analog reconstructed inter-sample peak reaches +3.01 dBTP.
    let sqrt2 = std::f64::consts::SQRT_2;
    let num_samples = 4800; // 100 ms
    let mut input_samples = Vec::with_capacity(num_samples);

    for n in 0..num_samples {
        let val =
            sqrt2 * (n as f64 * std::f64::consts::FRAC_PI_2 + std::f64::consts::FRAC_PI_4).sin();
        input_samples.push(val);
    }

    // Verify discrete-time peak is strictly <= 1.0000001 (0 dBFS)
    for &s in &input_samples {
        assert!(
            s.abs() <= 1.0000001,
            "Discrete sample peak must not exceed 0 dBFS"
        );
    }

    // Process through Lookahead True-Peak Limiter
    let mut limited_output = Vec::with_capacity(num_samples);
    for &s in &input_samples {
        let (out_l, _) = limiter.process_stereo(s, s);
        limited_output.push(out_l);
    }

    // Reconstruct 4x true-peak values on the output using ITU-R BS.1770-4 4x polyphase filter
    // Skip initial lookahead settling runway (~150 samples)
    let max_inter_sample_peak = {
        let mut history = [0.0f64; 12];
        let mut hist_idx = 0;
        let mut peak = 0.0f64;

        for (i, &s) in limited_output.iter().enumerate() {
            history[hist_idx] = s;
            hist_idx = (hist_idx + 1) % 12;

            if i >= 150 {
                // Evaluate all 4 phases of ITU-R BS.1770-4 filter
                for phase_coeffs in &TRUE_PEAK_COEFFS_4X {
                    let mut interp = 0.0f64;
                    for (tap, &coeff) in phase_coeffs.iter().enumerate() {
                        let idx = (hist_idx + 12 - 1 - tap) % 12;
                        interp += history[idx] * coeff;
                    }
                    if interp.abs() > peak {
                        peak = interp.abs();
                    }
                }
            }
        }
        peak
    };

    // -1.0 dBTP + 0.05 dB tolerance = -0.95 dBTP = 10^(-0.95/20) ~ 0.89639
    let ceiling_with_tolerance = 10.0_f64.powf(-0.95 / 20.0);
    assert!(
        max_inter_sample_peak <= ceiling_with_tolerance,
        "Gate 9: 4x reconstructed inter-sample peak ({}) exceeded -1.0 dBTP + 0.05dB tolerance ({})",
        max_inter_sample_peak,
        ceiling_with_tolerance
    );
}

#[test]
fn gate_10_dop_v1_1_dsp_bypass_lockout_invariant() {
    let _lock = SUITE_MUTEX.lock().unwrap_or_else(|e| e.into_inner());

    CALLBACK_IS_PLAYING.store(true, Ordering::SeqCst);
    CALLBACK_GATE_OUTPUT.store(false, Ordering::SeqCst);
    CALLBACK_FLUSH_REQUESTED.store(false, Ordering::SeqCst);
    CALLBACK_FADE_TARGET.store(1.0f32.to_bits(), Ordering::SeqCst);
    CALLBACK_FADE_STEP.store(1.0f32.to_bits(), Ordering::SeqCst);
    CALLBACK_FRAMES_PLAYED.store(0, Ordering::SeqCst);
    TRACK_ENDED_FLAG.store(false, Ordering::SeqCst);

    // Configure aggressive DSP: +6 dB preamp, peaking filter boost, auto-gain
    let mut specs = [EqBandSpec::default(); 16];
    specs[0] = EqBandSpec {
        kind: EQ_PEAK,
        freq: 1000.0,
        q: 1.0,
        gain_db: 6.0,
    };
    let snap = DspConfigSnapshot {
        eq_enabled: true,
        preamp_db: 6.0,
        is_parametric: true,
        specs,
        spec_count: 1,
        dop_active: true, // Hardware DoP lockout flag
        ..Default::default()
    };
    DSP_TRIPLE_BUFFER.publish(snap);

    // Also activate global atomic lockout flag
    DOP_BYPASS_LOCKOUT.store(true, Ordering::Release);

    let (mut audio_prod, audio_cons) = rtrb::RingBuffer::<f32>::new(4096);
    let mut renderer = OutputRenderer::new(176400.0, Some(audio_cons), None, None);
    renderer.dsp.dop_active = true;

    // Create 512 stereo DoP v1.1 frames (1024 DSD bytes per channel)
    let mut framer = DopFramer::new(PcmFormat::S24_3Le).expect("Create DopFramer");
    let mut dsd_l = Vec::new();
    let mut dsd_r = Vec::new();
    for i in 0..1024 {
        dsd_l.push((i * 17) as u8);
        dsd_r.push((i * 31) as u8);
    }

    let mut pcm_wire = vec![0u8; 512 * 6];
    let (consumed_dsd, pcm_bytes) = framer.frame_stereo(&dsd_l, &dsd_r, &mut pcm_wire);
    assert_eq!(consumed_dsd, 1024);
    assert_eq!(pcm_bytes, 512 * 6);

    // Push DoP frames into audio ring buffer as normalized 24-bit PCM floats
    let mut expected_samples = Vec::new();
    for frame_idx in 0..512 {
        let base = frame_idx * 6;
        // S24_3Le: 3 bytes L, 3 bytes R
        let b0_l = pcm_wire[base] as i32;
        let b1_l = pcm_wire[base + 1] as i32;
        let b2_l = pcm_wire[base + 2] as i32; // marker
        let i24_l = b0_l | (b1_l << 8) | (b2_l << 16);
        let f_l = (i24_l as f32) / 8388608.0;

        let b0_r = pcm_wire[base + 3] as i32;
        let b1_r = pcm_wire[base + 4] as i32;
        let b2_r = pcm_wire[base + 5] as i32; // marker
        let i24_r = b0_r | (b1_r << 8) | (b2_r << 16);
        let f_r = (i24_r as f32) / 8388608.0;

        audio_prod.push(f_l).unwrap();
        audio_prod.push(f_r).unwrap();
        expected_samples.push((b2_l as u8, (b0_l | (b1_l << 8)) as u16));
        expected_samples.push((b2_r as u8, (b0_r | (b1_r << 8)) as u16));
    }

    // Render through OutputRenderer with active +6 dB EQ and Limiter
    let mut render_out = [0.0f32; 1024];
    renderer.render_interleaved(&mut render_out, 2);

    // Verify: 100% of frames MUST have untouched DoP markers and DSD words
    for i in 0..1024 {
        let rend_f = render_out[i];
        let rend_i24 = (rend_f * 8388608.0).round() as i32;
        let marker = ((rend_i24 >> 16) & 0xFF) as u8;
        let dsd_payload = (rend_i24 & 0xFFFF) as u16;

        let (exp_marker, exp_dsd) = expected_samples[i];
        assert_eq!(
            marker, exp_marker,
            "Gate 10: Sample {} marker corrupted! Expected {:#04x}, got {:#04x}",
            i, exp_marker, marker
        );
        assert_eq!(
            dsd_payload, exp_dsd,
            "Gate 10: Sample {} DSD payload corrupted! Expected {:#06x}, got {:#06x}",
            i, exp_dsd, dsd_payload
        );
    }

    DOP_BYPASS_LOCKOUT.store(false, Ordering::Release);
}

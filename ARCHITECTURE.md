# BitDrop Architecture & Engine Specification

BitDrop is a bit-perfect, audiophile-grade music player and cloud streamer built with a high-performance **Rust audio engine** and a reactive **Flutter UI** bridged via **Flutter Rust Bridge (v2)**.

---

## 1. System Topology

```
┌─────────────────────────────────────────────────────────────────┐
│                    Flutter / Dart UI Layer                      │
│   • Riverpod State Management       • Material 3 Audiophile UI  │
│   • AudioService Background Handler • Hardware USB Probe        │
│   • Live / Mock Domain Core         • 10-Band & Parametric EQ   │
└────────────────────────────────┬────────────────────────────────┘
                                 │
                     Flutter Rust Bridge (FRB v2)
                      Zero-Copy FFI Command API
                                 │
┌────────────────────────────────▼────────────────────────────────┐
│                       Rust Engine Core                          │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │           Decoders & Cloud Storage Subsystem            │   │
│   │   • Symphonia Decoders (FLAC, WAV, MP3, AAC)            │   │
│   │   • SparseTrackCache (Zero-seek kernel page cache)      │   │
│   │   • Resilient HTTP Chunk Fetcher (Backoff + 401 retry)  │   │
│   │   • SQLite Database (WAL mode, FTS5 Search)             │   │
│   └────────────────────────────┬────────────────────────────┘   │
│                                │ raw f32 PCM                    │
│   ┌────────────────────────────▼────────────────────────────┐   │
│   │             Real-Time Lock-Free Audio Pipeline          │   │
│   │   • SPSC PCM Ring Buffer (rtrb, 8.7s capacity)          │   │
│   │   • SPSC Boundary Marker Queue (Single-sample ending)   │   │
│   │   • Wait-Free TripleBuffer<DspConfigSnapshot>           │   │
│   │   • 256-Sinc BlackmanHarris2 Resampler (rubato f64)     │   │
│   │   • ITU-R BS.775 Multichannel Downmix (0.3204 headroom) │   │
│   │   • f64 Biquad EQ (Direct Form II Transposed)           │   │
│   │   • Hardware Denormal Flushing (FTZ / DAZ)              │   │
│   │   • Lookahead True-Peak Limiter (-0.1 dBFS ceiling)     │   │
│   └────────────────────────────┬────────────────────────────┘   │
│                                │                                │
│   ┌────────────────────────────▼────────────────────────────┐   │
│   │                   Hardware Output Sinks                 │   │
│   │   • Android: Oboe / AAudio (SHARING_MODE_EXCLUSIVE)     │   │
│   │   • Desktop: CPAL (High-Priority Direct Stream)         │   │
│   └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. Audio Engine Core

### A. Real-Time Safety & Concurrency
Audio output callbacks (`on_audio_ready` in Oboe and CPAL callbacks) run with real-time audio thread priority. Under real-time audio constraints, the callback MUST NEVER:
1. Acquire standard mutex locks (to avoid priority inversion).
2. Allocate or free heap memory (to avoid memory allocator pauses).
3. Perform file or network I/O.

**Implementation**:
- **Wait-Free DSP Updates**: Audio parameters (EQ gains, preamp, balance, filter specs) are published via `TripleBuffer<DspConfigSnapshot>` in [`app/rust/src/dsp.rs`](file:///home/razib/Desktop/BitDrop/app/rust/src/dsp.rs). Readers swap cleanly in $O(1)$ wait-free time without locking.
- **State Flags**: Playback state, gating, flush requests, and smooth fades are managed by atomic flags (`CALLBACK_IS_PLAYING`, `CALLBACK_GATE_OUTPUT`, `CALLBACK_FLUSH_REQUESTED`, `CALLBACK_FADE_TARGET`, `CALLBACK_FADE_STEP`).
- **Consumer Ownership**: Consumers for the audio ring buffer and boundary markers are owned directly by the callback structure (`PlayerCallback`), returning to static storage only upon stream restart via `impl Drop`.

### B. Track Ending Drain & Boundary Synchronization
- Monotonic counters (`DECODER_FRAMES_PUSHED` and `CALLBACK_FRAMES_PLAYED`) maintain continuous sample progression.
- An SPSC ring buffer (`rtrb::RingBuffer<BoundaryMarker>`) queues `BoundaryMarker::track_ended` when decoder EOF is reached.
- The playback callback continues draining cached PCM audio from the ring buffer until `callback_frames_played >= trigger_at_frame`, guaranteeing that track endings are never truncated.

### C. 64-Bit Float (`f64`) DSP Pipeline
All digital signal processing executes in full double precision (`f64`) to eliminate quantization distortion and preserve dynamic range:
- **Direct Form II Transposed Biquads**: State variables $s_1$ and $s_2$ eliminate burst artifacts during coefficient modification.
- **Subsonic Filter**: 18 Hz 2nd-order Butterworth high-pass filter ($Q = 1/\sqrt{2}$) suppresses inaudible DC offset and subsonic turntable/microphone rumble.
- **Hardware FTZ/DAZ**: Flush-To-Zero and Denormals-Are-Zero registers are enabled on x86_64 and AArch64 to protect against CPU performance cliffs caused by subnormal float processing.
- **True-Peak Limiter**: Hard ceiling at $-0.1\text{ dBFS}$ with lookahead compression prevents inter-sample clipping on DAC reconstruction.
- **Resampling**: `rubato::Async::<f64>::new_sinc` with 256 sinc taps, 256 oversampling factor, cubic interpolation, and BlackmanHarris2 windowing.
- **Multichannel Downmixing**: ITU-R BS.775 5.1 downmixing standard with $0.3204$ headroom scaling.

---

## 3. Cloud Storage & Streaming Resilience

The cloud subsystem (`app/rust/src/cloud/`) provides zero-copy streaming of remote audio files:
- **Sparse File Cache (`SparseTrackCache`)**: Allocates sparse files using `set_len()` on ext4/f2fs without upfront disk block allocation.
- **Unified OS Page Cache**: Positional reads and writes occur via `read_at` and `write_at`, bypassing user-space buffer duplication.
- **Resilient Chunk Fetcher**: 2 MB chunk fetches incorporate exponential backoff retry (`200ms`, `500ms`, `1200ms`) and transparent OAuth token refresh on HTTP 401 Unauthorized.
- **Active Cancellation**: Seek, skip, and stop operations increment `active_generation` and call `abort_active_fetches()`, immediately halting background download tasks for stale tracks.
- **Database Engine**: SQLite configured in WAL mode with memory-mapped I/O, synchronous normal, and FTS5 full-text indexing for instant track/album lookups.

---

## 4. Flutter UI & Platform Integration

- **Device Routing & Bit-Perfect Indicator**: Detects external USB DACs (`output_device.dart`). When connected in exclusive mode with matched sample rate and bypassed EQ, surfaces a green `Bit-Perfect` indicator box with inspector details.
- **Background Audio & Lockscreen Controls**: `BitDropAudioHandler` coordinates Android notification media actions, lock screen transport controls, and dynamic track metadata.
- **Release Signing**: Android builds read release keystore parameters from `key.properties` (or CI environment variables), automatically falling back to debug signing for local development.

---

## 5. Verification & Testing Standards

All modifications to the engine and app must satisfy the verification gates:
1. `cargo test`: All unit and integration tests pass (including Golden Test 4 reference FLAC verification, TripleBuffer concurrent torture tests, filter frequency response checks, and downmixing tests).
2. `cargo clippy --all-targets -- -D warnings`: 100% clean with zero warnings.
3. `flutter analyze`: Zero warnings or lint issues.

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
                      Typed Command and Event API
                                 │
┌────────────────────────────────▼────────────────────────────────┐
│                       Rust Engine Core                          │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │           Decoders & Storage Subsystem                  │   │
│   │   • Symphonia Decoders (FLAC, ALAC, WAV, MP3, AAC)      │   │
│   │   • Native DSD64/128 Parser & DoP v1.1 Framing Engine   │   │
│   │   • Ultra-Low CPU Polyphase DSD-to-PCM Decimator        │   │
│   │   • Local Storage Scanner & Metadata Extractor          │   │
│   │   • SparseTrackCache (Zero-seek kernel page cache)      │   │
│   │   • Resilient HTTP Chunk Fetcher (Backoff + 401 retry)  │   │
│   │   • SQLite Database (WAL mode, FTS5 Search)             │   │
│   └────────────────────────────┬────────────────────────────┘   │
│                                │ raw f32 PCM / DoP frames       │
│   ┌────────────────────────────▼────────────────────────────┐   │
│   │             Real-Time Lock-Free Audio Pipeline          │   │
│   │   • SPSC PCM Ring Buffer (rtrb, 8.7s capacity)          │   │
│   │   • SPSC Boundary Marker Queue (Single-sample ending)   │   │
│   │   • Wait-Free TripleBuffer<DspConfigSnapshot>           │   │
│   │   • 256-Sinc BlackmanHarris2 Resampler (rubato f64)     │   │
│   │   • ITU-R BS.775 Multichannel Downmix (0.3204 headroom) │   │
│   │   • f64 Biquad EQ (Direct Form II Transposed)           │   │
│   │   • Hardware Denormal Flushing (FTZ / DAZ)              │   │
│   │   • Adaptive 4x Oversampled True-Peak Limiter (-1.0 dB) │   │
│   └────────────────────────────┬────────────────────────────┘   │
│                                │                                │
│   ┌────────────────────────────▼────────────────────────────┐   │
│   │                   Hardware Output Sinks                 │   │
│   │   • Android Tier D: Direct User-Space USB (Linux usbfs) │   │
│   │   • Android Tier A: Oboe / AAudio (SHARING_MODE_EXCL)   │   │
│   │   • iOS: CoreAudio / AVAudioSession Dynamic Rate Match  │   │
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
- **Wait-Free DSP Updates**: Audio parameters (EQ gains, preamp, balance, filter specs) are published via `TripleBuffer<DspConfigSnapshot>` in [`app/rust/src/dsp.rs`](file:///home/razib/Desktop/BitDrop/app/rust/src/dsp.rs). The mailbox serializes control-side writers. The renderer owns the sole non-cloneable consumer, which exchanges slots in $O(1)$ time without locking. Producer and consumer methods require exclusive access; arbitrary concurrent callers cannot access the same slot.
- **State Flags**: Playback state, gating, flush requests, and smooth fades are managed by atomic flags (`CALLBACK_IS_PLAYING`, `CALLBACK_GATE_OUTPUT`, `CALLBACK_FLUSH_REQUESTED`, `CALLBACK_FADE_TARGET`, `CALLBACK_FADE_STEP`).
- **Consumer Ownership**: Consumers for the audio ring buffer and boundary markers are owned directly by the callback structure (`PlayerCallback`), returning to static storage only upon stream restart via `impl Drop`.

### B. Track Ending Drain & Boundary Synchronization
- Monotonic counters (`DECODER_FRAMES_PUSHED` and `CALLBACK_FRAMES_PLAYED`) maintain continuous sample progression.
- An SPSC ring buffer (`rtrb::RingBuffer<BoundaryMarker>`) queues `BoundaryMarker::track_ended` when decoder EOF is reached.
- The playback callback continues draining cached PCM audio from the ring buffer until `callback_frames_played >= trigger_at_frame`, so buffered audio drains before the end event. Flushing advances the consumed-frame counter by the discarded frame count and acknowledges the flush after both queues are drained. The decoder waits for that acknowledgment before publishing replacement PCM or start markers. EOF releases the prebuffer gate even for tracks shorter than the configured runway.

### C. 64-Bit Float (`f64`) DSP Pipeline
All digital signal processing executes in full double precision (`f64`) to eliminate quantization distortion and preserve dynamic range:
- **Direct Form II Transposed Biquads**: State variables $s_1$ and $s_2$ eliminate burst artifacts during coefficient modification.
- **Subsonic Filter**: 18 Hz 2nd-order Butterworth high-pass filter ($Q = 1/\sqrt{2}$) suppresses inaudible DC offset and subsonic turntable/microphone rumble.
- **Hardware FTZ/DAZ**: Flush-To-Zero and Denormals-Are-Zero registers are enabled on x86_64 and AArch64 to protect against CPU performance cliffs caused by subnormal float processing.
- **Adaptive True-Peak Limiter**: 4x oversampled polyphase FIR inter-sample peak detector adhering strictly to ITU-R BS.1770-4 / EBU R128 standards, combined with an exponential decay lookahead envelope enforcing an immutable $-1.0\text{ dBTP}$ ceiling.
- **Resampling**: `rubato::Async::<f64>::new_sinc` with 256 sinc taps, 256 oversampling factor, cubic interpolation, and BlackmanHarris2 windowing.
- **Multichannel Downmixing**: ITU-R BS.775 5.1 downmixing standard with $0.3204$ headroom scaling.

### D. Native DSD & DoP Subsystem
- **DSF Bitstream Demuxer**: Direct parsing of `'DSD '`, `'fmt '`, and `'data'` blocks with fast 256-entry lookup table LSB-to-MSB bit reversal.
- **DoP v1.1 Framing**: Packs 16-bit DSD channel payloads into 24-bit PCM containers with alternating `0x05`/`0xFA` pilot markers for bit-perfect DSD output over PCM-only transport to DSD DACs.
- **Polyphase Decimator**: Byte-indexed 8-tap lookup table polyphase FIR decimation filter ($2.8224\text{ MHz} \to 176.4\text{ kHz}$) running in $<1.5\%$ CPU for PCM-only audio sinks or active DSP equalizers.

### E. Direct User-Space USB Audio Class 2.0 (Tier D)
- **Direct Linux `usbfs` IOCTLs**: Interacts directly with `/dev/bus/usb` file descriptors passed from Android `UsbManager`.
- **Isochronous Async Feedback Pacing**: Dedicated real-time streaming thread maintaining multi-URB isochronous OUT pipelines with explicit feedback frequency adaptation (UAC1 10.14 and UAC2 16.16 formats) to prevent buffer starvation or overruns on external audiophile DACs.

---

## 3. Cloud Storage & Streaming Resilience

`app/rust/src/cloud/media_source.rs` owns compressed-byte persistence for streaming and offline downloads:

- **Shared writer ownership**: sources opening the same sparse path share one cache object. Metadata probes and preloads do not replace or cancel the active playback source. Sources keep independent read positions and generation snapshots. Large seeks preserve outstanding requests while other readers share the cache. Explicit cancellation is surfaced once per reader, allowing a later read to adopt the current generation.
- **Explicit chunk lifecycle**: each chunk is idle, fetching, ready, or failed. Published byte counts describe partial progress independently. Four attempts use 200 ms, 500 ms, and 1200 ms backoffs. Terminal failures stay failed until a source is reopened or explicitly sought; read-ahead cannot restart them forever.
- **Bounded requests**: a shared semaphore caps active HTTP transfers at four. Throughput-based read-ahead schedules a smaller runway on slower links. Demand reads can queue behind the semaphore.
- **Range validation**: responses must be HTTP 206 with the requested `Content-Range`, file size, and body length. Writes handle interruptions and partial completion, stay inside the requested chunk, and retries resume after bytes already published to readers.
- **Cancellation**: generation changes interrupt request sends, body waits, credential waits, and retry delays. Condition updates and notifications use the waiting mutex; an old request cannot silently strand a reader.
- **Credentials**: `cloud/auth.rs` coalesces refresh requests for a rejected token with a five-second reuse window; an older replacement triggers a fresh platform request. A typed engine event asks the Dart account service to clear its cached credential and obtain another token. The reply completes a pending request with a 15-second timeout; dropped or timed-out requests remove their pending entries. New credentials update the shared fetch context.
- **Persistence**: SQLite owns completed-chunk records and CRC32 checks. Legacy `.idx` files are migrated and retired after records are established. Cache opens, eviction, and deletion follow registry → database → telemetry lock order; telemetry locks are released before pruning starts.
- **Eviction protection**: pin records and all open cache sources protect files from eviction or clearing. Unpinning an open file defers physical removal; it becomes eligible for later eviction after readers finish.
- **Scan safety**: incomplete Drive listings propagate errors, so pruning runs only after a complete walk. Concurrent scans are rejected from the start of initialization.

SQLite uses WAL mode, synchronous normal, and FTS5 for metadata queries.

---

## 4. Flutter UI & Platform Integration

`BitDropAudioHandler` owns queue policy, repeat, shuffle and successor selection. `PlaybackEngine` is the native transport boundary. Rust owns source opening, decoding, PCM flow and output callbacks. Every load is stamped when requested; separate staging generations invalidate obsolete preloads. Queue edits immediately refresh the staged successor, repeat-one clears it, and late credential responses cannot restore a skipped track. Native end events drive automatic advancement; polling does not infer EOF from a pause near the end. Transport stop retains the event subscription for replay and ignores queued EOF events; disposal cancels it. Engine initialization runs once per process.


- **Device Routing & Bit-Perfect Indicator**: Detects external USB DACs (`output_device.dart`). The UI combines advertised platform capabilities with engine telemetry. Hardware route selection, actual mixer acceptance, and end-to-end sample integrity require device verification; capability detection alone does not prove bit-perfect output.
- **Background Audio & Lockscreen Controls**: `BitDropAudioHandler` coordinates Android notification media actions, lock screen transport controls, and dynamic track metadata.
- **Release Signing**: Android builds read release keystore parameters from `key.properties` (or CI environment variables), automatically falling back to debug signing for local development.

---

## 5. Verification & Testing Standards

All modifications to the engine and app must satisfy the verification gates:
1. `cargo test`: All unit and integration tests pass (including Golden Test 4 reference FLAC verification, TripleBuffer concurrent torture tests, filter frequency response checks, and downmixing tests).
2. `cargo clippy --all-targets -- -D warnings`: 100% clean with zero warnings.
3. `flutter analyze`: Zero warnings or lint issues.
4. `cargo build` before `flutter test`: native integration tests load the freshly built shared library. CI builds this library in its Flutter job.
5. `flutter test`: queue coordination, persistence, scan failure, and UI behavior. Transport tests use an injected recording engine; native cache tests exercise the actual bridge.

Local HTTP regression tests cover truncated responses, wrong ranges, full-file responses, cancellation before body arrival, bounded failure retries, and automatic eviction. They require loopback socket access. Physical Android routing and live OAuth consent are separate acceptance checks.

# BitDrop Architecture & Engine Specification

BitDrop is an audiophile-grade, bit-perfect music player, DSP processor, and multi-cloud streamer built with a high-performance **Rust native engine** and a reactive **Flutter UI** bridged via **Flutter Rust Bridge (v2)**.

---

## 1. System Topology

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                Flutter / Dart UI Layer                                 │
│  • Riverpod State Management              • Material 3 Audiophile Ambient Aura UI      │
│  • AudioService Background Media Handler  • Now Playing Live Signal Path Pill          │
│  • Time-Synced Animated Lyrics View       • Audiophile Listening Recap Sheet           │
│  • 1-Tap JSON Backup & Restore            • 10-Band Graphic & Parametric AutoEQ        │
│  • Hardware USB DAC Telemetry Sheet       • Wi-Fi / Cellular Data Saver Toggle         │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │
                                Flutter Rust Bridge (FRB v2)
                               Typed Command and Event Stream
                                            │
┌───────────────────────────────────────────▼────────────────────────────────────────────┐
│                                  Rust Engine Core                                      │
│                                                                                        │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐  │
│  │                        Decoders & Storage Subsystem                              │  │
│  │  • Symphonia Decoders (FLAC, ALAC, WAV, MP3, AAC)                                │  │
│  │  • Native DSF Parser & DoP v1.1 Framing Engine                                   │  │
│  │  • 128-Tap Polyphase DSD-to-PCM Decimator FIR Kernel (16x256 LUT, 32 KB L1 Cache)│  │
│  │  • Multi-Cloud Storage Registry (Google Drive, WebDAV, OneDrive, Dropbox)        │  │
│  │  • Deterministic Namespacing (provider_id:unique_id) & CDN URL Cache             │  │
│  │  • SparseTrackCache (Zero-seek sparse page cache with CRC32 persistence)         │  │
│  │  • Wi-Fi vs. Metered Cellular Streaming Governor (Dynamic Read-Ahead & Concurrency)│ │
│  │  • SQLite Database (WAL mode, FTS5 Search, track_lyrics, playback_history)       │  │
│  │  • Time-Synced Lyrics Parser (.lrc), Embedded Vorbis/ID3 & LRCLIB Fallback       │  │
│  └────────────────────────────────────────┬─────────────────────────────────────────┘  │
│                                           │ raw f32/f64 PCM or DoP frames              │
│  ┌────────────────────────────────────────▼─────────────────────────────────────────┐  │
│  │                   Real-Time Lock-Free Audio Pipeline                             │  │
│  │  • SPSC PCM Ring Buffer (rtrb, 8.7s capacity)                                    │  │
│  │  • SPSC Boundary Marker Queue (Single-sample ending synchronization)             │  │
│  │  • Wait-Free TripleBuffer<DspConfigSnapshot> Mailbox                             │  │
│  │  • 256-Sinc BlackmanHarris2 Resampler (rubato f64)                               │  │
│  │  • ITU-R BS.775 Multichannel Downmix (0.3204 headroom scaling)                   │  │
│  │  • f64 Direct Form II Transposed Biquad EQ (10-Band Graphic + Parametric AutoEQ)│  │
│  │  • 18 Hz 2nd-Order Butterworth Subsonic High-Pass Filter                         │  │
│  │  • Hardware Denormal Flushing (FTZ / DAZ on AArch64 & x86_64)                    │  │
│  │  • Adaptive 4x Oversampled True-Peak Limiter (-1.0 dBTP ceiling, BS.1770-4)      │  │
│  └────────────────────────────────────────┬─────────────────────────────────────────┘  │
│                                           │                                            │
│  ┌────────────────────────────────────────▼─────────────────────────────────────────┐  │
│  │                              Hardware Output Sinks                               │  │
│  │  • Android Tier D: Direct User-Space USB Audio Class 2.0 (Linux usbfs ioctl)     │  │
│  │  • Android Tier A: Oboe / AAudio (SHARING_MODE_EXCLUSIVE, API 34+ Mixer Match)   │  │
│  │  • iOS: CoreAudio / AVAudioSession Dynamic Rate Matching                         │  │
│  │  • Desktop: CPAL (High-Priority Direct Stream)                                   │  │
│  └──────────────────────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Audio Engine Core & DSP Pipeline

### A. Real-Time Safety & Concurrency
Audio output callbacks (`on_audio_ready` in Oboe and audio callback loops in CPAL/USBFS) execute with strict real-time audio thread priority. Under real-time constraints, the engine enforces immutable guarantees:
1. **Zero Lock Acquisition**: No standard mutexes or blocking synchronization primitives are touched in the audio callback.
2. **Zero Dynamic Allocation**: No heap allocations (`malloc`, `free`, `Vec::reserve`, `String`) occur during active stream processing.
3. **Zero File/Network I/O**: Decoding and network fetching are decoupled onto background worker threads; the audio thread solely consumes pre-buffered frames.

**Key Mechanics**:
- **Wait-Free DSP Updates**: Audio parameters (preamp, balance, 10-band graphic gains, and parametric AutoEQ filters) are published from the UI thread to the real-time audio thread using a `TripleBuffer<DspConfigSnapshot>` in [`app/rust/src/dsp.rs`](file:///home/razib/Desktop/BitDrop/app/rust/src/dsp.rs). The consumer exchanges slots in $O(1)$ time with zero locks.
- **Atomic State Transitions**: Playback state, gating, flush requests, and smooth fades are managed by atomic flags (`CALLBACK_IS_PLAYING`, `CALLBACK_GATE_OUTPUT`, `CALLBACK_FLUSH_REQUESTED`, `CALLBACK_FADE_TARGET`, `CALLBACK_FADE_STEP`).
- **SPSC Audio Buffer & Boundary Synchronization**: Ring buffers (`rtrb`) with 8.7-second runway decouple decoders from the audio callback. When the decoder reaches EOF, it pushes a `BoundaryMarker::track_ended` containing the exact sample index to trigger track completion. Flushing drains both the audio ring buffer and boundary markers, advancing counters monotonically without starvation.

### B. 64-Bit Float (`f64`) DSP Pipeline
All DSP operations run in 64-bit double precision (`f64`) to eliminate truncation noise and maintain audiophile signal integrity:
- **Direct Form II Transposed Biquads**: State variables ($s_1$, $s_2$) prevent transient clicks and burst distortion during filter parameter modification.
- **Subsonic Filter**: 18 Hz 2nd-order Butterworth high-pass filter ($Q = 1/\sqrt{2}$) suppresses inaudible DC offset and subsonic turntable/microphone rumble.
- **Hardware Denormal Protection**: Flush-To-Zero (FTZ) and Denormals-Are-Zero (DAZ) CPU control register bits are enabled on x86_64 and AArch64 to eliminate performance degradation from subnormal float calculations.
- **Adaptive True-Peak Limiter**: 4x oversampled polyphase FIR inter-sample peak detector adhering to ITU-R BS.1770-4 / EBU R128 standards, combined with an exponential decay lookahead envelope enforcing an immutable $-1.0\text{ dBTP}$ ceiling.
- **Resampling**: `rubato::Async::<f64>::new_sinc` with 256 sinc taps, 256 oversampling factor, cubic interpolation, and BlackmanHarris2 windowing.
- **Multichannel Downmixing**: ITU-R BS.775 5.1 downmixing standard with $0.3204$ headroom scaling.

### C. Native DSD & DoP Subsystem
- **DSF Demuxer**: Direct demuxing of `'DSD '`, `'fmt '`, and `'data'` chunks with fast 256-entry lookup table LSB-to-MSB bit reversal.
- **DoP v1.1 Framing**: Packs 16-bit DSD channel payloads into 24-bit PCM containers with alternating `0x05`/`0xFA` pilot markers for bit-perfect DSD pass-through to external DSD-compatible DACs.
- **128-Tap Polyphase DSD Decimator FIR Kernel**:
  - When outputting to PCM-only audio sinks or when DSP (EQ/Limiter) is active, DSD64/128 bitstreams are decimated to high-resolution PCM ($2.8224\text{ MHz} \to 176.4\text{ kHz}$ or $5.6448\text{ MHz} \to 352.8\text{ kHz}$).
  - Uses a **128-tap ($16 \times 256$ LUT, 32 KB L1 cache-resident)** symmetric Blackman-Harris polyphase FIR filter.
  - Achieves narrow transition bandwidth ($\Delta f \approx 88.2\text{ kHz}$), stopband rejection $> 100\text{ dB}$ above $90\text{ kHz}$ (completely suppressing ultrasonic $\Delta\Sigma$ noise), and passband ripple $< 0.01\text{ dB}$ at $1\text{ kHz}$.

### D. Direct User-Space USB Audio Class 2.0 (Tier D)
- **Direct Linux `usbfs` IOCTLs**: Interacts directly with `/dev/bus/usb` file descriptors provided by Android `UsbManager`.
- **Isochronous Async Feedback Pacing**: Dedicated real-time streaming thread maintaining multi-URB isochronous OUT pipelines with explicit feedback frequency adaptation (UAC1 10.14 and UAC2 16.16 formats).
- **Kernel URB Teardown Safety**: During disconnect, stream shutdown, or format reconfiguration, BitDrop discards in-flight URBs with `USBDEVFS_DISCARDURB` and drains the kernel completion queue using `USBDEVFS_REAPURBNDELAY` in a non-blocking loop until `EAGAIN` or `ENODEV` is returned, preventing kernel use-after-free crashes or bus lockups.

---

## 3. Multi-Cloud Storage & Streaming Architecture

BitDrop provides seamless, high-res gapless streaming from multiple personal cloud storage providers without requiring third-party intermediary servers.

```
┌────────────────────────────────────────────────────────────────────────┐
│                        ProviderRegistry Subsystem                      │
│                                                                        │
│   ┌────────────────┐ ┌────────────────┐ ┌──────────────┐ ┌───────────┐ │
│   │  Google Drive  │ │     WebDAV     │ │   OneDrive   │ │  Dropbox  │ │
│   │ (OAuth2 + FTS) │ │ (Digest/Basic) │ │ (Azure CDN)  │ │ (API v2)  │ │
│   └───────┬────────┘ └───────┬────────┘ └──────┬───────┘ └─────┬─────┘ │
└───────────┼──────────────────┼─────────────────┼───────────────┼───────┘
            │                  │                 │               │
            ▼                  ▼                 ▼               ▼
┌────────────────────────────────────────────────────────────────────────┐
│             Deterministic Namespacing (provider_id:unique_id)          │
│   • Uniform storage addressing and cache isolation                     │
│   • OneDrive 45-min pre-signed CDN URL cache with 401/403 auto-retry   │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
┌───────────────────────────────────▼────────────────────────────────────┐
│                  SparseTrackCache (Zero-Seek Sparse Store)             │
│   • 2 MB chunk indexing with SQLite CRC32 integrity validation         │
│   • Background multi-worker HTTP range requests with backoff           │
│   • In-memory generation counters invalidating canceled prebuffering   │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
┌───────────────────────────────────▼────────────────────────────────────┐
│               Wi-Fi vs. Metered Cellular Streaming Governor            │
│   • Unmetered Wi-Fi: 30s lookahead, 4 parallel workers, full prebuffer │
│   • Metered Cellular: 15s lookahead, 1 worker, 512 KB header probe     │
└────────────────────────────────────────────────────────────────────────┘
```

### A. Multi-Cloud Providers & Namespacing
- **Unified Registry**: Supports Google Drive, WebDAV (Nextcloud, ownCloud, Synology), Microsoft OneDrive, and Dropbox through `CloudStorageProvider` trait implementations in [`app/rust/src/cloud/`](file:///home/razib/Desktop/BitDrop/app/rust/src/cloud/).
- **Deterministic Namespacing**: Every track is addressed via `provider_id:unique_id` (e.g., `onedrive:01ABC...`, `gdrive:1XYZ...`, `webdav:/Music/...`). This guarantees cache isolation, reliable database indexing, and collision-free multi-account synchronization.
- **OneDrive 45-Minute Pre-Signed URL Cache**:
  - Resolving Microsoft Graph API `/content` 302 redirects incurs network latency and API rate limits.
  - BitDrop caches the pre-signed Azure CDN URL for 45 minutes, enabling direct $1\text{ RTT}$ range requests.
  - If the CDN returns HTTP `401` or `403` prior to the TTL expiry, `OneDriveProvider::fetch_byte_range` evicts the cached entry and transparently re-authenticates/re-fetches via a fresh `/content` 302 redirect.

### B. SparseTrackCache & Fetch Engine
- **Chunk Lifecycle**: Chunks (default 2 MB) transition across `Idle` $\to$ `Fetching` $\to$ `Ready` or `Failed`. Published byte counts allow decoders to begin streaming as soon as initial bytes are received.
- **Resilient Range Requests**: 4 fetch attempts with exponential backoff (200 ms, 500 ms, 1200 ms). Validates HTTP 206 `Content-Range` and byte boundaries.
- **SQLite Persistence**: Completed chunks and CRC32 checksums are tracked in SQLite (WAL mode). Pinned tracks and active cache sources are protected from background cache pruning.

### C. Wi-Fi vs. Metered Cellular Streaming Governor
BitDrop dynamically regulates network I/O based on `NetworkTransportMode`:
- **Unmetered Wi-Fi (Default)**:
  - 30-second bitrate-aware lookahead window.
  - Up to 4 concurrent HTTP range workers.
  - Full next-track pre-buffering for instantaneous gapless playback.
- **Metered Cellular (Data Saver)**:
  - 15-second lookahead window.
  - Strict maximum of 1 active HTTP range worker.
  - Next-track pre-buffering is restricted to a **512 KB header probe** within 15 seconds of track completion, verifying format headers (Symphonia / DSF) without downloading multi-megabyte payloads until the user commits to playback.

---

## 4. Metadata, Tag Delimiters & Library Management

### A. Tag Extraction & Delimiter Isolation
- Extracts tags from ID3v2, Vorbis comments, MP4 atoms, and DSF metadata blocks.
- **Genre Isolation**: `parse_genres()` splits strictly on `;`, `/`, `|`, and `\0`, strictly preserving phrases with commas or ampersands like `"Drum & Bass"`, `"Rock & Roll"`, and `"R&B"`.
- **Artist Isolation**: `parse_artists()` respects canonical band names and trailing articles (e.g., `"The Beatles"`, `"Earth, Wind & Fire"`, `"The, Band"`).

### B. SQLite Architecture
SQLite is configured with Write-Ahead Logging (`WAL`), `synchronous = NORMAL`, and `FTS5` full-text search tables:
- `tracks`: Track metadata, file paths, provider IDs, sample rates, bit depths, channels, replaygain.
- `track_lyrics`: Synced and plain text lyrics with negative cache status.
- `playback_history`: Playback sessions for audiophile analytics.
- `chunk_cache`: Sparse track cache chunk descriptors and CRC32 signatures.

---

## 5. Consumer Delight & Virality Layer

### A. Time-Synced Animated Lyrics Engine
- **Deterministic `.lrc` Parser**: Supports standard `[mm:ss.xx]` and `[mm:ss.xxx]` timestamps, multi-timestamp lines, and metadata tags (`[ar:]`, `[ti:]`, etc.), sorting lines chronologically into `LyricsPayload`.
- **3-Tier Resolution Order**:
  1. Local SQLite `track_lyrics` cache.
  2. Embedded audio tags: Vorbis comments (`LYRICS`, `UNSYNCEDLYRICS`) or ID3 frames (`SYLT`, `USLT`).
  3. `LRCLIB` Fallback: Queries `https://lrclib.net/api/get` with artist, track title, album, and duration using a 5-second timeout and URL encoding.
- **Negative Caching**: If no lyrics exist, a record with `source = 'none'` is stored in SQLite to avoid recurring API lookups on every play.
- **Ambient Aura UI**: A dedicated lyrics toggle on the Now Playing screen crossfades album artwork into a smooth, auto-scrolling lyrics view with active line scaling and tap-to-seek playback.

### B. Live Signal Path Pill
- Prominently positioned directly beneath the track title and artist on the full-screen Now Playing view.
- Frosted-glass audiophile pill displaying real-time audio pipeline telemetry:
  - `FLAC · 24-bit / 96.0 kHz · Bit-Perfect` (Emerald indicator for unmolested bit-perfect output).
  - `DSD64 · DoP v1.1 · Direct USB` (Purple indicator for hardware DSD over PCM framing).
  - `FLAC · 64-Bit DSP · 48.0 kHz` (Cyan indicator for active EQ or true-peak limiting).
- Tapping the pill opens the comprehensive **Signal Path & Hardware Telemetry Inspector**.

### C. Audiophile Listening Recap & 1-Tap JSON Backup/Restore
- **Playback History & Recap**:
  - Automatically records playback sessions in `playback_history` when a track is played for at least 30 seconds or 50% of its duration.
  - `get_listening_recap()` calculates total minutes listened, top 5 tracks, top 5 artists, top genres, and the **Lossless & Hi-Res Ratio** (% of plays with sample rate $\ge 44.1\text{ kHz}$ and bit depth $\ge 16\text{ bit}$).
- **1-Tap JSON Backup & Restore**:
  - `exportBackupJson()` and `importBackupJson(json)` serialize user settings, custom graphic/parametric EQ presets, AutoEQ headphone bindings, non-secret cloud provider configs, and listening recap summaries into a versioned JSON format (`schemaVersion: 1`).

---

## 6. Android R8 / ProGuard Keep Rules & Native Release Optimization

### A. ProGuard / R8 Minification (`app/android/app/proguard-rules.pro`)
When building release packages (`flutter build apk --release` / `flutter build appbundle`), Android R8 minification is enabled (`minifyEnabled true`, `shrinkResources false`). The rules protect critical low-level interfaces:
- **Flutter Rust Bridge & JNI Native Boundaries**: Preserves `com.bitdrop.**`, `MethodChannel`, `EventChannel`, and native JNI entrypoints.
- **Android 14+ AudioMixerAttributes (API 34)**: Preserves `android.media.AudioMixerAttributes`, `AudioFormat`, and `AudioTrack` reflection.
- **User-Space USB Subsystem**: Preserves `android.hardware.usb.UsbManager` and `UsbDeviceConnection`.
- **Media3 & AudioService Receivers**: Preserves background notification handlers and playback service receivers (`androidx.media3.**`, `com.ryanheise.audioservice.**`).

### B. Native Rust Release Profile (`app/rust/Cargo.toml`)
Optimized for maximum SIMD throughput and minimal binary footprint:
```toml
[profile.release]
opt-level = 3
lto = "thin"
codegen-units = 1
strip = "symbols"
```

---

## 7. Verification & Quality Gates

Every modification to BitDrop must satisfy all 5 automated verification gates before code check-in:

1. **Rust Code Formatting**: `cargo fmt --manifest-path app/rust/Cargo.toml -- --check`
2. **Rust Linter**: `cargo clippy --manifest-path app/rust/Cargo.toml --all-targets -- -D warnings` (Zero warnings).
3. **Rust Test Suite**: `cargo test --manifest-path app/rust/Cargo.toml` (152+ tests passing, including Golden Audio Tests, 128-tap DSD decimator tests, multi-cloud range tests, and LRC parser tests).
4. **Flutter Static Analysis**: `flutter analyze lib test` (Zero issues or lint warnings).
5. **Flutter Test Suite**: `flutter test` (230+ unit, widget, and golden tests passing across queue management, live signal path pill, synced lyrics, listening recap, and JSON backup/restore).

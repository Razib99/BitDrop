# Changelog

All notable changes to **BitDrop** are documented in this file.

---

## [1.0.0] - 2026-11-11 — *Audiophile Genesis Release*

BitDrop 1.0.0 is the inaugural public production release of the bit-perfect, audiophile-grade cloud music player and DSP processor. Engineered with a zero-allocation, lock-free Rust native audio engine and an ambient Material 3 Flutter UI.

### 🌟 Core Audio Engine & Hardware Connectivity
- **Direct User-Space USB Audio Class 2.0 (Tier D)**:
  - Direct Linux `usbfs` IOCTL communication bypassing Android audio framework jitter and resampling.
  - Isochronous asynchronous feedback pacing for UAC1 (10.14) and UAC2 (16.16) DAC master clock synchronization.
  - Fail-safe xHCI URB teardown loop (`USBDEVFS_DISCARDURB` $\to$ non-blocking `USBDEVFS_REAPURBNDELAY` drain) preventing kernel use-after-free panics on DAC disconnects.
- **Android Tier A & API 34+ Bit-Perfect Support**:
  - Oboe / AAudio in exclusive sharing mode (`SHARING_MODE_EXCLUSIVE`).
  - Native integration with Android 14+ (API 34) `AudioMixerAttributes` for bit-perfect output format matching.
- **Native DSD & DoP Subsystem**:
  - Direct demuxer for DSF bitstreams (DSD64 and DSD128) with fast 256-entry lookup table LSB-to-MSB bit reversal.
  - Bit-perfect DoP v1.1 framing packing 16-bit DSD payloads into 24-bit PCM containers with alternating `0x05`/`0xFA` pilot markers.
  - **128-Tap Polyphase DSD Decimator FIR Kernel**: $16 \times 256$ LUT (32 KB L1 cache-resident) Blackman-Harris polyphase filter ($2.8224\text{ MHz} \to 176.4\text{ kHz}$ / $5.6448\text{ MHz} \to 352.8\text{ kHz}$) with $> 100\text{ dB}$ stopband rejection above $90\text{ kHz}$ and $< 0.01\text{ dB}$ passband ripple at $1\text{ kHz}$.

### 🎛️ Real-Time 64-Bit Float (`f64`) DSP Pipeline
- **Lock-Free Concurrency**:
  - Zero heap allocations, zero mutex locks, and zero I/O on the real-time audio thread.
  - `TripleBuffer<DspConfigSnapshot>` wait-free parameter updates from UI to audio renderer in $O(1)$ time.
  - SPSC ring buffers (`rtrb`) with 8.7-second runway and single-sample boundary marker queue for sample-accurate gapless transitions.
- **Audiophile DSP Chain**:
  - 10-band graphic equalizer and fully parametric AutoEQ headphone compensation using Direct Form II Transposed biquad filters.
  - 18 Hz 2nd-order Butterworth subsonic high-pass filter ($Q = 1/\sqrt{2}$) suppressing DC offset and turntable rumble.
  - Hardware CPU denormal protection (Flush-To-Zero / Denormals-Are-Zero on AArch64 and x86_64).
  - 4x oversampled polyphase FIR True-Peak Limiter compliant with ITU-R BS.1770-4 / EBU R128 enforcing an immutable $-1.0\text{ dBTP}$ ceiling.
  - High-precision sinc resampling (`rubato` 256-sinc BlackmanHarris2 window) and ITU-R BS.775 5.1 multichannel downmix ($0.3204$ headroom).

### ☁️ Resilient Multi-Cloud Streaming & Caching
- **Multi-Cloud Storage Registry**: Seamless streaming from Google Drive (OAuth2 + FTS), WebDAV (Nextcloud, ownCloud, Synology), Microsoft OneDrive (Graph API + Azure CDN), and Dropbox.
- **Deterministic Namespacing**: Universal `provider_id:unique_id` addressing preventing cache collisions across accounts.
- **OneDrive 45-Minute CDN URL Cache**: Direct $1\text{ RTT}$ range fetches from Azure CDN with automatic 401/403 eviction and single retry on token invalidation.
- **SparseTrackCache**: 2 MB chunk sparse page cache with SQLite WAL-mode CRC32 chunk persistence and protected pinned/open file retention.
- **Wi-Fi vs. Metered Cellular Streaming Governor**:
  - *Unmetered Wi-Fi*: 30-second rolling read-ahead, 4 parallel HTTP range workers, full next-track pre-buffering.
  - *Metered Cellular (Data Saver)*: 15-second read-ahead, 1 worker, next-track pre-buffering clamped to a 512 KB header probe within 15 seconds of track completion.

### ✨ Consumer Delight & Visual Polish
- **Time-Synced Animated Lyrics**:
  - Deterministic `.lrc` timestamp parser supporting multi-timestamp lines and metadata tags.
  - 3-tier resolution: Local SQLite cache $\to$ Vorbis/ID3 embedded tags $\to$ LRCLIB REST API fallback with 5-second timeout and URL encoding.
  - Negative caching (`source = 'none'`) preventing redundant network queries.
  - Smooth ambient crossfading artwork, auto-scrolling synced lines, active line scale emphasis, and tap-to-seek playback.
- **Now Playing Live Signal Path Pill**:
  - Translucent frosted-glass audiophile status pill beneath track title/artist.
  - Dynamic status dots: Emerald (`Bit-Perfect`), Purple (`DSD64 DoP Direct`), Cyan (`64-Bit DSP`).
  - 1-tap launch into the comprehensive Signal Path & Hardware Telemetry Inspector.
- **Audiophile Listening Recap & 1-Tap Backup/Restore**:
  - SQLite `playback_history` tracking qualified listens (30s / 50% threshold).
  - Recap metrics: Total minutes, top tracks, top artists, top genres, and Lossless & Hi-Res Playback Ratio.
  - Versioned 1-tap JSON backup/restore (`schemaVersion: 1`) of EQ presets, AutoEQ bindings, cloud configs, and listening recap.

### 🛡️ Production Release Hardening
- Android R8 minification enabled with robust ProGuard keep rules preserving JNI/FFI boundaries, API 34 `AudioMixerAttributes`, `UsbManager`, and `Media3` receivers.
- Rust release profile with `opt-level = 3`, ThinLTO (`lto = "thin"`), `codegen-units = 1`, and symbol stripping.
- 100% automated test coverage with 382 passing tests across Rust and Flutter.

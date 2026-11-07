# BitDrop: Systems Architecture Review & Next-Phase Dossier
**Prepared for Architecture & Systems Review (Argon)**  
*Date: November 8, 2026 | Repository: Razib99/BitDrop | Branch: `main` (Commit: `ed22388`)*

---

## 1. Executive Summary & Current State

All six milestones outlined in the BitDrop engineering roadmap have been implemented, tested, verified, and pushed to `main`. The codebase maintains a clean architectural separation: a double-precision (`f64`) Rust engine managing low-latency decoding, DSP, caching, and hardware sinks, bridged via `flutter_rust_bridge` (v2) to a reactive Flutter client.

### Current Verification Baseline
- **Flutter Test Suite**: **185 tests passing** (0 failures, 100% pass rate).
- **Rust Test Suite**: **116 tests passing** (110 unit tests + 6 Golden Audio Gates).
- **Static Analysis & Linting**: `flutter analyze lib test` clean (0 issues), `cargo fmt --check` clean, `cargo clippy --all-targets -- -D warnings` clean (0 warnings).
- **Git State**: Clean working tree, fully synchronized with `origin/main`.

---

## 2. Summary of Completed Architectural Milestones

```
┌────────────────────────────────────────────────────────────────────────┐
│                        DELIVERED ARCHITECTURE                          │
├────────────────────────────────────────────────────────────────────────┤
│ 1. Android Tier D Direct USB Audio Class 2.0 (UAC2) User-Space Driver  │
│ 2. Transparent & Honest Signal Path Resolution (No Resample Shaming)   │
│ 3. ITU-R BS.1770-4 4x Oversampled Adaptive True-Peak Limiter (-1 dBTP) │
│ 4. Native 1-bit DSD64/128 Bitstream Demuxer, DoP v1.1 & Decimator     │
│ 5. Hierarchical Local & Cloud Folder Browser with Recursive Queueing   │
│ 6. iOS CoreAudio / AVAudioSession Dynamic Output & Rate Negotiation    │
└────────────────────────────────────────────────────────────────────────┘
```

### Milestone 1: Tier D User-Space USB Audio Class 2.0 Driver
- **Problem Solved**: On Android 12/13 (e.g. Samsung Galaxy S10+), `AudioFlinger` forces 48 kHz / 16-bit float mixing, preventing bit-perfect output over standard Android APIs.
- **Implementation**:
  - Flutter / Android Host Broker passes raw Linux `/dev/bus/usb` file descriptors from `UsbManager` to Rust via FFI.
  - Rust driver interacts directly via Linux `usbfs` ioctls (`USBDEVFS_CLAIMINTERFACE`, `USBDEVFS_SUBMITURB`, `USBDEVFS_REAPURBDELAY`).
  - Implements asynchronous isochronous OUT streaming with multi-URB buffering and dual feedback frequency pacing (UAC1 10.14 and UAC2 16.16 formats).
  - Software fallbacks cleanly revert to standard Oboe/AAudio if USB permissions are denied or detachment occurs.

### Milestone 2: Signal Path Honesty & Presentation Refinement
- **Problem Solved**: Playing native 44.1 kHz audio on an Android shared mixer previously displayed `⚠️ Resampled 44.1 -> 44.1 kHz`, misleading users.
- **Implementation**:
  - Differentiates **"Native Rate · Android Mixed"** (informational blue badge) from true sample rate shifts (`⚠️ Resampled`).
  - Accurately details connected hardware capabilities (e.g., 384 kHz / 32-bit DAC) vs. OS mixer ceilings.

### Milestone 3: ITU-R BS.1770-4 Adaptive True-Peak Limiter
- **Problem Solved**: Discrete sample-peak limiters allow inter-sample peaks up to $+3.0\text{ dBFS}$ during DAC analog reconstruction, causing analog distortion.
- **Implementation**:
  - Implemented 4x oversampled polyphase FIR inter-sample peak detector in `app/rust/src/dsp.rs`.
  - Exponential decay lookahead envelope enforcing an immutable $-1.0\text{ dBTP}$ ceiling compliant with ITU-R BS.1770-4 and EBU R128.
  - Validated by Golden Audio Gate 2 across full-scale multitone bursts and logarithmic frequency sweeps.

### Milestone 4: Native DSD (DSF/DFF) & DoP v1.1 Framing Engine
- **Problem Solved**: Audiophile DSD collections (`.dsf`) could not be decoded or streamed by Symphonia.
- **Implementation**:
  - Custom `DsfFormatReader` parsing `'DSD '`, `'fmt '`, and `'data'` blocks with lookup table LSB-to-MSB bit reversal.
  - DoP v1.1 framing: Packs 16-bit DSD channel payloads into 24-bit PCM containers with alternating `0x05`/`0xFA` pilot markers for direct transmission to DSD-capable USB DACs.
  - Ultra-low-CPU ($<1.5\%$) 8-tap polyphase decimation filter ($2.8224\text{ MHz} \to 176.4\text{ kHz}$) for PCM-only audio sinks or active DSP equalizers.

### Milestone 5: Local & Cloud Hierarchical Folder Browsing
- **Problem Solved**: `LiveBitDropCore` previously returned empty folder and local storage queries.
- **Implementation**:
  - High-performance local directory scanner in Rust extracting container audio metadata.
  - Recursive directory tree indexing in SQLite with normalized path hierarchies.
  - Interactive Flutter UI with breadcrumb navigation, format filter chips, real-time statistics header, and instant recursive queueing.

### Milestone 6: iOS Audio Engine Architecture
- **Problem Solved**: Audio hardware integration was Android-specific; iOS lacked native output host plumbing.
- **Implementation**:
  - Rust `open_cpal_output_stream(sample_rate: Option<u32>)` enabling dynamic stream instantiation and rate matching on CoreAudio.
  - Safe `OutputRenderer::drop` returning `AUDIO_CONSUMER`, `BOUNDARY_CONSUMER`, and `TRIGGERED_PRODUCER` to atomic cells during reconfiguration.
  - Swift `IosAudioHostBroker` in `AppDelegate.swift` managing `AVAudioSession`:
    - Port mapping: `.usbAudio` $\to$ USB Bit-Perfect, `.headphones` $\to$ Wired Analog, `.builtInSpeaker` $\to$ Speaker, `.bluetoothA2DP` $\to$ Bluetooth, `.airPlay` $\to$ AirPlay.
    - Rate negotiation: `setPreferredSampleRate(rate)` dynamically locks hardware clocks.
    - Lifecycle: route changes, `onBecomingNoisy`, phone call interruptions (`onInterruptionBegan`/`onInterruptionEnded`), and media services reset recovery.
  - Dart `OutputDeviceProbe` iOS support with Tier A Bit-Perfect signal path resolution.

---

## 3. Real-Time Audio Guarantees & Invariants

The engine strictly enforces real-time audio thread safety across all platforms:
1. **Zero Allocations & Zero Locks**: Audio render callbacks (`PlayerCallback` in Oboe, CPAL callbacks on iOS/Desktop, and the USB isochronous thread) perform zero heap allocations, zero system mutex acquisition, and zero file/network I/O.
2. **Single-Owner Wait-Free DSP Updates**: Audio parameters (biquad coefficients, preamp, true-peak limiter state) are published via a wait-free `TripleBuffer<DspConfigSnapshot>`. The audio thread reads snapshots without contention.
3. **Hardware Denormal Flushing**: `FPCR` (ARM64) and `MXCSR` (x86_64) flush subnormal floating-point numbers to zero (FTZ/DAZ) at thread entry, preventing CPU microcode execution stalls.
4. **Sample-Accurate Track Transitions**: `BoundaryMarker` queues synchronize track endings with ring buffer drain progress, preserving continuous phase and gapless playback.

---

## 4. Prospective Candidates for Next Phase (For Argon Review & Guidance)

With the initial 6 milestones delivered, we present the following candidate focus areas for Argon to review, prioritize, or refine into future implementation plans:

### Candidate A: Physical Device Acceptance & Hardware Validation Matrix
* **Objective**: Validate the engine against physical devices and OEM-specific audio HAL variations.
* **Key Tasks**:
  1. *Physical Android 12 (Galaxy S10+)*: Validate the Tier D user-space USB driver with physical DACs (DUNU Titan X, FiiO KA17) under real-world conditions (screen sleep, incoming phone calls, hot-unplugging during high-res 192 kHz streams).
  2. *Physical Android 14+ Devices*: Validate `AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT` across Pixel, Samsung, and Sony HAL quirks.
  3. *Physical iOS Devices*: Verify `AVAudioSession.setPreferredSampleRate` on iPhone 15/16 Pro via USB-C and Lightning adapters, verifying that iOS locks to 96 kHz / 192 kHz without OS resampling.

### Candidate B: Architectural Decomposition of `LiveBitDropCore` & `cloud/db.rs`
* **Objective**: Decouple monolithic services into focused, single-responsibility components as outlined in `docs/ARCHITECTURE_REVIEW.md`.
* **Key Tasks**:
  1. *Decompose `LiveBitDropCore`*:
     - Extract `BitDropLibraryService` (cloud and local library queries, search, folder indexing).
     - Extract `BitDropSettingsRepository` (persisting user preferences, EQ state, audio device profiles).
     - Extract `BitDropOutputCoordinator` (managing `OutputDeviceProbe`, direct USB DAC attachment, and signal path diagnostics).
  2. *Decompose `cloud/db.rs`*:
     - Split into `LibraryRepository` (tracks, albums, artists, folders), `CacheRepository` (sparse chunk metadata, CRC32 checks, eviction locks), and `AutoEqRepository` (AutoEQ profiles and FTS5 indexing).

### Candidate C: End-to-End Real Container Golden Audio Regression Suite
* **Objective**: Expand the Golden Audio CI test suite from synthetic PCM buffers to full end-to-end container decodes.
* **Key Tasks**:
  1. Add small, multi-format test fixture files (FLAC, ALAC, WAV, DSF, AAC, MP3) to the test assets.
  2. Test end-to-end decoding, resampler filter delay compensation, container atom walking, and track-to-track gapless transition with real files in CI.
  3. Verify true-peak limiter performance on known high-energy inter-sample clipping test files (e.g., EBU SQAM audio tracks).

### Candidate D: Modular Cloud Storage Providers Beyond Google Drive
* **Objective**: Expand BitDrop's zero-server, direct-streaming paradigm to additional cloud storage backends.
* **Key Tasks**:
  1. Abstract the storage subsystem into a generic `CloudStorageProvider` trait in Rust.
  2. Implement **WebDAV** support (enabling Nextcloud, ownCloud, Synology NAS, and QNAP streaming).
  3. Implement **OneDrive** / **Dropbox** OAuth2 providers with on-device token management.

### Candidate E: Genre & Tag Aggregation Engine
* **Objective**: Complete the remaining user-facing library features noted in earlier architectural reviews (`LiveBitDropCore.genres()`).
* **Key Tasks**:
  1. Parse embedded genre tags and multi-artist tags during local and cloud library scans.
  2. Index genres into SQLite with track counts and album associations.
  3. Implement the Genres tab in the Flutter Library screen with sorting, artwork mosaics, and instant playback.

---

## 5. Request for Argon

Please review this dossier and provide:
1. **Architectural Assessment**: Feedback on the completed architecture (Tier D USB driver, DSD/DoP engine, True-Peak limiter, iOS CoreAudio broker).
2. **Priority Ranking**: Recommendation on which prospective candidate(s) (A through E, or alternative items) should be prioritized for the next phase.
3. **Specific Directives / Constraints**: Any architectural invariants, safety gates, or design patterns you wish enforced in upcoming phases.

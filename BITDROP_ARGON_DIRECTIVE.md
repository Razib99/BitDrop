# BitDrop: Principal Systems Architecture Audit & Phase 2 Engineering Directive
**Reviewer:** Argon (Principal Systems & Audio Architecture Review)  
**Target Repository:** `Razib99/BitDrop` (`main` @ `ed22388`)  
**Verification Baseline:** 185 Flutter tests passing | 116 Rust tests passing (6 Golden Audio Gates) | 0 lint/clippy warnings

---

## 1. Architectural Assessment of Completed Milestones (Milestones 1–6)

Delivering a double-precision ($f_{64}$) Rust audio engine with an Android user-space USB Audio Class 2.0 (`usbfs`) driver, ITU-R BS.1770-4 $4\times$ oversampled True-Peak limiting, Native DSD/DoP v1.1 framing, and iOS CoreAudio dynamic rate negotiation is a major systems engineering achievement.

Before advancing to the next phase, our deep-dive inspection of Milestones 1–6 identified **five subtle real-time and hardware edge cases** that must be codified as strict invariants during the upcoming phase:

### 1.1 Milestone 1 Audit: Tier D User-Space UAC2 Driver (`usbfs`)
* **Strengths:** Bypassing Android's `AudioFlinger` ($48\text{ kHz}$ mixer ceiling on Android 12/13) via `USBDEVFS_SUBMITURB` and `USBDEVFS_REAPURBDELAY` with $Q10.14$ (UAC1) and $Q16.16$ (UAC2) explicit feedback parsing is the gold-standard approach used by reference players like UAPP.
* **Critical Edge Cases to Harden:**
  1. **Implicit Feedback & Adaptive UAC2 Endpoints:** Many compact USB-C DAC dongles (including certain firmware revisions of CS43131 and ES9281PRO dongles, or FiiO KA17 in UAC1 mode) do *not* expose an explicit Isochronous IN feedback endpoint (`bSynchAddress == 0`). When no feedback endpoint exists, the driver must seamlessly fall back to **Nominal Fractional Microframe Pacing**, accumulating fractional samples per $125\ \mu\text{s}$ microframe ($f_s / 8000$) using a $Q16.16$ Bresenham accumulator (e.g., at $44.1\text{ kHz}$, alternating five $5\text{-frame}$ packets and one $6\text{-frame}$ packet every $8$ microframes: $5.5125\text{ frames}/\mu\text{frame}$).
  2. **File Descriptor Ownership Across JNI/FFI:** When Android's `UsbDeviceConnection` passes its raw `fd` (`getFileDescriptor()`) to Rust, **Rust must never call `close(fd)` directly**. Calling `close(fd)` in Rust while `UsbDeviceConnection` still holds the descriptor causes file-descriptor reuse races on Linux/Android, potentially closing a newly opened socket or SQLite file when `UsbDeviceConnection.close()` later executes on the JVM side. Rust must release interfaces via `USBDEVFS_RELEASEINTERFACE` and let the Android Host Broker close the `UsbDeviceConnection`.
  3. **Hot-Unplug Silence Invariant (`ENODEV` / `ESHUTDOWN`):** When a user physically unplugs a FiiO KA17 or DUNU Titan X during a $192\text{ kHz}$ stream, `USBDEVFS_REAPURBDELAY` returns `-ENODEV` ($-19$) or `-ESHUTDOWN` ($-108$). The engine **must not** automatically hot-swap the active stream onto the phone's built-in speaker while playing. It must immediately transition playback state to `Paused` (`onBecomingNoisy` semantics) before reverting the output sink route to Speaker.

### 1.2 Milestone 3 & 4 Audit: DoP v1.1 vs. True-Peak Limiter & DSP Bit-Transparency
* **Strengths:** The $4\times$ oversampled polyphase FIR true-peak detector enforcing a $-1.0\text{ dBTP}$ ceiling compliant with ITU-R BS.1770-4 prevents inter-sample DAC clipping, while DoP v1.1 framing packs $16\text{-bit}$ DSD words into $24\text{-bit}$ PCM frames with alternating `0x05` / `0xFA` markers.
* **Critical Invariant to Enforce (The DoP Bit-Corruption Lockout):**
  * In DoP v1.1 mode, the upper $8\text{ bits}$ ($[23:16]$) of every $24\text{-bit}$ PCM sample carry the `0x05` / `0xFA` marker byte. If the $f_{64}$ DSP pipeline applies *any* gain scaling, biquad filtering, dither, or True-Peak limiting to a DoP stream, the `0x05` / `0xFA` markers are altered, causing the hardware DAC to drop out of DSD mode or emit full-scale white noise.
  * **Hard Invariant:** Whenever `SignalMode::DoP` is active, the DSP pipeline and True-Peak Limiter **must be hardware-locked to complete bypass** at the audio callback level, regardless of user EQ or preamp settings.
* **DSD64/128 Decimator Aliasing Rejection:**
  * A single-stage $8\text{-tap}$ polyphase FIR decimating $2.8224\text{ MHz} \to 176.4\text{ kHz}$ ($16\times$ decimation) is ultra-fast ($<1.5\%$ CPU), but 5th-order $\Sigma\Delta$ DSD modulators push massive quantization noise into the $50\text{ kHz}\text{--}1.4\text{ MHz}$ band (rising at $+24\text{ dB/octave}$). To prevent ultrasonic noise from folding back into the $20\text{ Hz}\text{--}20\text{ kHz}$ audible band, ensure the byte-lookup table (LUT) convolves a symmetric $32\text{-tap}$ or $64\text{-tap}$ Blackman-Harris low-pass kernel ($f_c = 24\text{ kHz}$, stopband attenuation $>105\text{ dB}$) precomputed across $256$-entry byte tables ($4\text{ tables} \times 256\text{ entries}$ for $32\text{ taps}$), which still consumes $<1.8\%$ CPU with zero runtime multiplications.

### 1.3 Milestone 6 Audit: iOS CoreAudio Rate-Lock Synchronization
* **Critical Edge Case:** Calling `AVAudioSession.sharedInstance().setPreferredSampleRate(targetRate)` on iOS is a *request*, not an atomic synchronous guarantee. Before `open_cpal_output_stream(Some(rate))` builds the CoreAudio `RemoteIO` AudioUnit, the Swift broker must read back `AVAudioSession.sharedInstance().sampleRate` and pass the *actual* hardware-latched rate back to Rust so CPAL configures the stream format to match the hardware clock without triggering CoreAudio's internal `AudioConverter` resampler.

---

## 2. Priority Ranking of Next-Phase Candidates (A through E)

To maximize velocity while guaranteeing zero regressions in the real-time audio engine, the candidates **must not** be executed in alphabetical order. Adding new features (Candidates D & E) before decomposing the monolith (Candidate B) will compound technical debt, and decomposing the monolith (Candidate B) without real-container end-to-end tests (Candidate C) risks subtle regressions.

Here is the authoritative **Argon Priority Ranking & Execution Sequence**:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                    PHASE 2 AUTHORITATIVE EXECUTION SEQUENCE                            │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ PRIORITY 1 ──► Candidate C: End-to-End Real Container Golden Audio Regression Suite    │
│                (Establishes the deterministic CI safety net + DoP/DSP lockout gates)   │
│                                          │                                             │
│                                          ▼                                             │
│ PRIORITY 2 ──► Candidate B: Architectural Decomposition of `LiveBitDropCore` & `db.rs` │
│                (Splits monolith into focused services/repos protected by Candidate C)  │
│                                          │                                             │
│                                          ▼                                             │
│ PRIORITY 3 ──► Candidate A: Hardware Edge-Case Hardening & Device Validation Matrix    │
│                (Hardens UAC2 implicit feedback, FD safety, hot-unplug pause & iOS rate)│
│                                          │                                             │
│                                          ▼                                             │
│ PRIORITY 4 ──► Candidate E: Genre & Multi-Artist Tag Aggregation Engine                │
│                (Builds cleanly on the decomposed `LibraryRepository` & SQLite schema)  │
│                                          │                                             │
│                                          ▼                                             │
│ PRIORITY 5 ──► Candidate D: Modular Cloud Storage Providers (`CloudStorageProvider`)   │
│                (Plugs WebDAV, OneDrive & Dropbox into the decoupled storage layer)     │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Detailed Engineering Specifications by Priority

### Priority 1: Candidate C — End-to-End Real Container Golden Audio Suite
**Why First:** Before touching a single line of `LiveBitDropCore` or `cloud/db.rs`, we lock in deterministic end-to-end tests using real binary container fixtures generated programmatically or committed as tiny ($\le 15\text{ KB}$) canonical byte fixtures in `app/rust/tests/fixtures/`.

#### Required Golden Gates to Add (Gates 7–10):
1. **Golden Gate 7 (Multi-Container Decode & Sample Count Exactness):**
   * Generate/embed canonical $100\text{ ms}$ test fixtures across **FLAC** ($24\text{-bit}/96\text{ kHz}$), **WAV** ($32\text{-bit float}/48\text{ kHz}$), **ALAC/M4A** ($16\text{-bit}/44.1\text{ kHz}$), **DSF** ($\text{DSD64 } 2.8224\text{ MHz}$), and **MP3/AAC** (with encoder delay/padding metadata).
   * Assert exact decoded frame counts and bit-exact $f_{64}$ sample reconstruction ($<\!10^{-9}\text{ RMS}$ error for lossless containers).
2. **Golden Gate 8 (Sample-Accurate Gapless Transition Across Containers):**
   * Construct a continuous $1\text{ kHz}$ sine wave split at an arbitrary non-zero-crossing phase angle $\theta_0 = 1.134\text{ rad}$ across Track 1 and Track 2.
   * Feed Track 1 $\to$ `BoundaryMarker` $\to$ Track 2 through the ring buffer and resampler (with filter delay compensation).
   * Assert that the first derivative (phase continuity $\Delta y_n = y_n - y_{n-1}$) across the track boundary has zero discontinuity spike ($|\Delta y_{\text{boundary}} - \Delta y_{\text{expected}}| < 10^{-6}$).
3. **Golden Gate 9 (EBU SQAM Inter-Sample Clipping Torture Test):**
   * Synthesize a pathological $0\text{ dBFS}$ discrete-time signal at $f_s / 4$ with $\pi / 4$ phase offset whose continuous-time reconstructed peak reaches $+3.01\text{ dBTP}$ ($\approx 1.4142\text{ linear}$).
   * Pass through the $4\times$ oversampled ITU-R BS.1770-4 True-Peak Limiter and verify that $4\times$ reconstructed inter-sample peaks never exceed $-1.0\text{ dBTP} + 0.05\text{ dB}$ tolerance ($0.896\text{ linear}$).
4. **Golden Gate 10 (DoP v1.1 Bit-Integrity & DSP Bypass Lockout Gate):**
   * Configure the engine with an active $+6.0\text{ dB}$ preamp boost, active 10-band Parametric EQ, and active True-Peak Limiter, then feed a `.dsf` stream in **DoP v1.1 mode**.
   * Assert that $100\%$ of output frames retain intact alternating `0x05` and `0xFA` marker bytes in bits $[23:16]$ and bit-identical $16\text{-bit}$ DSD payloads in bits $[15:0]$.

---

### Priority 2: Candidate B — Architectural Decomposition of `LiveBitDropCore` & `cloud/db.rs`
**Why Second:** With Golden Gates 1–10 protecting the pipeline, we decompose the Rust database layer and the Flutter core service without risking regressions.

#### 1. Rust Database Decomposition (`app/rust/src/cloud/db/`)
Replace the monolithic `cloud/db.rs` with a modular submodule tree sharing a thread-safe `DbConnectionPool` (or serialized `Mutex< rusqlite::Connection >` with WAL mode enabled: `PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;`):
```text
app/rust/src/cloud/db/
├── mod.rs                 # Connection management, schema migrations & WAL pragmas
├── library_repo.rs        # LibraryRepository: tracks, albums, artists, folders, genres
├── cache_repo.rs          # CacheRepository: sparse chunk bitmaps, CRC32 verification, LRU eviction locks
└── autoeq_repo.rs         # AutoEqRepository: headphone profiles & SQLite FTS5 search
```
* **Architectural Rule:** Keep the public FFI boundary functions in `api.rs` backwards-compatible so existing Flutter callers do not break during the Rust-side refactor.

#### 2. Flutter Core Decomposition (`lib/core/` & `lib/services/`)
Decompose `LiveBitDropCore` using the **Facade + Specialized Domain Services Pattern**:
* `BitDropLibraryService`: Handles local/cloud scanning, album/artist/folder/genre queries, and search.
* `BitDropSettingsRepository`: Persists user preferences, DSP presets, USB DAC mode, and theme state.
* `BitDropOutputCoordinator`: Owns `OutputDeviceProbe`, Android `UsbDacHostBroker` / iOS `IosAudioHostBroker`, UAC2 permission lifecycles, and Signal Path resolution.
* `LiveBitDropCore`: Remains as a thin, clean facade delegating to the three services so all 185 existing Flutter tests continue to pass without brittle rewrites, while new unit tests target the three decomposed services directly.

---

### Priority 3: Candidate A — Hardware Edge-Case Hardening & Device Acceptance Matrix
**Why Third:** Once `BitDropOutputCoordinator` is cleanly isolated, harden the hardware boundary for physical Android 12/14+ and iOS 17/18 devices.

#### Key Engineering Deliverables:
1. **UAC2 Implicit Feedback Fallback (`app/rust/src/usb_dac.rs`):**
   * When parsing USB descriptors, if the selected Audio Streaming interface's Isochronous OUT endpoint has `bmAttributes & 0x0C != 0x04` (i.e., Adaptive or Synchronous rather than Asynchronous) or `bSynchAddress == 0`, automatically engage the **Fractional $Q16.16$ Microframe Accumulator** so dongles without explicit feedback endpoints play bit-perfectly without URB starvation.
2. **Safe FD Lifecycle & Hot-Unplug Pause Guarantee:**
   * Ensure Rust's `UsbDacStream::drop` releases the interface (`USBDEVFS_RELEASEINTERFACE`) and discards pending URBs (`USBDEVFS_DISCARDURB`) *without* calling `libc::close(fd)`, delegating socket/FD closure strictly to Android's `UsbDeviceConnection.close()`.
   * Emit a `HardwareDisconnectEvent` on `-ENODEV` / `-ESHUTDOWN` that immediately pauses playback before switching the active sink back to the internal speaker.
3. **Android 14+ Bit-Perfect Mixer Attributes Probe (`android/` & `OutputDeviceProbe`):**
   * On Android 14+ (API 34+), query `AudioManager.getSupportedMixerAttributes(audioDeviceInfo)` and call `AudioManager.setPreferredMixerAttributes(..., MIXER_BEHAVIOR_BIT_PERFECT)` when Tier D direct `usbfs` is disabled or unavailable, verifying fallback if Samsung/Sony HALs reject the attribute.
4. **Hardware Validation Harness (`lib/screens/diagnostics/` or Debug Overlay):**
   * Add a concise **Hardware Telemetry Inspector** accessible from the Signal Path sheet displaying:
     * Active USB Endpoint Mode (`Explicit Feedback 16.16`, `Explicit Feedback 10.14`, or `Implicit/Nominal Pacing`)
     * Live URB In-Flight Count & Underrun Counter (`urb_underruns: 0`)
     * Latched Hardware Sample Rate vs. Requested Rate ($f_{s,\text{actual}}$ vs. $f_{s,\text{requested}}$)

---

### Priority 4: Candidate E — Genre & Multi-Artist Tag Aggregation Engine
**Why Fourth:** With `LibraryRepository` and `BitDropLibraryService` cleanly separated in Priority 2, implementing Genres and Multi-Artist indexing is clean and modular.

#### Key Engineering Deliverables:
1. **Multi-Value Tag Parser (Rust):**
   * Split embedded `GENRE` and `ARTIST` tags across standard delimiters (`;`, `/`, `,`, null-byte `\0` in ID3v2.4, and multiple Vorbis comment keys) and normalize whitespace/casing (e.g., `"Progressive Rock"`).
2. **Normalized SQLite Schema (`library_repo.rs`):**
   * Create `genres (id, name, normalized_name, track_count, album_count)` and `track_genres (track_id, genre_id)` with indexed foreign keys.
   * Populate genres during both local directory scans and cloud metadata indexing.
3. **Flutter Genres Tab:**
   * Replace the placeholder in `LiveBitDropCore.genres()` with live data from `BitDropLibraryService`.
   * Render a responsive **Genres Grid/List** in the Flutter Library view featuring a $2\times 2$ album-art mosaic card per genre, track/album badge counts, sorting (by track count or alphabetical), and 1-tap "Play All / Shuffle Genre".

---

### Priority 5: Candidate D — Modular Cloud Storage Providers (`CloudStorageProvider` Trait)
**Why Fifth:** With the database and library services decoupled, we expand BitDrop beyond Google Drive into a universal zero-server cloud & NAS player.

#### Key Engineering Deliverables:
1. **`CloudStorageProvider` Trait (`app/rust/src/cloud/provider.rs`):**
   ```rust
   pub trait CloudStorageProvider: Send + Sync {
       fn provider_id(&self) -> &'static str;
       fn list_changes(&self, cursor: Option<&str>) -> Result<CloudDeltaPage, CloudError>;
       fn fetch_byte_range(&self, file_id: &str, start: u64, end_inclusive: u64) -> Result<Vec<u8>, CloudError>;
       fn refresh_credentials_if_needed(&self) -> Result<(), CloudError>;
   }
   ```
2. **Refactor `GoogleDriveProvider`** to implement `CloudStorageProvider`.
3. **Implement `WebDavProvider` (Nextcloud, ownCloud, Synology NAS, QNAP):**
   * Support HTTP `PROPFIND` (Depth: 1 / recursive directory walk) for metadata discovery and standard HTTP `Range: bytes=start-end` requests for sparse chunk streaming into the existing CRC32-verified chunk cache.
4. **Implement `OneDriveProvider` / `DropboxProvider`:**
   * PKCE OAuth2 flow on device with zero intermediate servers, mapping Microsoft Graph `/me/drive/root/delta` and Dropbox `/2/files/list_folder` into `CloudDeltaPage`.

---

## 4. Non-Negotiable Architectural Invariants for Phase 2

1. **Zero Audio-Thread Regression:** No change in Priorities 1–5 may introduce heap allocations (`Vec::new`, `Box::new`, `String`, `Arc::clone`), mutex locks (`Mutex::lock`), or system I/O inside `Oboe::AudioStreamCallback`, `CPAL` render closures, or the `usbfs` isochronous URB reaper loop.
2. **DoP Bit-Transparency Guarantee:** When streaming DoP v1.1 frames, the $f_{64}$ DSP chain and True-Peak limiter must be bypassed so `0x05`/`0xFA` markers are never mutated.
3. **Zero Unplanned Playback on USB Detach:** Unplugging an external USB DAC or wired headphone must immediately pause playback before routing audio back to the built-in speaker.
4. **Zero Analyzer or Clippy Warnings:** Every milestone commit must pass `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test`, `flutter analyze lib test`, and `flutter test`.

---

## 5. Unified Execution Prompt for Antigravity & Codex

Save this file as `BITDROP_ARGON_DIRECTIVE.md` in your BitDrop repository root and paste this single command into your agent environment:

```text
@Antigravity @Codex Read `BITDROP_ARGON_DIRECTIVE.md` in the repository root. This document is the authoritative Phase 2 Systems Architecture Directive from Argon.

EXECUTION PROTOCOL FOR BOTH AGENTS:
1. Antigravity (Primary Lead Builder - 85%): Execute the Phase 2 priorities strictly in the sequence specified in Section 2 of `BITDROP_ARGON_DIRECTIVE.md`:
   - Step 1 (Priority 1 - Candidate C): Implement Golden Audio Gates 7, 8, 9, and 10 (including the DoP v1.1 DSP-bypass lockout invariant and 32-tap LUT DSD decimator filter upgrade) using real binary container fixtures in `app/rust/tests/`.
   - Step 2 (Priority 2 - Candidate B): Decompose `app/rust/src/cloud/db.rs` into `db/mod.rs`, `db/library_repo.rs`, `db/cache_repo.rs`, and `db/autoeq_repo.rs`, and decompose `LiveBitDropCore` into `BitDropLibraryService`, `BitDropSettingsRepository`, and `BitDropOutputCoordinator` while keeping `LiveBitDropCore` as a backwards-compatible facade.
   - Step 3 (Priority 3 - Candidate A): Harden `usb_dac.rs` with Implicit/Nominal Q16.16 microframe pacing fallback when `bSynchAddress == 0`, strict JNI/FFI file-descriptor ownership (never calling `libc::close(fd)` on Android-owned descriptors), automatic pause on `-ENODEV`/`-ESHUTDOWN` hot-unplug, Android 14+ `MIXER_BEHAVIOR_BIT_PERFECT` support, and the Hardware Telemetry Inspector in the Signal Path UI.
   - Step 4 (Priority 4 - Candidate E): Implement the Genre & Multi-Artist Tag Aggregation Engine across Rust (`library_repo.rs`), FFI, and the Flutter Library Genres tab with 2x2 artwork mosaics.
   - Step 5 (Priority 5 - Candidate D): Extract the `CloudStorageProvider` trait in Rust, migrate Google Drive to the trait, and implement `WebDavProvider` (Nextcloud/Synology/QNAP) and `OneDriveProvider`/`DropboxProvider`.

2. Codex (Principal Systems Auditor & QA Gatekeeper - 15%): After each step, verify all 4 Non-Negotiable Architectural Invariants in Section 4 of `BITDROP_ARGON_DIRECTIVE.md`. Run `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test`, `flutter analyze lib test`, and `flutter test`, and ensure 100% pass rate before advancing to the next step.

Begin immediately with Step 1 (Priority 1: Candidate C — Real Container Golden Audio Regression Suite & DoP/DSP Safety Gates).
```
# BitDrop 🎵

[![CI](https://github.com/Razib99/BitDrop/actions/workflows/ci.yml/badge.svg)](https://github.com/Razib99/BitDrop/actions/workflows/ci.yml)
[![GitHub Repo](https://img.shields.io/badge/GitHub-Razib99%2FBitDrop-blue?logo=github)](https://github.com/Razib99/BitDrop)
[![Platform](https://img.shields.io/badge/Platform-Android%2012%2B%20%7C%20iOS%20%7C%20Linux-green)]()
[![Core](https://img.shields.io/badge/Core-Rust%20(Double%20Precision%20f64)-orange?logo=rust)]()
[![UI](https://img.shields.io/badge/UI-Flutter%203.24-blue?logo=flutter)]()
[![Tests](https://img.shields.io/badge/Tests-185%20Flutter%20%7C%20116%20Rust%20%7C%206%20Gates-brightgreen)]()

**Audiophile Cloud Music Player** — Stream bit-perfect, lossless audio (FLAC, ALAC, WAV, DSD, DoP) directly from personal Google Drive storage and local folders to external USB DACs and IEMs, with zero intermediate servers.

---

## 🎯 The Problem & Vision

Audiophile music enthusiasts frequently run out of phone storage when storing uncompressed/lossless music libraries (often 30–120 MB per 24-bit/96kHz–192kHz track). While 2 TB+ cloud drives are widely available, existing playback solutions fall short:

1. **Standard Cloud Players (CloudBeats, Spiral, etc.):** Stream over the wire but route audio through default OS mixers, forcing lossy resampling (e.g. down to 48 kHz / 16-bit) and lacking bit-perfect USB DAC control.
2. **Dedicated Audiophile Players (Poweramp, UAPP, Neutron):** Provide custom DSP and direct hardware DAC control, but are designed for offline local storage and lack native cloud drive integration.
3. **Self-Hosted Servers (Navidrome + Symfonium):** Work well, but require configuring and running a personal home server or VPS 24/7.

**BitDrop fills this void:** A single mobile app connecting directly to your personal Google Drive via on-device OAuth2 to stream bit-perfect or native-rate lossless audio directly to your DAC, backed by a high-performance double-precision Rust DSP engine.

---

## 🌟 Key Features

### ☁️ Direct Google Drive & Local Storage Integration
* **Strict Zero-Server Privacy:** Google Drive OAuth2 authentication occurs entirely on-device; user credentials, tokens, and audio data never touch any intermediate server.
* **Hierarchical Cloud & Local Folder Browser:** Navigate Google Drive and local storage directory trees with real-time audio statistics, breadcrumb navigation, and instant recursive queueing.
* **Format-Aware Progressive Header Reader:** Audio metadata is extracted over HTTP byte-range requests by walking container atoms (FLAC/MP4/ID3/DSF) in milliseconds, fetching only metadata blocks and skipping heavy embedded artwork.
* **Sparse Chunk Cache (2 MiB Blocks):** Compressed audio bytes are cached in sparse disk files with SQLite metadata tracking and CRC32 integrity verification, enabling instant seeks and offline album/track pinning.
* **Bitrate-Aware Read-Ahead Scheduler:** Dynamically manages 30-second rolling read-ahead with concurrent workers (1–4) scaled to network throughput.

### 🎛️ Audiophile 64-Bit Floating Point DSP & DSD Engine
* **Native DSD & DoP v1.1:** Custom Rust DSF parser supporting native 1-bit $\Sigma\Delta$ DSD64 and DSD128, DoP v1.1 framing for DSD-capable USB DACs, and ultra-low-CPU ($<1.5\%$) polyphase decimation for PCM sinks.
* **Double-Precision `f64` Biquads:** 10-band graphic EQ, simple tone controls, and parametric filters running in Transposed Direct Form II with zero coefficient quantization distortion.
* **Adaptive True-Peak Limiter:** 4x oversampled polyphase FIR inter-sample peak detector adhering to ITU-R BS.1770-4 standards, with a -1.0 dBFS ceiling and logarithmic auto-preamp.
* **Hardware Denormal Flushing:** Enforces Flush-To-Zero (FTZ) and Denormals-Are-Zero (DAZ) in hardware to prevent audio-thread CPU slowdowns.
* **Integrated AutoEQ Database:** Built-in parametric presets for **4,900+ calibrated headphone & IEM models** (including Harman and diffuse-field targets), plus custom parametric import.
* **Cryptographic Bit-Exact Neutral Bypass:** When DSP is bypassed, the audio stream bit-for-bit matches the source file (validated via SHA-256 hash in CI).

### 🔍 Honest Signal Path & Bit-Perfect HAL
* **Tier D Direct User-Space USB Driver:** Direct Linux `usbfs` driver in Rust with asynchronous isochronous pacing and explicit feedback loops, delivering bit-perfect output on Android 12 & 13 bypassing AudioFlinger.
* **Android 14+ Preferred Mixer Attributes:** Leverages Android 14's `AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT` to bypass the Android AudioFlinger mixer on supported USB DACs.
* **iOS CoreAudio & `AVAudioSession` Architecture:** Native dynamic rate negotiation (`setPreferredSampleRate`) for bit-perfect output on iOS Lightning/USB-C DACs, plus route change and interruption handling.
* **Four-Tier Output Strategy:**
  * **Tier D (Direct USB):** Direct user-space USB Audio Class 2.0 driver bypassing OS audio server entirely.
  * **Tier A (Bit-Perfect):** Native hardware sample rate & bit depth via Android 14+ or iOS CoreAudio; software volume bypassed.
  * **Tier B (Native Rate):** Native sample rate output without OS resampling; system software volume remains active.
  * **Tier C (Resampled):** Standard OS media audio path (resampled to match device mixer, typically 48 kHz).
* **Live Bitrate (kbps) Transparency:** Displays true calculated uncompressed PCM/DSD data rates across the Now Playing chip, verdict banner, and signal path diagnostics.
* **Auto-Pause on Disconnect & Interruption:** Automatically pauses playback immediately when earphones, headphones, or USB DACs are unplugged or phone calls/alarms begin.
* **Hearing Safety Gate:** On Tier A (where software digital volume is bypassed), BitDrop enforces a safety confirmation before full-scale hardware playback to protect sensitive IEMs.

### 📊 Studio Telemetry & Real-Time FFT
* **60 FPS Live Visualizer:** Real-time 512-point FFT spectrum and left/right peak dB meters fed directly from the engine output stream.
* **Deep Diagnostics:** Live tracking of buffer health, cache hit rates, network throughput, and underrun counters.

---

## 🏛️ System Architecture

BitDrop is decoupled into three distinct layers. The **Rust Core** owns decoding, output, cached audio bytes, and library metadata. The **Dart / Flutter UI** coordinates reactive presentation, queue management, and platform account access. See [ARCHITECTURE.md](ARCHITECTURE.md) for full engineering specifications.

```text
┌─────────────────────────────────────────────────────────────────┐
│                    Flutter / Dart UI Layer                      │
│   • Riverpod State Management       • Material 3 Audiophile UI  │
│   • AudioService Background Handler • Hardware USB DAC Probe    │
│   • AutoEQ Database & Preset Sheet  • Signal Path Diagram       │
└────────────────────────────────┬────────────────────────────────┘
                                 │
                     Flutter Rust Bridge (FRB v2)
                      Typed Command and Event API
                                 │
┌────────────────────────────────▼────────────────────────────────┐
│                       Rust Engine Core                          │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │           Decoders & Cloud Storage Subsystem            │   │
│   │   • Symphonia Decoders (FLAC, ALAC, WAV, MP3, AAC)      │   │
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
│   │   • Lookahead Sample-Peak Limiter (-1.0 dBFS ceiling)   │   │
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

## 🔊 Tiered Audio Output Strategy

Rather than making false claims, BitDrop dynamically detects the operating system, Android API version, and DAC capabilities to truthfully report the active audio path:

| Tier | Availability | Mechanism | Behavior | UI Indicator |
| :--- | :--- | :--- | :--- | :--- |
| **Tier D** | Android 12–14 (USB DAC) | Direct Linux `usbfs` UAC2 driver in Rust | Bypasses Android AudioFlinger entirely; explicit isochronous pacing; bit-perfect passthrough. | `DIRECT USB` |
| **Tier A** | Android 14+ (API 34+) & iOS | `setPreferredMixerAttributes(BIT_PERFECT)` / `AVAudioSession.setPreferredSampleRate` | Bit-perfect passthrough at native sample rate & depth; software volume bypassed; safety gate enabled. | `BIT-PERFECT` |
| **Tier B** | Android 14+ (API 34+) | `setPreferredMixerAttributes(DEFAULT)` | Native sample rate output without OS resampling; system software volume remains active. | `NATIVE RATE` |
| **Tier C** | Android 12–13 or unsupported route | Standard OS media audio path | Output managed by system audio policy (resampled to match device mixer, typically 48 kHz). | `STANDARD (RESAMPLED)` |

---

## 🛡️ Automated Verification & Golden Audio CI Suite

Every pull request and commit is rigorously tested by our automated GitHub Actions CI pipeline:

* **Flutter Automated Tests:** 185 unit, widget, and integration tests covering the live domain core, state persistence, queue management, earphone disconnect, interruption lifecycle, and signal path readouts.
* **Rust Unit & Integration Tests:** 110 tests covering Symphonia decoders, DSD demuxers, DoP framing, polyphase decimation, ring buffers, HTTP range streaming, SQLite cache tracking, and FTS5 search.
* **Golden Audio CI Gates:**
  * **Gate 1:** Parametric & graphic EQ frequency response curve accuracy.
  * **Gate 2:** Zero clipping across all DSP presets with the true-peak limiter active.
  * **Gate 3:** Cryptographic bit-exact bypass verification (SHA-256 hash match against raw input).
  * **Gate 4:** Offline render last frame exactness with zero boundary truncation.
  * **Gate 5:** Gapless album boundary continuity without sample drops or buffer underruns.
  * **Gate 6:** Flushed frames preserve future boundary positions across seeks.

---

## 📱 Hardware Testbed & Environment

* **Primary Test Phone:** Samsung Galaxy S10+ (Android 12 / One UI 4.1, API Level 31)
* **Target Bit-Perfect Platforms:** Android 14+ devices (API Level 34+)
* **Test In-Ear Monitor (IEM):** DUNU Titan X (Type-C with integrated DAC/DSP)
* **External USB DACs:** FiiO KA17, generic USB Audio Class 2 (UAC2) DACs
* **Development Host:** Ubuntu 24.04 LTS (x86_64)

---

## 📂 Repository Structure

```text
BitDrop/
├── README.md                 # Project vision, architecture & guide
├── ARCHITECTURE.md           # Engineering specifications & pipeline docs
├── docs/                     # Project specifications & verification reports
│   ├── FINAL_AUDIT_VERIFICATION_REPORT.md # Full audit & benchmark comparison
│   ├── ARCHITECTURE_REVIEW.md             # Deep architectural review
│   └── UI_UX_DESIGN_BRIEF.md              # UI/UX guidelines and design tokens
├── app/                      # Primary Flutter client application
│   ├── lib/                  # Dart application code (UI, state, routing)
│   │   ├── core_api/         # Abstract core API models & player commands
│   │   ├── core_live/        # Live Rust FFI bridge & AudioHandler integration
│   │   ├── features/         # Feature screens (Now Playing, Library, Sources, EQ)
│   │   ├── theme/            # Theme tokens, typography, and styling
│   │   └── widgets/          # Signal path diagram, visualizer, seek bar
│   ├── rust/                 # Native Rust audio core (Single Source of Truth)
│   │   ├── src/              # Symphonia decoders, Oboe/CPAL audio loops, chunk cache
│   │   └── tests/            # Golden audio test suite & CI verification gates
│   ├── rust_builder/         # flutter_rust_bridge v2 build integration
│   ├── android/              # Android native shell & MediaSession service
│   ├── ios/                  # iOS native shell & AudioSession setup
│   ├── linux/                # Linux desktop shell
│   └── test/                 # Automated unit and widget test suite (111 tests)
├── spike-audio/              # Standalone Android USB audio & DAC capability probe
└── .github/                  # CI/CD workflows and automated build checks
    └── workflows/ci.yml      # GitHub Actions CI workflow
```

---

## 🛠️ Building & Running

### Prerequisites
- **Flutter SDK**: 3.24.5 (`sdk: ^3.5.3`)
- **Rust Toolchain**: 1.80+ with `cargo`
- **Android SDK & NDK**: API 34, NDK r26d+ (for Android builds)
- **Java**: OpenJDK 17

### Development Commands
```bash
# Run Flutter analyzer and unit tests
cd app
flutter analyze lib test
flutter test

# Run Rust engine tests and Golden Audio Gates
cd app/rust
cargo test

# Run the app on a connected device / emulator
cd app
flutter run
```

---

## 📄 References & Documentation

* [BitDrop Architecture Specification](ARCHITECTURE.md)
* [Final Audit Verification Report](docs/FINAL_AUDIT_VERIFICATION_REPORT.md)
* [AOSP Preferred Mixer Attributes](https://source.android.com/docs/core/audio/preferred-mixer-attr)
* [Android Audio Architecture Guide](https://developer.android.com/media/platform/improve-audio-playback)

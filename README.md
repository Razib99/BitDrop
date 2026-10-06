# BitDrop 🎵

[![GitHub Repo](https://img.shields.io/badge/GitHub-Razib99%2FBitDrop-blue?logo=github)](https://github.com/Razib99/BitDrop)
[![Platform](https://img.shields.io/badge/Platform-Android%2012%2B%20%7C%20iOS-green)]()
[![Core](https://img.shields.io/badge/Core-Rust-orange?logo=rust)]()
[![UI](https://img.shields.io/badge/UI-Flutter-blue?logo=flutter)]()

**Audiophile Cloud Music Player** — Stream lossless audio (FLAC, ALAC, WAV) directly from personal cloud storage (Google Drive, S3, WebDAV) with high-fidelity output to external USB DACs and IEMs, with zero intermediate servers.

---

## 🎯 The Problem & Vision

Audiophile music enthusiasts frequently run out of phone storage when storing uncompressed/lossless music libraries (often 30–80 MB per 24-bit/96kHz–192kHz track). While 2 TB+ cloud drives are widely available, existing playback solutions fall short:

1. **Standard Cloud Players (CloudBeats, Spiral, etc.):** Stream over the wire but route audio through default OS mixers, forcing lossy resampling (e.g. down to 48 kHz / 16-bit) and lacking bit-perfect USB DAC control.
2. **Dedicated Audiophile Players (Poweramp, UAPP, Neutron):** Provide custom DSP and direct hardware DAC control, but are designed for offline local storage and lack native cloud drive integration.
3. **Self-Hosted Servers (Navidrome + Symfonium):** Work well, but require configuring and running a personal home server or VPS 24/7.

**BitDrop fills this void:** A single mobile app connecting directly to your Google Drive to stream bit-perfect or native-rate lossless audio directly to your DAC.

---

## 🏛️ System Architecture

BitDrop is decoupled into three distinct layers. The **Rust Core** is the single source of truth for all playback state, caching, decoding, and library metadata.

```text
┌────────────────────────────────────────────────────────┐
│                  FLUTTER UI (Dart)                     │
│  - Library browser, Now Playing, AutoEQ & DSP controls │
│  - Renders reactively from Rust event streams          │
└──────────────────────────▲─────────────────────────────┘
                           │ flutter_rust_bridge v2
┌──────────────────────────▼─────────────────────────────┐
│              RUST CORE (Single Source of Truth)        │
│                                                        │
│  [Async Control & Network IO]                          │
│  ├── State Machine & Library DB (rusqlite + FTS5)      │
│  ├── StorageProvider Trait (Google Drive, S3, WebDAV)  │
│  └── Fetch Scheduler & Sparse Disk Cache (Byte Range)  │
│                                                        │
│  [Dedicated Decoder Thread (Elevated Audio Priority)]  │
│  ├── Symphonia Demux/Decoder (FLAC, ALAC, WAV)         │
│  └── 64-bit Float DSP Engine (Parametric EQ, Dither)   │
│                                                        │
│  [Real-Time Output Pipe]                               │
│  └── Lock-Free SPSC PCM Ring Buffer (rtrb, 0.5–2.0s)   │
└──────────────────────────▲─────────────────────────────┘
                           │ UniFFI / JNI
┌──────────────────────────▼─────────────────────────────┐
│             PLATFORM SHELLS (Kotlin / Swift)           │
│  Android: Media3 MediaLibraryService, AudioFocus,      │
│           AudioMixerAttributes, TokenProvider          │
│  iOS:     AVAudioSession, MPRemoteCommandCenter        │
└────────────────────────────────────────────────────────┘
```

---

## 🔊 Tiered Audio Output Strategy

Rather than making false promises, BitDrop dynamically detects the operating system and DAC capabilities and truthfully reports the active audio path:

| Tier | Availability | Mechanism | Behavior | UI Indicator |
| :--- | :--- | :--- | :--- | :--- |
| **Tier A** | Android 14+ (API 34+) | `setPreferredMixerAttributes(BIT_PERFECT)` | Bit-perfect passthrough at native sample rate & depth; software volume bypassed; safety gate enabled. | `Bit-Perfect` |
| **Tier B** | Android 14+ (API 34+) | `setPreferredMixerAttributes(DEFAULT)` | Native sample rate output without OS resampling; system software volume remains active. | `Native Rate` |
| **Tier C** | Android 12–13 (API 31–33) or unsupported DAC | Standard OS media audio path | Output managed by system audio policy (resampled to match device mixer, typically 48 kHz). | `System Resampled` |
| **Tier D** | Optional / Future | Direct USB Host driver (UAC1/UAC2) | Custom user-space driver bypassing OS audio HAL entirely. | `Direct USB` |

> **Hearing Safety Gate:** On Tier A (where software digital volume is bypassed), BitDrop enforces a safety confirmation before full-scale hardware playback to protect sensitive IEMs.

---

## ⚡ Core Engineering Principles

1. **Strict Zero-Server Policy:** To protect user privacy and avoid costly Google CASA security assessments on `drive.readonly` scopes, zero servers touch user credentials or audio data. All API calls, caching, and token refreshes occur entirely on-device.
2. **Disk-Based Sparse Cache:** Compressed audio bytes (8–16 MiB chunks) are cached in a sparse file on disk, rather than buffering decompressed PCM in RAM. Seeking, gapless pre-roll, and offline pinning operate directly through the disk cache.
3. **Format-Aware Progressive Header Reader:** Audio metadata is extracted over HTTP range requests by walking container atoms (FLAC/MP4), fetching only metadata blocks and skipping heavy embedded artwork.
4. **Real-Time Thread Discipline:** The audio output writer/callback thread is completely decoupled from network operations and decoding, adhering to lock-free, zero-allocation real-time safety.

---

## 📱 Hardware Testbed & Environment

*   **Primary Test Device:** Samsung Galaxy S10+ (Exynos/Snapdragon)
    *   **OS:** Android 12 (One UI 4.1, API Level 31)
    *   **Baseline Output Tier:** **Tier C** (Standard Audio Stack / Mixer Resampled)
*   **Test In-Ear Monitor (IEM):** DUNU Titan X (Type-C)
    *   **Configuration:** Integrated Type-C DSP decoding chip & DAC
*   **Development Host:** Ubuntu 24.04 LTS (x86_64)

---

## 🗺️ Phased Roadmap & Work Split

The project is actively being built in two parallel tracks by a 2-person team:

### Track B: Audio Engine & UI Wiring (Completed ✅)
- [x] **Spike 3:** Rust FFI Bridge (flutter_rust_bridge v2)
- [x] **Spike 4:** NDK Oboe Audio Output bridge (AAudio)
- [x] **Phase 1: Local Engine & Native Shell**
  - [x] Symphonia decoding pipeline & crossbeam-channel buffering
  - [x] Android Foreground Service (`audio_service` / MediaSession)
  - [x] Explicit Tier output routing (Exclusive -> Shared fallback)
  - [x] Queue Management and seamless gap-aware playback
- [x] **Phase 4 (Partial): DSP & Polish**
  - [x] 10-band Graphic EQ (Transposed Direct Form II Biquad filters) processing at real-time in Rust

### Track A: Google Drive Architecture (Next Up 🚀)
- [ ] **Phase 2: Cloud Streaming Core**
  - [ ] GCP OAuth2 authentication flow in Flutter
  - [ ] `StorageProvider` Google Drive integration (REST API)
  - [ ] Sparse disk cache (LRU chunking) for progressive `.flac` buffering
  - [ ] HTTP byte-range requests for metadata scanning without full download
- [ ] **Phase 3: Library & Metadata Engine**
  - [ ] Recursive folder scanning and tag extraction (`symphonia` over cloud cache)
  - [ ] SQLite local metadata persistence


---

## 📂 Repository Structure

```text
BitDrop/
├── README.md                 # Project vision, architecture & roadmap
├── SETUP.md                  # Development environment bootstrap guide
├── bitdrop_audit.md          # Architectural review, risk register & findings
├── docs/                     # Project documentation and specifications
│   └── UI_UX_DESIGN_BRIEF.md # Comprehensive UI/UX prompt for external agents
├── spike-audio/              # Phase 0: Android USB audio probe app
│   ├── app/src/main/java/com/bitdrop/spike/audio/
│   │   ├── AudioDeviceProbe.kt        # USB device & capability enumeration
│   │   ├── MixerAttributesProbe.kt    # API 34+ bit-perfect mixer query
│   │   ├── TierDetector.kt            # Tier A/B/C classification logic
│   │   └── AudioProbeActivity.kt      # Diagnostic UI & AudioTrack probe
│   └── build.gradle.kts
└── spike-drive/              # Phase 0: Cloud fetch spike (Upcoming)
```

---

## 🔄 Daily Workflow & Upload Reminder

> **Reminder:** At the end of every active coding session, commit all incremental changes with a descriptive message and push to GitHub:
> ```bash
> git add .
> git commit -m "feat/fix: describe your daily progress"
> git push origin main
> ```

---

## 📄 References & Documentation

*   [BitDrop Comprehensive Audit](bitdrop_audit.md)
*   [Environment Setup Guide](SETUP.md)
*   [AOSP Preferred Mixer Attributes](https://source.android.com/docs/core/audio/preferred-mixer-attr)
*   [Android Audio Architecture Guide](https://developer.android.com/media/platform/improve-audio-playback)

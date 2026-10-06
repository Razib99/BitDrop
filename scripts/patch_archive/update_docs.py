import re

with open("README.md", "r") as f:
    readme = f.read()

# Update Roadmap in README
old_roadmap = """## 🗺️ Phased Roadmap

- [ ] **Phase 0: Feasibility Spikes** *(In Progress)*
  - [x] Spike 1: Audio Output Capability Probe (`spike-audio/` Kotlin Android App)
  - [ ] Spike 1 Testing: Probe Samsung S10+ & DUNU Titan X over USB
  - [x] Spike 2: Progressive FLAC Header Parser & Range Fetcher (`spike-drive/` Rust CLI)
  - [ ] Spike 3: Rust FFI Bridge Spikes (UniFFI + flutter_rust_bridge v2)
- [ ] **Phase 1: Local Engine & Native Shell**
  - [ ] Symphonia decoding pipeline + `rtrb` lock-free PCM ring buffer
  - [ ] Kotlin Media3 Foreground Service (`MediaLibraryService`)
  - [ ] Tier C / B / A output routing and volume safety gate
- [ ] **Phase 2: Cloud Streaming Core**
  - [ ] `StorageProvider` trait (Google Drive client)
  - [ ] Sparse disk cache & dynamic fetch scheduler
  - [ ] Mid-stream OAuth token auto-refresh
- [ ] **Phase 3: Library & Metadata Engine**
  - [ ] Format-aware progressive tag scanner
  - [ ] SQLite + FTS5 full-text search database
  - [ ] Flutter cross-platform user interface
- [ ] **Phase 4: Audiophile DSP & Polish**
  - [ ] 64-bit float biquad Parametric EQ with AutoEQ profile import
  - [ ] TPDF dithered digital volume control & gapless playback
- [ ] **Phase 5: Multi-Cloud & iOS Expansion**
  - [ ] S3-compatible, WebDAV, and OpenSubsonic backends
  - [ ] iOS shell (`AVAudioSession` + CoreAudio pull sink)"""

new_roadmap = """## 🗺️ Phased Roadmap & Work Split

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
"""

readme = readme.replace(old_roadmap, new_roadmap)

with open("README.md", "w") as f:
    f.write(readme)

# Update task.md
with open("task.md", "w") as f:
    f.write("""# BitDrop Team Task Tracker

## Track B: Local Audio Engine & UI Wiring (Razib)
- [x] **Spike 3: FFI Bridge** - flutter_rust_bridge v2 + Symphonia directory scanning.
- [x] **Spike 4: Oboe Playback** - NDK AAudio streams with Exclusive -> Shared fallback.
- [x] **Task 1: Replace Mock Core** - Wire `LiveBitDropCore` to the Rust engine backend.
- [x] **Task 2: Background Audio Service** - Hook `audio_service` to FFI for lock-screen media controls.
- [x] **Task 3: Queue Management** - Build `BitDropAudioHandler` queue advancing logic (EOF detection).
- [x] **Task 4: DSP Engine (Rust)** - Implement 10-band Graphic EQ Biquad filter chain in the Oboe output callback.

## Track A: Google Drive Cloud Architecture (Friend)
- [ ] **Task 1: OAuth2 Authentication** - Set up Google Cloud Platform client credentials and Flutter `google_sign_in` / `extension_google_sign_in_as_googleapis_auth`.
- [ ] **Task 2: Drive API Integration** - Connect to `googleapis` for `drive.readonly` to list files and folders.
- [ ] **Task 3: Byte-Range Fetcher** - Implement a Rust trait for making HTTP Range requests to the Drive API download URLs.
- [ ] **Task 4: LRU Chunk Cache** - Build a sparse file caching layer in Rust to cache 8-16MB chunks of FLAC files locally.
- [ ] **Task 5: Cloud Metadata Scanner** - Wire Symphonia to probe the Drive files via the byte-range fetcher without downloading the whole file.
- [ ] **Task 6: SQLite Database** - Persist scanned metadata into a local database for fast UI loading.
""")


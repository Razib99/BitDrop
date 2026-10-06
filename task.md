# BitDrop Team Task Tracker

## Track B: Local Audio Engine & UI Wiring (Razib)
- [x] **Spike 3: FFI Bridge** - flutter_rust_bridge v2 + Symphonia directory scanning.
- [x] **Spike 4: Oboe Playback** - NDK AAudio streams with Exclusive -> Shared fallback.
- [x] **Task 1: Replace Mock Core** - Wire `LiveBitDropCore` to the Rust engine backend.
- [x] **Task 2: Background Audio Service** - Hook `audio_service` to FFI for lock-screen media controls.
- [x] **Task 3: Queue Management** - Build `BitDropAudioHandler` queue advancing logic (EOF detection).
- [x] **Task 4: DSP Engine (Rust)** - Implement 10-band Graphic EQ Biquad filter chain in the Oboe output callback.

## Track A: Google Drive Cloud Architecture (Friend)
- [x] **Task 1: OAuth2 Authentication** - Set up Google Cloud Platform client credentials and Flutter `google_sign_in` / `extension_google_sign_in_as_googleapis_auth`.
- [x] **Task 2: Drive API Integration** - Connect to `googleapis` for `drive.readonly` to list files and folders.
- [x] **Task 3: Byte-Range Fetcher** - Implement a Rust trait for making HTTP Range requests to the Drive API download URLs.
- [x] **Task 4: LRU Chunk Cache** - Build a sparse file caching layer in Rust to cache 8-16MB chunks of FLAC files locally.
- [x] **Task 5: Cloud Metadata Scanner** - Wire Symphonia to probe the Drive files via the byte-range fetcher without downloading the whole file.
- [x] **Task 6: SQLite Database** - Persist scanned metadata into a local database for fast UI loading.

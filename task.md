# BitDrop Team Task Tracker

## Track B: Local Audio Engine & UI Wiring (Razib)
- [x] **Spike 3: FFI Bridge** - flutter_rust_bridge v2 + Symphonia directory scanning.
- [x] **Spike 4: Oboe Playback** - NDK AAudio streams with Exclusive -> Shared fallback.
- [x] **Task 1: Replace Mock Core** - Wire `LiveBitDropCore` to the Rust engine backend.
- [x] **Task 2: Background Audio Service** - Hook `audio_service` to FFI for lock-screen media controls.
- [x] **Task 3: Queue Management** - Build `BitDropAudioHandler` queue advancing logic (EOF detection).
- [x] **Task 4: DSP Engine (Rust)** - Implement 10-band Graphic EQ Biquad filter chain in the Oboe output callback.
- [x] **Task 5: iOS Background Audio** - Added `audio` UIBackgroundModes in Info.plist and AVAudioSession `.playback` category in AppDelegate.swift.
- [x] **Task 6: iOS/macOS Audio Engine** - Implemented cross-platform `cpal` CoreAudio output callback backend for non-Android targets.
- [x] **Task 7: Linux Desktop & ALSA Audio Engine** - Implemented native Linux desktop playback via `cpal` + ALSA with `CpalStreamWrapper` for thread safety.
- [x] **Task 8: Low-Latency Seek & Track Transition Flush** - Implemented instant buffer flushing (`flush_requested`) to eliminate playback delay and bleedover on seeking or track changes.
- [x] **Task 9: High-Res Audio Real-Time Resampling** - Built runtime linear decimation to match decoded high-res audio (e.g. 192 kHz) to the system output rate (48 kHz / 44.1 kHz), resolving slow-motion playback.
- [x] **Task 10: Multi-Channel Surround Downmixing** - Added automatic folddown from 5.1/surround channels (and mono duplication) into stereo before output.
- [x] **Task 11: DSP Equalizer & Preamp Wiring** - Connected 10-band Graphic EQ biquad filters, mapped Bass/Treble simple tone controls, and added pre-amp gain control.
- [x] **Task 12: Embedded Artwork Extraction & Zero-Flicker Cache** - Extracted FLAC picture metadata in Rust (`get_cover_art`) and added in-memory synchronous artwork caching in Flutter to prevent UI blinking when minimizing.
- [x] **Task 13: Global Navigation & Docked Mini-Player** - Moved album, artist, and playlist views inside Flutter `ShellRoute` so the Now Playing mini-player stays docked everywhere.
- [x] **Task 14: Dynamic Loudness Normalization (AGC)** - Implemented Automatic Gain Control limiter and maximizer in the CPAL audio loop.

## Track A: Google Drive Cloud Architecture (Friend)
- [x] **Task 1: OAuth2 Authentication** - Set up Google Cloud Platform client credentials and Flutter `google_sign_in` / `extension_google_sign_in_as_googleapis_auth`.
- [x] **Task 2: Drive API Integration** - Connect to `googleapis` for `drive.readonly` to list files and folders.
- [x] **Task 3: Byte-Range Fetcher** - Implement a Rust trait for making HTTP Range requests to the Drive API download URLs.
- [x] **Task 4: LRU Chunk Cache** - Build a sparse file caching layer in Rust to cache 8-16MB chunks of FLAC files locally.
- [x] **Task 5: Cloud Metadata Scanner** - Wire Symphonia to probe the Drive files via the byte-range fetcher without downloading the whole file.
- [x] **Task 6: SQLite Database** - Persist scanned metadata into a local database for fast UI loading.

## Track C: Integration & GCP Setup (Next Steps for Friend/Agent)
- [ ] **Create Google Cloud Project** - Go to GCP Console and create a new project.
- [ ] **Enable Drive API** - Enable `Google Drive API` in the GCP project.
- [ ] **Configure OAuth Consent Screen** - Set up the consent screen for `drive.readonly` scope.
- [ ] **Generate Client IDs** - Generate OAuth Client IDs for Android (SHA-1 fingerprint) and iOS (Bundle ID).
- [ ] **Inject Client IDs** - Put the generated Client IDs into the Flutter app configuration (`Info.plist` and `google-services.json`).
- [ ] **Wire Google API to Rust API** - Pass the access token from `GoogleDriveService` down into the `CloudMediaSource` via FFI when opening a track.

## Track D: Community-Requested Audiophile Features
- [ ] **Task 1: Subsonic/Navidrome Backend** - Implement OpenSubsonic API fetcher and mirror server libraries into the local SQLite DB for unified search.
- [ ] **Task 2: Zero-Server Cloud Metadata Sync** - Implement HTTP Byte-Range requests in Rust to fetch only Vorbis/ID3 headers from Google Drive, enabling fast library indexing without downloading full files.
- [ ] **Task 3: Network Gapless Pre-Buffering** - Upgrade the Rust audio engine to predictively fetch and decrypt the next track in the queue when 15 seconds remain, ensuring 0ms gapless cloud playback.
- [ ] **Task 4: Dynamic Sparse Chunk Caching** - Build an LRU sparse disk buffer to cache high-res FLACs in chunks (e.g. 4MB) over the network, eliminating stuttering on weak cellular data.
- [ ] **Task 5: Advanced Queue State** - Upgrade `audio_handler.dart` to support `Play Next`, `Add to End`, and `Shuffle by Album`.
- [ ] **Task 6: Local Auto-Tagging & Lyrics** - Build metadata scraper (MusicBrainz/Lrclib) that writes missing tags and synced `.lrc` lyrics exclusively to the local SQLite cache.
- [ ] **Task 7: Android Auto Full Hierarchy** - Map SQLite tables to `audio_service` MediaBrowser trees (Artists -> Albums -> Tracks) for car displays.
- [ ] **Task 8: Bit-Perfect USB DAC Passthrough** - Implement `setPreferredMixerAttributes` (API 34+) to bypass Android's resampler for audiophile external DACs.

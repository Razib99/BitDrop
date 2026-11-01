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

## Track C: Integration & GCP Setup
- [x] **Create Google Cloud Project** - `bitdrop-511218`.
- [x] **Enable Drive API** - `drive.readonly` scope, consent screen in Testing mode.
- [x] **Generate Client IDs** - Android (`com.bitdrop.bitdrop` + debug SHA-1) and iOS (bundle id).
- [x] **Inject Client IDs** - `GIDClientID` + reversed-client-ID URL scheme in `Info.plist`.
      Android needs no file: its client is matched server-side by package name and
      SHA-1. No Firebase, so no `google-services.json` or `GoogleService-Info.plist`.
- [x] **Wire Google API to Rust API** - `engine_play_cloud()` builds a `CloudMediaSource`
      on the decode thread; tokens are fetched per track, since they last about an hour.
- [x] **Cloud library index** - two-pass scan: Drive walk records files by name, then
      tags are read over byte ranges and stored in SQLite. Served to the UI through
      `LiveBitDropCore` alongside local and mock content.

> **Remaining before release:** add the *release* keystore SHA-1 to the Android
> OAuth client, or sign-in fails only in release builds. Testing mode expires the
> Google grant roughly weekly; the app surfaces this as "needs reconnection".

## Track D: Community-Requested Audiophile Features
- [ ] **Task 1: Subsonic/Navidrome Backend** - Implement OpenSubsonic API fetcher and mirror server libraries into the local SQLite DB for unified search.
- [x] **Task 2: Zero-Server Cloud Metadata Sync** - Implemented HTTP Byte-Range requests in Rust (`CloudMediaSource` + Symphonia container probe) to extract metadata (duration, sample rate, bit depth, tags) and embedded artwork into SQLite without downloading full files.
- [x] **Task 3: Network Gapless Pre-Buffering & De-click Transitions** - Background loader thread in Rust probes and prepares the next track while the current track plays. Implemented 120ms declick fade-out, swap, and fade-in across track changes; exposed real-time buffer telemetry ("Buffer 2.2 s").
- [x] **Task 4: Dynamic Sparse Chunk Caching** - Built 2MB sparse disk chunk cache in Rust for network audio streaming; published cache spans to UI for seek-bar visualization; added cache storage telemetry and cleanup in Sources settings.
- [x] **Task 5: Advanced Queue State & Shuffle/Repeat** - Implemented full Shuffle (shuffle remaining, preserve & unshuffle to original context), Repeat (off, all with queue wrap-around, one with auto-replay), `Play Next`, `Enqueue`, `ClearQueue`, `RemoveFromQueue`, and `Reorder` in `BitDropAudioHandler` and `LiveBitDropCore`.
- [ ] **Task 6: Local Auto-Tagging & Lyrics** - Build metadata scraper (MusicBrainz/Lrclib) that writes missing tags and synced `.lrc` lyrics exclusively to the local SQLite cache.
- [ ] **Task 7: Android Auto Full Hierarchy** - Map SQLite tables to `audio_service` MediaBrowser trees (Artists -> Albums -> Tracks) for car displays.
- [x] **Task 8: Output Signal Path & Hardware DAC Probe** - Built native Android USB capability query via `AudioManager.getDevices()`; mapped sample rates, channel counts, and encodings; implemented live signal path tier classification (Tier A/B/C) and Bluetooth degradation warnings.

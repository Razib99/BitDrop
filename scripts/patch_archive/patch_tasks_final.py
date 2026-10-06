import re

with open("task.md", "r") as f:
    content = f.read()

# Add iOS tasks to Track B
track_b_replacement = """## Track B: Local Audio Engine & UI Wiring (Razib)
- [x] **Spike 3: FFI Bridge** - flutter_rust_bridge v2 + Symphonia directory scanning.
- [x] **Spike 4: Oboe Playback** - NDK AAudio streams with Exclusive -> Shared fallback.
- [x] **Task 1: Replace Mock Core** - Wire `LiveBitDropCore` to the Rust engine backend.
- [x] **Task 2: Background Audio Service** - Hook `audio_service` to FFI for lock-screen media controls.
- [x] **Task 3: Queue Management** - Build `BitDropAudioHandler` queue advancing logic (EOF detection).
- [x] **Task 4: DSP Engine (Rust)** - Implement 10-band Graphic EQ Biquad filter chain in the Oboe output callback.
- [x] **Task 5: iOS Background Audio** - Added `audio` UIBackgroundModes in Info.plist and AVAudioSession `.playback` category in AppDelegate.swift.
- [x] **Task 6: iOS/macOS Audio Engine** - Implemented cross-platform `cpal` CoreAudio output callback backend for non-Android targets."""

content = content.replace("## Track B: Local Audio Engine & UI Wiring (Razib)", "## Track B: Local Audio Engine & UI Wiring (Razib) (TEMP)")
content = re.sub(r"## Track B: Local Audio Engine & UI Wiring \(Razib\) \(TEMP\).*?## Track A: Google Drive Cloud Architecture", track_b_replacement + "\n\n## Track A: Google Drive Cloud Architecture", content, flags=re.DOTALL)

# Add remaining integration task for the friend
friend_integration = """
## Track C: Integration & GCP Setup (Next Steps for Friend/Agent)
- [ ] **Create Google Cloud Project** - Go to GCP Console and create a new project.
- [ ] **Enable Drive API** - Enable `Google Drive API` in the GCP project.
- [ ] **Configure OAuth Consent Screen** - Set up the consent screen for `drive.readonly` scope.
- [ ] **Generate Client IDs** - Generate OAuth Client IDs for Android (SHA-1 fingerprint) and iOS (Bundle ID).
- [ ] **Inject Client IDs** - Put the generated Client IDs into the Flutter app configuration (`Info.plist` and `google-services.json`).
- [ ] **Wire Google API to Rust API** - Pass the access token from `GoogleDriveService` down into the `CloudMediaSource` via FFI when opening a track.
"""
content += friend_integration

with open("task.md", "w") as f:
    f.write(content)

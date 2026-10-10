# BitDrop — Full Audit (Blueprint v2 + Claude's Review + My Phase 0 Work)

**Scope:** Blueprint v2, Claude's review (F1–F13), the Phase 0 [implementation_plan.md](file:///home/razib/.gemini/antigravity/brain/0e5fcd32-fc20-4937-b415-8b6dd9a28a25/implementation_plan.md), and the `spike-audio/` code I already wrote.
**Constraints since the PDFs:** S10+ on Android 12 (API 31), DUNU Titan X Type-C, **minSdk 31**, **Android and iOS**, public/private release still undecided.

> [!NOTE]
> **Verdict:** Claude's review holds up, and Blueprint v2 is sound for an **Android 14+ phone on a Pixel-like device**. But three things changed after it was written (your hardware, minSdk 31, and iOS), and the blueprint doesn't handle any of them yet. My own Phase 0 work also has real defects, listed first.

---

## Status Update: Resolution of Audit Findings (Current State)

| Audit Item | Status | Notes |
|---|---|---|
| **1.1 spike-audio build defects** | ⚪ Obsolete | We skipped Spike 1 and moved directly to the full Flutter app integration. |
| **1.2 Spike 1 test measurements** | ⚪ Obsolete | Not required anymore. We rely on standard AudioTrack / CPAL backends for now. |
| **2.1 Output path selection** | ✅ Done | Replaced platform-specific audio logic with cross-platform `cpal` + `rtrb` (RingBuffer) in Rust for Linux, iOS, and macOS. Used `Oboe` via CPAL/AAudio for Android. |
| **2.2 iOS Architecture (Pull model)** | ✅ Done | The `cpal` callback operates natively as a "Pull" model, popping frames from our `rtrb` lock-free ring buffer. |
| **2.3 Real-time audio thread rules** | ✅ Done | Decoding happens on a dedicated thread sending raw PCM via `rtrb` channel. Audio output callback is lock-free and zero-allocation. |
| **2.4 Tier D (Custom USB Driver)** | ❌ Not Started | Still a potential future feature for API 31-33 bit-perfect playback. |
| **2.5 Rust binding generation** | ✅ Done | Used `flutter_rust_bridge` v2 for all communication. Shell UI (Kotlin/Swift) is handled via Flutter/Dart plugins (e.g. `audio_service`), avoiding UniFFI duplication. |

---

## Part 1 — Defects in my own work (fix before anything else)

### 1.1 The `spike-audio` project won't build

| # | Defect | Where | Severity |
|---|--------|-------|----------|
| S1 | One of my edits put a literal `-\u003e` into the code instead of `->`, which is a Kotlin syntax error | [AudioProbeActivity.kt:L140](file:///home/razib/Desktop/BitDrop/spike-audio/app/src/main/java/com/bitdrop/spike/audio/AudioProbeActivity.kt#L140) | Build-breaking |
| S2 | The manifest points to `@mipmap/ic_launcher` and `ic_launcher_round`, but no mipmap resources exist, so AAPT linking fails | [AndroidManifest.xml](file:///home/razib/Desktop/BitDrop/spike-audio/app/src/main/AndroidManifest.xml) | Build-breaking |
| S3 | There's no `gradlew` script or `gradle-wrapper.jar`, only the `.properties` file. The `./gradlew assembleDebug` command in [SETUP.md](file:///home/razib/Desktop/BitDrop/SETUP.md) won't run | `spike-audio/` | Build-breaking |
| S4 | AGP 8.5.0 doesn't officially support `compileSdk 35`, so you get warnings at best | [build.gradle.kts](file:///home/razib/Desktop/BitDrop/spike-audio/build.gradle.kts) | Minor (use AGP ≥ 8.7, Gradle ≥ 8.9) |

### 1.2 Spike 1 can't answer the question it was built for (bigger problem)

The plan said Spike 1 would *"report which configs the system actually accepts vs. silently resamples."* **The code can't do that.**

- **`AudioTrack.getFormat()` just returns the format you asked for.** On Android 12, a 24/192 track reports `INITIALIZED` because AudioFlinger quietly resamples it into the mixer. So every "Actual:" line in the report only repeats the request and proves nothing.
- **The test tracks never play.** They're built and released without writing any audio, so the USB output stream may never open in that state, and there's nothing to measure.
- **No public API on API 31 exposes the USB sink's real rate or format.** The only reliable source is `adb shell dumpsys media.audio_flinger`, read **while audio is playing** (output thread sample rate, HAL format, any resampler in use). An app can't run that itself because it needs the `DUMP` permission. It has to come from the host.
- Smaller issues: `TierDetector` gives Tier A if *any* attribute is bit-perfect instead of matching the track's format. The mixer probe only checks the first USB device. `RECORD_AUDIO` isn't needed. `usb.host` should be `required="false"`.

**Fix:** the spike has to (a) play a generated sine wave at each test rate/format for a few seconds, while (b) a host script captures `dumpsys media.audio_flinger` and pulls out the USB output thread's rate and format. That pairing gives real data.

### 1.3 Statements I made that were too strong

| I said | Correction |
|--------|-----------|
| "S10+ will **always** resample to **48 kHz**" | On API 31, audio policy fixes the USB mixer output's rate when the device connects, and every track is resampled to that rate. It's **often** 48 kHz but depends on the device and DAC. We should **measure** it, not assume it. |
| "Tier C only on S10+" | True for the **standard Android audio stack**. But **Tier D** (an app-owned USB driver, the way UAPP does it) **works on Android 12**. That matters a lot (see 2.4). |
| "targetSdk 35 = current Play requirement" | Play raises the target-API floor every August. Check the current requirement when we publish. Not urgent for a personal build. |

---

## Part 2 — New gaps in Blueprint v2 (not covered by Claude's review)

### 2.1 🔴 Phase 0 and Phase 1 exit criteria can't be met with your hardware

| Exit criterion | Achievable on S10+ (API 31) + Titan X? |
|---|---|
| Phase 0: "Phone × DAC tier matrix across 2–3 phones × 2–3 DACs" | ❌ One phone, one DAC, and no mixer-attributes API |
| Phase 0: "Output API chosen (AAudio vs AudioTrack attachment to preferred mixer)" | ❌ Needs API 34+ to test |
| Phase 1: "Tier A confirmed on at least one device via loopback or dumpsys" | ❌ Impossible on API 31 |

As written, the plan blocks at Phase 1. **Options:** (a) get a cheap used Android 14+ phone (Pixels track AOSP behavior most closely) plus a USB DAC dongle with a documented chip; (b) redefine the exits so Tier A/B checks move to a later "hardware validation" milestone; or (c) both. I recommend (b) now and (a) before any "bit-perfect" claim is made.

### 2.2 🔴 iOS is in scope, but the architecture is Android-only

Blueprint v2's shell layer is entirely Kotlin/Media3. iOS needs its own design:

| Concern | Android (blueprint) | iOS (missing) |
|---|---|---|
| Platform shell | Kotlin, Media3 `MediaLibraryService` | Swift: `AVAudioSession`, `MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`, background-audio mode |
| Output model | **Push**: a writer thread calls `AudioTrack.write()` | **Pull**: a CoreAudio render callback asks for frames |
| Staying alive in background | Foreground service, wake and Wi-Fi locks | Only while audio is actually playing. **Prefetch while paused gets suspended**, and gapless pre-roll has to finish while playback is active |
| "Bit-perfect" | Tiers A/B/C | iOS has no bit-perfect API. It can request a preferred hardware rate, but system volume and mixing still apply. Best label: **"Native rate"** until verified with a loopback test |
| Auth | Credential Manager + `AuthorizationClient` | GoogleSignIn-iOS SDK |
| Cache location | app files dir / cache dir | `Application Support` for pinned albums / `Caches` (the OS can purge it) |

**Architectural consequence:** the Rust core needs an `AudioSink` abstraction that supports **both push and pull** output. The PCM ring already allows this, since a pull callback can pop from the ring, but it has to be designed in from Phase 1 or iOS becomes a rewrite.

### 2.3 🟠 The real-time rules contradict the chosen Android output path

Blueprint v2 says the output thread *"never calls into the JVM"* and *"never blocks."* Claude's review then recommends an **`AudioTrack` writer via JNI** as the likely Android path. That path is a JVM call that **blocks by design** (`WRITE_BLOCKING`). Both can't be true.

**Resolution:** state the rules **per sink type**:
- **Pull sinks** (AAudio callback, iOS render callback): strict rules. No alloc, locks, I/O, or JVM.
- **Push sinks** (`AudioTrack` writer): a dedicated JNI-attached thread at `THREAD_PRIORITY_AUDIO`. It blocks **only** inside `write()`, reuses one preallocated direct `ByteBuffer`, never allocates, and uses large buffers (100–300 ms).

My recommendation is to use **`AudioTrack` as the single Android sink for v1**. It works from API 31 to 36 and it's the field-proven pairing with mixer attributes. Treat AAudio as an optional later experiment, not a Phase 0 question.

### 2.4 🟠 Tier D should be reconsidered as a decision, not dismissed

With **minSdk 31**, every user on Android 12–13 (including you) can **never** get bit-perfect through Tiers A/B. The only route on those devices is **Tier D**: an app-owned USB Audio Class driver using the USB Host API, with Rust `rusb`/libusb wrapping the file descriptor from `UsbManager`. Dedicated audiophile players do this.

Claude's reasons to keep it out of v1 still hold. It's a large effort (UAC1/UAC2 descriptors, isochronous transfers, feedback endpoints), it takes the DAC away from system sounds, and volume becomes the app's job. But it should be a **conscious product decision**, and the `AudioSink` trait should be shaped so a USB sink can be added later without rework.

### 2.5 🟠 One Rust library, two binding generators, two hosts: unspecified

Blueprint v2 has Flutter→Rust through **flutter_rust_bridge** and Kotlin→Rust through **UniFFI**, on the same core, where the core may be running **with no Flutter engine alive** (background or Android Auto). Unresolved questions:
- Both bindings must compile into **one** `cdylib`/`staticlib` sharing **one** global core instance in **one process**.
- **Who initializes the core?** It has to be the platform shell (service or app delegate), never Flutter, and Flutter attaches to an already-running core.
- **Alternative:** UniFFI only (it generates Kotlin **and Swift**), with Flutter talking to the shells over platform channels. That's one binding generator but duplicated channel code on each platform.

**Recommendation:** FRB for Dart plus UniFFI for Kotlin/Swift in one crate behind a thin `bitdrop-ffi` facade, with the core lifecycle owned by the shell. A one-day spike should confirm it before Phase 1.

### 2.6 🟡 Android-version details the blueprint doesn't cover

| Topic | Impact |
|---|---|
| **Android 15 `dataSync` foreground-service time limit** | **Offline pinning** (downloading whole albums) can't ride on the playback FGS or run as an unlimited `dataSync` FGS. Use WorkManager or user-initiated data transfer jobs (API 34+), with a fallback for 31–33 |
| Android 12 rules on starting an FGS from the background | Resuming from a media button or Bluetooth has to go through Media3's exemptions. Test it |
| Android 13 `POST_NOTIFICATIONS` | Must be requested for the media notification flow |
| Android 14 `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | Already mentioned in the review. Keep it |
| Legacy `GoogleSignIn` is deprecated | Use **Credential Manager** (identity) + **`AuthorizationClient`** (Drive scope). Android apps get **access tokens, not refresh tokens**. `TokenProvider.refresh()` means a silent `authorize()` call, which fits the review's design well |

### 2.7 🟡 OAuth Testing mode has a 7-day re-consent gotcha

In Testing mode with an External user type, Google **expires grants after about 7 days**, so you'll be asked to re-authorize roughly weekly. That's fine for building, but the app should handle "re-consent required" smoothly (a `ProviderError` variant plus a UI prompt) and not treat it as a fatal auth error.

### 2.8 🟡 Format scope isn't stated

Symphonia covers FLAC, ALAC, WAV/AIFF, MP3, AAC-LC, and Vorbis. It **doesn't** cover **APE (Monkey's Audio), WavPack, DSF/DFF (DSD), or Opus**, all of which turn up in audiophile collections. v1 needs an explicit rule: show those files greyed out as "unsupported format" rather than hiding them.

### 2.9 🟡 Timeline doesn't fit a solo developer building for two platforms

The 14-week plan was sized for **Android only**, assuming full-time work and existing comfort with Rust, NDK, and media plumbing. Adding iOS (a second shell, a pull sink, background rules, signing) adds roughly **4–6 weeks**. Treat the dates as rough sequencing, not a commitment.

---

## Part 3 — A reality check on what the hardware can deliver

The **DUNU Titan X Type-C** is a budget IEM whose USB-C plug contains an **undisclosed DSP/DAC chip that applies its own tuning**. Even with perfect bit-perfect delivery, the samples get processed inside the plug. With **123 dB/Vrms sensitivity at 16 Ω** it's also very sensitive, so the volume-safety gate matters for any tier where software volume is off.

That isn't a reason to drop the bit-perfect goal, since that's the product's identity. But it does point the **order** of work toward your actual original problem: **storage, cloud library, and seamless streaming**. On your current hardware those are things you'll notice every day. Bit-perfect vs. a 48 kHz mixer, through a DSP dongle, mostly won't be.

---

## Part 4 — Claims to verify before relying on them

| Claim (source) | Why verify |
|---|---|
| "symphonia **0.6** with `flac`/`alac`/`isomp4` features" (Claude) | Check the actual released version and feature names on crates.io at project start |
| Drive quota "12,000 queries / 60 s per user and per project" (Claude) | Quota numbers change. Read the current limits page |
| Picking a folder with `drive.file` doesn't grant access to the files inside (Claude, "community reports") | Claude itself suggests a 5-minute test. Still untested |
| Whether AAudio shared-mode streams attach to preferred mixer attributes the way `AudioTrack` does (Claude) | Moot if we commit to the `AudioTrack` sink (2.3) |
| What rate the S10+ actually runs the USB mixer at | Measure it with the fixed Spike 1 |

---

## Part 5 — Proposed changes to the plan

### 5.1 Revised Phase 0 (hardware-honest, maximum reuse)

| Spike | Change | Why |
|---|---|---|
| **1. Audio probe** | Fix S1–S4. **Play** a sine at each rate/format and add a host script `probe.sh` that captures and parses `dumpsys media.audio_flinger` during playback | Gives real measurements instead of echoed requests |
| **2. Drive fetch** | **Write it in Rust as a CLI**, not a throwaway Kotlin app: `reqwest` range fetch + a **progressive FLAC metadata reader**. Run it on desktop, then **cross-compile it for `aarch64-linux-android` and run it through `adb shell`** to measure the phone's real Wi-Fi and mobile throughput. Get the access token from the OAuth Playground | The fetch and FLAC parser become **Phase 2/3 production code**, and the Android shell isn't needed yet |
| **3. FFI topology (new)** | A one-day check: one Rust crate exposing FRB + UniFFI, initialized from Kotlin, then attached to by Flutter | Settles 2.5 before Phase 1 depends on it |
| **4. Drive scope** | 5-minute `drive.file` folder-pick test | Closes Claude's open item |

### 5.2 Revised Phase 1 exit criteria
- Sample-identical decode vs. reference (unchanged)
- Zero xruns in a 2-hour run through the **`AudioTrack` sink on the S10+** (Tier C)
- `AudioSink` trait proven with **both** a push sink (AudioTrack) and a pull sink (a desktop `cpal` sink is enough for now)
- The Tier A/B code path is written and unit-tested against fake mixer attributes. **Real Tier A validation moves to a "Hardware Validation" milestone** once an API 34+ device is available

### 5.3 Add to the roadmap
- An **iOS shell phase** (Swift, AVAudioSession, CoreAudio pull sink, background constraints)
- An **offline pinning** design that complies with Android 15's FGS limits
- An explicit **unsupported-format policy**

---

## Decisions I need from you

> [!IMPORTANT]
> 1. **Test hardware:** Are you willing to get a used Android 14+ phone (and ideally a USB DAC dongle with a known chip) at some point? If not, BitDrop can't honestly verify Tier A, and we should talk about whether Tier D matters more.
> 2. **Priority order:** Keep the blueprint order (audio engine first, then streaming, then library), or put your **daily-use value** first (streaming + library on Tier C, then bit-perfect polish)? I recommend the second, given your hardware.
> 3. **Tier D:** Rule it out permanently, or keep it as a post-v1 option, which shapes the `AudioSink` trait now?
> 4. **Spike 2 in Rust (CLI + `adb shell`)** instead of a Kotlin app. OK?
> 5. **Android sink:** Commit to `AudioTrack` for v1 and drop the AAudio question?

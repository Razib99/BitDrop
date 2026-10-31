# BITDROP: ENTERPRISE MASTER PROJECT PLAN & ENGINE v2 EXECUTION BIBLE

**Repository:** `https://github.com/Razib99/BitDrop`  
**Baseline Commit Audited:** `4ae1930` (31 Oct 2026)  
**Target Architecture:** BitDrop Engine v2 (Flutter + Unified Rust `f64` Audio Core + Oboe/CPAL + SQLite FTS5/LRU)  
**Execution Strategy:** Phased Atomic Refactor with Hard CI Gates (Zero-Breakage Agent Protocol)

---

## HOW TO USE THIS DOCUMENT WITH YOUR CODING AGENT & TEAM

When an AI coding agent is handed a 10-page architectural overhaul all at once, it typically tries to rewrite 15+ Rust and Dart files simultaneously—breaking `flutter_rust_bridge` FFI bindings, introducing borrow-checker deadlocks, and leaving the project uncompilable.

To guarantee **zero broken builds** and **enterprise-grade reliability**, this document is structured into four parts:
1. **Part I: The Complete Verbatim Claude Audit & Engine v2 Specification (Pages 1–10 As-Is)** — Preserves every single measurement, table, diagram, and requirement from the audit so no context is ever lost.
2. **Part II: The 6 Critical Engineering Guardrails** — Low-level DSP and concurrency specifications that prevent subtle implementation bugs during the v2 refactor.
3. **Part III: The 7-Phase Enterprise Execution Plan (Work Packages, File Targets & "Do Not Touch" Rules)** — Breaks the massive project into 7 isolated, testable phases.
4. **Part IV: Sequential Copy-Paste Agent Prompts (Phases 1 to 7)** — Save this entire file in your repository root as `MASTER_PLAN.md`, and feed **one phase prompt at a time** to your coding agent. Never move to Phase $N+1$ until Phase $N$ compiles cleanly and passes all automated tests.

---

# PART I: VERBATIM CLAUDE AUDIT & ENGINE v2 ARCHITECTURE (AS-IS)

> **Note:** The following section is the complete, unedited reproduction of *BitDrop Audit & Engine v2 Architecture* (Nov 1, 2026, `@Rakib Hossain`, Pages 1–10).

## BitDrop Audit & Engine v2 Architecture
**Nov 1, 2026**  
**@Rakib Hossain**

The bass sounds low-quality because of the EQ, not the source files: with a bass boost the engine clips $1\text{--}3\%$ of samples, applies a different curve from the one on screen, and its 32-bit float filters add audible error. That error gets much worse at hi-res rates. A separate bug cuts off the end of every track. Audit of commit `4ae1930` (31 Oct 2026); every EQ number below was measured by running the engine's exact filter code on the FLACs in the repo's `Music` folder.

---

### Why the bass sounds cheap

Three defects stack up every time bass is boosted. Fixing the first two alone removes most of what you hear.

#### 1. Clipping: no headroom and no limiter
EQ boosts add level, but the preamp stays at $0\text{ dB}$ unless you lower it by hand, and nothing in the output path catches peaks. Android hard-clips everything above full scale. The auto-preamp is only a suggestion. The clipping meter lives in the mock core and only fires when the preamp itself is positive. `task.md` and the `README` claim an AGC limiter (Task 14), but `audio_engine.rs` has none: the `auto_gain` field is never read.

| Track ($16\text{-bit}/44.1\text{ kHz}$) | Source peak | Graphic bass preset | Simple mode, Bass $+6\text{ dB}$ |
| :--- | :--- | :--- | :--- |
| **Ae Dil Hai Mushkil** | $0.0\text{ dBFS}$ | peaks $+5.5\text{ dBFS}$, $2.1\%$ of samples clipped | $+5.9\text{ dBFS}$, $3.2\%$ clipped |
| **Bulleya** | $0.0\text{ dBFS}$ | $+4.8\text{ dBFS}$, $2.0\%$ clipped | $+5.6\text{ dBFS}$, $2.5\%$ clipped |
| **O Sajna** | $0.0\text{ dBFS}$ | $+4.0\text{ dBFS}$, $0.5\%$ clipped | $+5.7\text{ dBFS}$, $0.8\%$ clipped |
| **Aadat** | $-1.0\text{ dBFS}$ | $+1.5\text{ dBFS}$, $0.1\%$ clipped | $+2.6\text{ dBFS}$, $0.2\%$ clipped |

Graphic bass preset = $+6, +5, +3, +1\text{ dB}$ at $31, 62, 125, 250\text{ Hz}$, preamp $0$. At $3\%$ that is about $2,600$ clipped samples a second, bunched on kicks and bass notes. That is the flat, fuzzy, "MP3-like" bass.

#### 2. The graphic EQ is not the curve on screen
The screen draws all 10 bands as peaking filters (`biquad.dart`, `fromGraphicGains`). The engine turns band 1 into a low shelf and band 10 into a high shelf at $Q = 1.414$ (`audio_engine.rs`, `update_gains`), and a shelf at that $Q$ overshoots. Same preset, $48\text{ kHz}$:

| Frequency | Screen shows | Engine applies |
| :--- | :--- | :--- |
| $10\text{ Hz}$ | $+0.5\text{ dB}$ | $+6.6\text{ dB}$ |
| $20\text{ Hz}$ | $+2.7\text{ dB}$ | $+7.8\text{ dB}$ |
| $31\text{ Hz}$ | $+7.1\text{ dB}$ | $+4.1\text{ dB}$ |
| $40\text{ Hz}$ | $+6.0\text{ dB}$ | $+1.3\text{ dB}$ |
| $62\text{ Hz}$ | $+6.7\text{ dB}$ | $+4.5\text{ dB}$ |
| $125\text{ Hz}$ | $+4.3\text{ dB}$ | $+3.8\text{ dB}$ |

Up to $+7.8\text{ dB}$ goes below $20\text{ Hz}$, where you cannot hear it but it eats headroom and pushes IEM drivers into distortion. The $31\text{--}62\text{ Hz}$ punch region gets $2\text{--}5\text{ dB}$ less than shown. The suggested preamp is worked out from the screen curve ($-7.1\text{ dB}$) while the real peak gain is $+7.8\text{ dB}$, so even "apply suggestion" still clips.

#### 3. 32-bit float filters are too coarse for bass
The biquads run Transposed Direct Form II with `f32` coefficients and `f32` state. The `README` and `biquad.dart` say "64-bit float DSP"; the code is 32-bit. Near $31\text{ Hz}$ the filter poles sit almost on the unit circle, so `f32` rounding shifts the curve and its arithmetic noise is amplified. Measured against an `f64` reference (*Bulleya*, preamp $-7\text{ dB}$ so nothing clips):

| Output rate | Error vs 64-bit, RMS | Error peak | Signal-to-error |
| :--- | :--- | :--- | :--- |
| $44.1\text{ kHz}$ | $-84\text{ dBFS}$ | $-66\text{ dBFS}$ | $68\text{ dB}$ |
| $96\text{ kHz}$ | $-66\text{ dBFS}$ | $-46\text{ dBFS}$ | $51\text{ dB}$ |
| $192\text{ kHz}$ | $-53\text{ dBFS}$ | $-29\text{ dBFS}$ | $38\text{ dB}$ |

A 16-bit source is about $96\text{ dB}$ clean, so EQ'd output drops to roughly $11\text{--}13\text{-bit}$ quality. Hi-res is hit hardest because the engine reopens the stream at the track's own rate. Coefficient rounding alone moves the $31\text{ Hz}$ shelf by up to $0.96\text{ dB}$ at $192\text{ kHz}$. Coefficient updates also land instantly with no smoothing, so dragging a slider can zipper.

*Method:* a C port of `StereoBiquad` and `GraphicEq`, run in `f32` (as shipped) beside `f64`, over the repo's FLACs decoded with `ffmpeg`; the $96$ and $192\text{ kHz}$ copies were made with `soxr`.

---

### Audio engine flaws

The worst engine bug outside the EQ is that every track's last seconds are muted. Real gapless playback and bit-perfect output, both listed as done, are not implemented.

| Severity | Flaw | Where | Effect | Fix |
| :--- | :--- | :--- | :--- | :--- |
| **Critical** | Track endings cut off. At end of file the decoder sets `is_playing = false` while the ring still holds unplayed audio, and the callback mutes at once | `audio_engine.rs`, end-of-file branch of the decode loop | Up to $\sim 8.7\text{ s}$ lost at $44.1\text{ kHz}$ ($2\text{ s}$ at $192\text{ kHz}$). Position freezes short of the end, so the "within $1\text{ s}$ of end" check in `audio_handler.dart` can miss and the queue stalls. Found by reading the code: confirm by listening to the last $10\text{ s}$ of a local track | Put an end-of-stream marker in the ring; the callback raises `TrackEnded` when it plays the marker |
| **High** | Not gapless. Each change fades out $260\text{ ms}$, flushes, fades in; the next track only starts after Dart's poll notices the end. Encoder delay and padding are never trimmed | Loader hand-off; `open_media_source` | Gaps and fades inside live and continuous albums | Decode the next track into the same ring; set `enable_gapless` in Symphonia |
| **High** | Real-time rule breaks. Every output callback locks the global `PLAYER_STATE` mutex and clones `eq_specs` (a heap allocation); the decode thread takes the same lock on every packet | `on_audio_ready` and the `cpal` closure | Priority inversion leads to dropouts and crackles under load | Lock-free parameter hand-off; compute coefficients off the audio thread |
| **High** | Bit-perfect tiers missing. Nothing calls `setPreferredMixerAttributes`; Rust always opens an AAudio `LowLatency` + `Exclusive` `f32` stream | `MainActivity.kt`, `open_output_stream` | "Tier A/B" is a label only; no path is bit-perfect | Kotlin mixer attributes on API 34+, `PerformanceMode::None`, native integer format, full DSP bypass |
| **Medium** | Mono and balance only apply while the EQ is on (they sit inside `if eq_enabled`) | Both callbacks | Accessibility settings silently ignored | Separate output stage |
| **Medium** | Resampler: async sinc with 64 taps, errors silently drop audio (`if let Ok`), new `Vec`s every packet | Decode loop | Mild aliasing and dropouts on $44.1$ to $48\text{ kHz}$ conversion | Fixed-ratio FFT resampler, or sinc 256 / cutoff $0.95$ / oversampling 256 in `f64`; report errors |
| **Medium** | Android and desktop each have their own copy of the callback ($\sim 110$ duplicated lines) | `init_engine`, `PlayerCallback` | Fixes land in one copy only (desktop never updates the EQ rate) | One shared `OutputRenderer` |
| **Low** | 5.1 downmix drops the surround and LFE channels | Decode loop | Missing ambience and sub-bass in multichannel files | ITU-R BS.775 matrix including LFE |
| **Low** | Coarse seek reports the target time though audio lands earlier; seeks and track swaps sleep on the decode thread | Seek handler | Lyrics and position drift after seeking | Accurate seek, then discard to the target frame |

---

### Streaming and cache flaws

The sparse cache works, but one network blip ends a track for good, read-ahead is only about a second on hi-res, and the cache has no size limit.

| Severity | Flaw | Where | Effect | Fix |
| :--- | :--- | :--- | :--- | :--- |
| **High** | One failed chunk kills the track. `cache.failed` is a single sticky flag per file, with no retry | `media_source.rs`, `trigger_chunk_fetch` | Any dropped connection makes every later read fail; decode gives up after 5 tries | Per-chunk retry with backoff; clear the failure once a retry succeeds |
| **High** | Read-ahead too short. The next $2\text{ MB}$ chunk is only requested after half the current one is read | `CloudMediaSource::read` | About $1\text{ MB}$ of lead, roughly $1\text{ s}$ of $24/192$ FLAC; mobile latency spikes cause stutter | Bitrate-aware window (keep $\sim 30\text{ s}$ ahead), 2–3 parallel ranges, adaptive to throughput |
| **High** | Token expiry mid-track. The OAuth token is passed once when the track opens; Rust has no 401 handling | `DecoderCmd::PlayCloud` | After about an hour (long pause or long session) fetches fail, then the sticky flag kills playback | Token-provider callback into Dart; refresh on 401 and retry the range |
| **High** | No cache limit or eviction. The storage screen's limit and "evicted oldest-first" exist only in the mock; live storage reports a limit of 0 | `live_core.dart` `refreshStorage`, `media_source.rs` | Cache grows until the phone is full | LRU eviction under a user-set cap; pinned albums exempt |
| **Medium** | Skipping does not cancel downloads. `active_generation` is checked but never incremented | `media_source.rs` | Skipped tracks keep downloading over mobile data | Bump the generation on skip; keep only the next-track prefetch |
| **Medium** | Cache integrity is unchecked. Finished chunks are recorded in a plain `.idx` text file with no size or checksum | `SparseTrackCache::new` | If Android clears the audio file but not its index, reads return zeros: silence or noise | Chunk state in the existing SQLite DB, with file size and `mtime` checks and a CRC per chunk |
| **Low** | Seek-bar cache telemetry (`CACHED`) is one global slot | `media_source.rs` | Current track and next-track prefetch overwrite each other | Key it by file id |

---

### App, security and repo flaws

The "live" app still runs EQ, settings and AutoEQ on the mock core. The repo carries $476\text{ MB}$ of commercial music, which is why it is too big to clone onto your device.

| Severity | Flaw | Where | Effect | Fix |
| :--- | :--- | :--- | :--- | :--- |
| **Critical** | Release builds may have no network. `INTERNET` is declared only in the debug and profile manifests | `android/app/src/main/AndroidManifest.xml` | Unless a plugin merges it in, a release APK cannot reach Drive. Check the merged manifest | Declare it in the main manifest |
| **High** | The live core still runs on the mock. `LiveBitDropCore` builds a `MockBitDropCore` and forwards EQ, settings, diagnostics, visualizer, device profiles, banners and AutoEQ search to it | `live_core.dart` | EQ and settings live in mock memory (I found no code that saves them); visualizer and diagnostics are simulated | Move EQ and settings into the Rust core, saved in SQLite; delete the mock from release builds |
| **High** | AutoEQ profiles are hard-coded placeholders, including a "DUNU Titan X, oratory1990, Harman IE 2019" entry, your test IEM | `core_mock/catalog.dart` | Applying it EQs to numbers that come from no measurement file | Bundle the AutoEq ParametricEQ database (MIT licence) and reuse the existing import parser |
| **High** | Music and build output committed. `Music/` (10 commercial tracks, $476\text{ MB}$) and the `spike-audio` APK are tracked, though `.gitignore` now lists them | Repo root | Checkout $972\text{ MB}$, `.git` $435\text{ MB}$; copyright exposure on a public repo | `git rm --cached`, then `git filter-repo` to purge history, then force-push |
| **Medium** | Release build signed with the debug key | `android/app/build.gradle` | Not publishable; Google sign-in needs the release SHA-1 | Release keystore outside git, plus its SHA-1 on the OAuth client |
| **Medium** | Hard-coded developer path `/home/razib/Desktop/BitDrop/Music` | `live_core.dart`, `scenario_sheet.dart` | Startup scan on every desktop run; dead code on phones | Delete, or move to a dev flag |
| **Medium** | Docs drift from the code. `task.md` and the `README` tick off a limiter, $8\text{--}16\text{ MB}$ LRU chunks and 64-bit DSP; the code has no limiter, $2\text{ MB}$ chunks with no LRU, and `f32` | `README.md`, `task.md`, 4 audit docs | Decisions made on features that do not exist | One `ARCHITECTURE.md` kept true to the code; archive the rest |
| **Medium** | Clutter: 12 `patch_*.py` in `app/`, 31 in `scripts/patch_archive`, plus `spike_ffi` and `spike-audio` | Repo | Hard to tell what is live | Delete; git history keeps them |
| **Low** | Dart polls the engine with several sync FFI calls per tick | `audio_handler.dart` | Battery use and late state changes | Push events through a `flutter_rust_bridge` `StreamSink` |
| **Low** | Tests miss the audio. The Rust EQ test only checks output is finite; nothing covers frequency response, noise, clipping, end of track or gapless | `audio_engine.rs` tests | All the bugs above passed CI | Golden DSP tests and an offline render test (spec below), run in CI |

---

### Engine v2 architecture

The v2 engine keeps today's Flutter + Rust + Oboe split but gives every slow job its own thread, so the audio callback only reads, filters and writes.

#### Slow work stays off the real-time audio callback

```
┌────────────────────────────────────────────────────────────────────────────────────┐
│ Flutter UI (Dart)                                                                  │
│ Screens render from engine events and only send commands; no mock core, no polling │
└───────────────────────┬────────────────────────────────────▲───────────────────────┘
                        │ commands                           │ events (StreamSink)
┌───────────────────────▼────────────────────────────────────┴───────────────────────┐
│ Rust core (one library, all platforms)                                             │
│                                                                                    │
│  ┌───────────────────────────────────────┐  ┌───────────────────────────────────┐  │
│  │ Fetch scheduler (tokio)               │  │ Control thread                    │  │
│  │ ~30 s bitrate-aware read-ahead,       │  │ Commands in, events out           │  │
│  │   2–3 ranges                          │  │ Settings, EQ presets, library     │  │
│  │ Per-chunk retry; token refresh on 401 │  │   in SQLite                       │  │
│  │ Sparse cache, LRU cap, chunk table    │  │ DSP planner: f64 coeffs +         │  │
│  │   in SQLite                           │  │   auto-preamp                     │  │
│  └───────────┬───────────────────────────┘  └────────┬──────────────────────┬───┘  │
│              │ bytes                     load / seek │                      │      │
│              ▼                                       ▼                      │      │
│  ┌─────────────────────────┐    ┌─────────────────────────┐                 │      │
│  │ Decode thread           │    │ PCM ring (SPSC)         │  params         │      │
│  │ Symphonia, gapless on   ├───►│ frames + track markers  │  (triple buffer)│      │
│  │ Next track pre-opened   │    │ sized in time, ~1.5 s   ├────────┐        │      │
│  │ Resample only if needed │    └─────────────────────────┘        │        │      │
│  └─────────────────────────┘                                       ▼        ▼      │
│                                                    ┌────────────────────────────┐  │
│                                                    │ Audio callback (real-time) │  │
│                                                    │ No locks, no allocations   │  │
│                                                    │ Reads params from triple   │  │
│                                                    │   buffer                   │  │
│                                                    │ Counts frames played +     │  │
│                                                    │   markers                  │  │
│                                                    └───────────────┬────────────┘  │
│                                                                    ▼               │
│  ┌──────────────────────────────────────────────────────────────────────────────┐  │
│  │ DSP chain inside the callback, all f64                                       │  │
│  │ Auto-preamp → EQ biquads (smoothed) → 18 Hz subsonic high-pass →             │  │
│  │ balance / mono → lookahead limiter (ceiling -1 dBFS) →                       │  │
│  │ TPDF dither, integer output only                                             │  │
│  │ Bit-exact bypass when EQ, preamp, ReplayGain and volume are all neutral      │  │
│  └───────────────────────────┬──────────────────────────────────────────────────┘  │
└──────────────────────────────┼─────────────────────────────────────────────────────┘
                               │ samples out
          ┌────────────────────┴────────────────────┐
          ▼                                         ▼
┌───────────────────────────────────────────┐  ┌─────────────────────────────┐
│ Android shell (Kotlin + Oboe)             │  │ Desktop / iOS (cpal)        │
│ AAudio stream; bit-perfect mixer          │  │ Same renderer code,         │
│   attributes on API 34+                   │  │ no duplicate callback       │
│ USB DAC probe, audio focus, MediaSession  │  │                             │
└───────────────────────────────────────────┘  └─────────────────────────────┘
```
*BitDrop engine v2 threads, buffers and data flow*

The control thread is the only writer of state; the callback receives finished coefficient sets and reports progress through atomics, and the control thread turns that into events for Dart. Track ends and gapless joins come from markers in the ring, not from Dart guessing from the position.

---

### DSP v2 spec

The chain runs in 64-bit float, sets headroom from the real curve, and has a limiter as a safety net. With a correct preamp the same bass preset peaked at $-2.7\text{ dBFS}$ on *Bulleya*, with zero clipped samples.

| Stage | Spec | Why |
| :--- | :--- | :--- |
| **Resampler (only if output rate $\neq$ source)** | Prefer opening the output at the source rate. Otherwise `rubato` fixed-ratio FFT resampler in `f64`, or sinc length 256, cutoff $0.95$, oversampling 256, cubic interpolation | 64-tap async sinc leaves audible aliasing on $44.1$ to $48\text{ kHz}$ |
| **Auto-preamp** | $-(\text{peak of the engine's real summed response, } 10\text{ Hz to Nyquist})$, computed in Rust from the same coefficients the filters use, and on by default | Removes the screen-vs-engine mismatch and most clipping |
| **ReplayGain** | Track gain capped at $-20 \cdot \log_{10}(\text{track peak})$ | Positive gain on quiet tracks never clips |
| **EQ filters** | `f64` coefficients and `f64` state (TDF-II is fine in `f64`; a Cytomic/Simper SVF if you want smoother modulation) | Precision error falls far below the 16- and 24-bit noise floor at every rate |
| **Graphic mode** | All 10 bands peaking, constant-$Q$ octave ($Q \approx 1.41$), exactly what `biquad.dart` draws | Screen and sound match |
| **Tone mode** | Shelves at $Q = 0.707$ (shelf slope $S = 1$) | No overshoot or dip |
| **Subsonic filter** | 2nd-order Butterworth high-pass at $18\text{ Hz}$, on whenever a band below $60\text{ Hz}$ is boosted | Stops boost energy going into inaudible $5\text{--}20\text{ Hz}$ |
| **Parameter changes** | New coefficient set built on the control thread, then crossfaded over $\sim 20\text{ ms}$ in the callback | No zipper noise while dragging |
| **Balance and mono** | Own stage after the EQ, whatever the EQ state | Works with the EQ off |
| **Limiter** | Lookahead peak limiter, $1.5\text{ ms}$ lookahead, ceiling $-1\text{ dBFS}$, $\sim 80\text{ ms}$ release; gain reduction and clip count sent to the UI | Catches what auto-preamp misses; the meter shows real numbers |
| **Output** | TPDF dither only when writing integer samples; float output needs none | Clean truncation on the bit-perfect integer path |
| **Bypass** | Untouched samples when EQ, preamp, ReplayGain and software volume are all neutral | Bit-exact path that a hash test can prove |

*Cost:* 16 bands plus the high-pass in `f64` stereo at $192\text{ kHz}$ is about $60\text{ million}$ floating-point operations a second, a small load for one phone core.

#### Tests to add, each a CI gate:
1. Engine frequency response within $0.05\text{ dB}$ of the reference from $20\text{ Hz}$ to $20\text{ kHz}$ at $44.1$, $48$, $96$ and $192\text{ kHz}$.
2. Every preset on the test FLACs with auto-preamp on: zero samples above $0\text{ dBFS}$.
3. Bypass: output hash equals input hash.
4. Offline render of a file: the last output frame equals the file's last frame (catches the cut-off ending).
5. Album render: sample-continuous across track boundaries (proves gapless).

---

### Fix order

Start with the EQ: it is the smallest change and the one you will hear right away.

1. **Sound quality.** `f64` filters; graphic bands all peaking; tone shelves at $Q = 0.707$; auto-preamp from the real curve, on by default; lookahead limiter; $18\text{ Hz}$ subsonic high-pass; mono and balance moved out of the EQ block. This fixes the bass complaint.
2. **Correctness.** End-of-stream marker (no more cut-off endings); `INTERNET` in the main manifest; remove the mutex and allocation from the callback; per-chunk retry; token refresh on 401; cancel fetches on skip.
3. **Repo cleanup.** Agree it with your teammate first, because rewriting history needs both clones reset. Purge `Music/` and the APK with `git filter-repo`, delete the patch scripts, merge the four audit docs into one `ARCHITECTURE.md`, set up a release keystore. After this the repo should fit on your device.
4. **Engine v2 refactor.** One shared `OutputRenderer` for Android and desktop; lock-free parameters; event stream to Dart instead of polling; real gapless with the next track pre-opened.
5. **Streaming v2.** Bitrate-aware read-ahead window, parallel ranges, LRU cache under a user-set cap, chunk state in SQLite.
6. **Platform and data.** Android 14 bit-perfect path with mixer attributes and DSP bypass; honest Tier C on Android 12 (your S10+); real AutoEq database in place of the mock profiles; EQ and settings saved in Rust.
7. **CI.** The five DSP tests above, plus `cargo clippy`, `cargo test`, `flutter analyze` and `flutter test` on every push.

> **[END OF VERBATIM CLAUDE AUDIT & ENGINE v2 ARCHITECTURE]**

---

# PART II: THE 6 CRITICAL ENGINEERING GUARDRAILS (WHY AGENTS BREAK AUDIO REPOS & HOW WE PREVENT IT)

Before any developer or AI coding agent touches the codebase, the following **6 Mandatory Engineering Guardrails** must be enforced across all phases:

### Guardrail 1: Out-of-Band SPSC Marker Queue (No Enum Bloat in PCM Ring Buffer)
* **The Trap:** In Engine v2, track endings and gapless transitions are signaled by markers in the ring buffer. If an agent changes `rtrb::RingBuffer<f32>` into `rtrb::RingBuffer<AudioItem>` where `enum AudioItem { Sample(f32, f32), Marker(TrackEvent) }`, Rust aligns the enum to 16 or 24 bytes per stereo frame, destroying SIMD/bulk slice copies and tripling memory bandwidth.
* **The Mandatory Solution:** Keep the PCM SPSC ring buffer strictly as raw interleaved numeric samples (`rtrb::RingBuffer<f64>` or `rtrb::RingBuffer<f32>`). Track two monotonic 64-bit frame counters: `decoder_frames_pushed: u64` and `callback_frames_played: AtomicU64`. Push track markers into a separate tiny lock-free side queue `rtrb::RingBuffer<BoundaryMarker>` (capacity 32) containing `{ trigger_at_frame: u64, kind: BoundaryKind }`. When `callback_frames_played >= marker.trigger_at_frame`, the callback pops the marker and signals `TrackEnded` / `TrackStarted` with single-sample accuracy.

### Guardrail 2: Safe 20 ms Filter Crossfading (Preventing TDF-II Pole Explosion)
* **The Trap:** Directly interpolating Transposed Direct Form II feedback coefficients ($a_1, a_2$) sample-by-sample when a user drags an EQ slider can momentarily push filter poles outside the unit circle ($\lvert z \rvert > 1$) at $192\text{ kHz}$, causing a loud pop or `NaN` lockup.
* **The Mandatory Solution:** Either:
  1. Implement the EQ filters as **Andy Simper / Cytomic Linear Trapezoidal State Variable Filters (SVF)** in `f64` (whose $g, k, a_1, a_2, a_3$ coefficients are unconditionally stable under linear per-sample interpolation), **OR**
  2. Maintain two `f64` TDF-II filter banks (`active_bank` and `target_bank`) inside `OutputRenderer`. When a new coefficient set arrives via the triple buffer, copy `active_bank`'s `z1`/`z2` state registers into `target_bank`, run both banks for $20\text{ ms}$ ($N = \lfloor 0.020 \times f_s \rfloor$ frames), and crossfade their audio outputs using $y[n] = (1 - \alpha) y_{\text{active}}[n] + \alpha y_{\text{target}}[n]$.

### Guardrail 3: Glitch-Free 18 Hz Subsonic High-Pass Engagement
* **The Trap:** Toggling a 2nd-order Butterworth high-pass filter at $18\text{ Hz}$ dynamically from "bypassed" to "active" the instant a sub-60 Hz band crosses $0.0\text{ dB}$ introduces an immediate phase and DC step discontinuity (an audible click).
* **The Mandatory Solution:** Keep the $18\text{ Hz}$ 2nd-order Butterworth HPF ($Q = 0.70710678$) continuously running in `f64` whenever `eq_enabled == true` (or smoothly crossfade its dry/wet mix over $20\text{ ms}$ when any band $< 60\text{ Hz}$ becomes $> 0.0\text{ dB}$). Bypass it completely when `eq_enabled == false` so the Bit-Exact Bypass hash test passes 100%.

### Guardrail 4: Pre-Allocated 1.5 ms Lookahead Limiter Buffer (Zero Callback Allocations)
* **The Trap:** At $44.1\text{ kHz}$, $1.5\text{ ms}$ is $66$ stereo frames; at $192\text{ kHz}$, $1.5\text{ ms}$ is $288$ stereo frames; at $384\text{ kHz}$, $1.5\text{ ms}$ is $576$ stereo frames. Reallocating a `Vec` when the sample rate changes inside the audio callback violates real-time rules.
* **The Mandatory Solution:** Pre-allocate a fixed-size array `delay_line: [[f64; 2]; 1024]` inside the limiter struct when the engine starts, and dynamically adjust only the active modulo wrap length `lookahead_len = ((sample_rate as f64 * 0.0015).round() as usize).clamp(1, 1023)`.

### Guardrail 5: Auto-Preamp Phase-Dispersion Headroom Margin
* **The Trap:** Minimum-phase IIR filters (especially the $18\text{ Hz}$ high-pass filter) alter harmonic phase relationships, which can increase time-domain peak levels by $+0.3$ to $+0.6\text{ dB}$ on square-like or heavily mastered $0.0\text{ dBFS}$ tracks even at frequencies where magnitude gain is $0.0\text{ dB}$.
* **The Mandatory Solution:** Compute the exact complex transfer function magnitude $\lvert H_{\text{total}}(e^{j\omega_k}) \rvert$ across 512 logarithmically spaced frequencies from $10\text{ Hz}$ to Nyquist:
  $$\text{auto\_preamp\_db} = -\max\left(0.0, \max_{k} 20\log_{10}\left\lvert H_{\text{total}}\left(e^{j\omega_k}\right)\right\rvert\right)$$
  Coupled with the $-1.0\text{ dBFS}$ lookahead peak limiter downstream, this guarantees $0$ samples ever clip above $0.0\text{ dBFS}$ while keeping loudness transparent.

### Guardrail 6: Backup Test FLACs *Before* Untracking `Music/`
* **The Trap:** If the agent deletes `Music/` in Phase 3 before running the empirical clipping tests on *Ae Dil Hai Mushkil*, *Bulleya*, *O Sajna*, and *Aadat*, you lose your golden reference test corpus.
* **The Mandatory Solution:** In Phase 1, the very first shell command copies `Music/*.flac` to `/tmp/bitdrop_golden_flacs/` (outside the repository) so all golden FLAC tests run against the exact files used in Claude's audit.

---

# PART III: ENTERPRISE 7-PHASE MASTER EXECUTION PLAN

Each phase below is designed to be completed, tested, and committed as an independent unit of work.

| Phase | Name | Primary Files Modified | Est. Effort | Blocking CI Gate |
| :--- | :--- | :--- | :--- | :--- |
| **Phase 1** | **DSP v2 (`f64` Audio Quality Overhaul)** | `rust/src/dsp.rs` (new), `rust/src/audio_engine.rs`, `app/lib/core/biquad.dart` | 2–3 Days | Golden DSP Tests 1, 2 & 3 (`cargo test`) |
| **Phase 2** | **Engine Correctness & Real-Time Safety** | `rust/src/audio_engine.rs`, `rust/src/media_source.rs`, `android/app/src/main/AndroidManifest.xml` | 2–3 Days | Golden Test 4 (No Cut-off Endings) + Zero Locks in Callback |
| **Phase 3** | **Repo Cleanup & Documentation Unification** | `.gitignore`, `ARCHITECTURE.md`, `android/app/build.gradle` (remove `Music/`, `patch_*.py`) | 1 Day | Repo size $< 50\text{ MB}$, clean `cargo test` & `flutter analyze` |
| **Phase 4** | **Engine v2 Architecture & True Gapless** | `rust/src/renderer.rs` (new), `rust/src/audio_engine.rs`, `rust/src/api.rs`, `app/lib/services/audio_handler.dart` | 3–4 Days | Golden Test 5 (Sample-Continuous Gapless Boundary) |
| **Phase 5** | **Cloud Streaming v2 & SQLite LRU Cache** | `rust/src/media_source.rs`, `rust/src/range_fetcher.rs`, `rust/src/db.rs` | 3 Days | Bitrate-aware 30s read-ahead + SQLite CRC & LRU Eviction tests |
| **Phase 6** | **Platform Bit-Perfect HAL & Kill Mock Core** | `MainActivity.kt`, `app/lib/core/live_core.dart`, `rust/src/db.rs`, AutoEQ bundled assets | 3–4 Days | Zero `MockBitDropCore` imports in release + API 34 Mixer Attributes |
| **Phase 7** | **Full CI Pipeline & Release Hardening** | `.github/workflows/ci.yml`, `rust/tests/golden_audio_suite.rs` | 1–2 Days | All 5 CI Gates + `clippy` + `flutter test` green |

---

# PART IV: READY-TO-PASTE SEQUENTIAL AGENT PROMPTS (PHASES 1 TO 7)

> **Instructions for You:**  
> 1. Save this document in your repository root as `MASTER_PLAN.md`.  
> 2. Open your coding agent (Claude Code / Cursor / Windsurf / Cline) and paste **ONLY Prompt 1** below.  
> 3. Wait for the agent to finish Phase 1 and show you the passing `cargo test` output.  
> 4. Commit the changes (`git commit -am "Phase 1: DSP v2 f64 overhaul"`), then paste **Prompt 2**, and repeat through **Prompt 7**.

---

### PROMPT 1: EXECUTE PHASE 1 — DSP v2 (`f64` SOUND QUALITY OVERHAUL)

Copy and paste this into your agent first:

```markdown
We are executing the BitDrop Engine v2 overhaul defined in `MASTER_PLAN.md` (which embeds the "BitDrop Audit & Engine v2 Architecture" specification).

Your task is to execute **PHASE 1 ONLY (Sound Quality & DSP v2 in `f64`)**. Do NOT touch Google Drive networking, SQLite schemas, or git history in this phase—stay strictly focused on the DSP pipeline so we can verify the audio improvements immediately.

### STEP 1: BACKUP GOLDEN TEST FLACS FIRST
Before changing any code, check if the `Music/` directory exists in the repo. If it does, copy all `.flac` files (`Ae Dil Hai Mushkil`, `Bulleya`, `O Sajna`, `Aadat`, etc.) to `/tmp/bitdrop_golden_flacs/` so our automated tests can run against them.

### STEP 2: IMPLEMENT THE `f64` DSP v2 PIPELINE (`rust/src/dsp.rs` & `rust/src/audio_engine.rs`)
Implement a dedicated, real-time-safe `f64` DSP module with zero heap allocations on the audio path:
1. **64-Bit Float Precision (`f64`):**
   - Convert all biquad filter coefficients (`b0, b1, b2, a1, a2`) and state variables (`z1, z2`) from `f32` to `f64`.
2. **Fix Graphic EQ vs. Screen Curve Mismatch:**
   - All 10 Graphic EQ bands (`31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 Hz`) MUST be **Peaking filters** with constant-Q octave bandwidth (`Q = 1.4142135623730951`), matching `biquad.dart` (`fromGraphicGains`) 1:1. Do NOT convert Band 1 (31 Hz) or Band 10 (16 kHz) into shelves!
3. **Fix Tone Mode Shelves:**
   - In Tone / Simple mode, the Bass low-shelf (100 Hz) and Treble high-shelf (10 kHz) MUST use `Q = 0.7071067811865476` (shelf slope `S = 1.0`, zero resonant overshoot).
4. **18 Hz Subsonic High-Pass Filter:**
   - Implement a 2nd-order Butterworth high-pass filter at `18.0 Hz` (`Q = 0.7071067811865476`) in `f64` that engages whenever any band below `60 Hz` (or Tone Bass) has gain `> 0.0 dB` (with smooth 20 ms crossfade on engagement so toggling never clicks).
5. **Real-Curve Auto-Preamp (Enabled by Default):**
   - Compute the true summed magnitude response $|H(e^{j\omega})|$ in dB of the exact `f64` filter cascade across 512 logarithmically spaced frequencies from `10.0 Hz` to `0.495 * sample_rate`.
   - Set `auto_preamp_db = -(peak_response_db.max(0.0))` and enable `auto_preamp` by default.
   - Support ReplayGain track gain capped at `-20.0 * log10(track_peak)`.
6. **20 ms Zipper-Free Parameter Crossfade:**
   - Build new coefficient sets off the audio callback. When a new coefficient set arrives in the callback, copy the active filter bank's `z1`/`z2` state into the target filter bank and crossfade their outputs over `20 ms` (`0.020 * sample_rate` frames) so dragging sliders never causes zipper noise or TDF-II pole instability.
7. **Independent Balance & Mono Stage:**
   - Move Stereo Balance and Mono mixdown out of the `if eq_enabled` block into their own stage after the EQ so accessibility settings work even when EQ is disabled.
8. **1.5 ms Lookahead Peak Limiter & TPDF Dither:**
   - Implement a `f64` stereo Lookahead Peak Limiter with a `1.5 ms` lookahead delay line (pre-allocated to fixed capacity `[[f64; 2]; 1024]` to support up to 384 kHz with zero runtime heap allocations), ceiling at `-1.0 dBFS` (`10.0_f64.powf(-1.0 / 20.0)`), and `80 ms` smooth exponential release.
   - Track real-time gain reduction (`limiter_gr_db`) and clipped sample counts via lock-free atomics for the UI meter.
   - Apply TPDF dither (using a fast inline SplitMix64/Xoshiro PRNG) ONLY when quantizing `f64` to integer output formats (`I16`, `I24`, `I32`).
9. **Bit-Exact Neutral Bypass:**
   - When EQ gains are all `0.0 dB` (or EQ is disabled), preamp is `0.0 dB`, ReplayGain is neutral, balance is `0.0`, mono is `false`, and software volume is `1.0`, bypass all math so output samples are bit-for-bit identical to input samples.

### STEP 3: WRITE & RUN PHASE 1 VERIFICATION TESTS
Add unit tests in Rust and run `cargo test`:
- **Test 1:** Verify engine frequency response matches theoretical `f64` reference within `±0.05 dB` from `20 Hz` to `20 kHz` at `44.1, 48, 96, and 192 kHz`, and verify the `31 Hz` `f64` SNR error vs reference is `< -120 dBFS` at `192 kHz` (fixing the `-29 dBFS` `f32` error).
- **Test 2:** Run the Graphic Bass preset (`+6, +5, +3, +1 dB` at `31, 62, 125, 250 Hz`) and Simple Bass `+6 dB` with auto-preamp + limiter on full-scale `0.0 dBFS` audio (and `/tmp/bitdrop_golden_flacs/` if present): assert **0 samples above `0.0 dBFS`** and peak `<= -1.0 dBFS`.
- **Test 3:** Verify Bit-Exact Bypass produces an identical SHA-256 hash between input and output buffers.

Show me the complete `cargo test` output and before/after peak & SNR metrics when finished.
```

---

### PROMPT 2: EXECUTE PHASE 2 — ENGINE CORRECTNESS, EOS MARKERS & REAL-TIME SAFETY

Once Phase 1 passes `cargo test`, paste Prompt 2:

```markdown
Phase 1 is complete and verified. Now execute **PHASE 2 ONLY (Correctness & Real-Time Safety)** from `MASTER_PLAN.md`.

### TASKS TO IMPLEMENT IN PHASE 2:
1. **Fix Cut-Off Track Endings (`audio_engine.rs`):**
   - Currently, when the decoder reaches EOF, it sets `is_playing = false` immediately while the ring buffer still holds up to 8.7 seconds of unplayed audio, causing the callback to mute the end of every song.
   - Fix: Do NOT set `is_playing = false` at decoder EOF! Maintain monotonic `decoder_frames_pushed: u64` and `callback_frames_played: AtomicU64` counters, and add a lock-free SPSC side queue `rtrb::RingBuffer<BoundaryMarker>` (capacity 32) holding `{ trigger_at_frame: u64, event: BoundaryEvent }`.
   - When the decoder hits EOF, push `BoundaryEvent::TrackEnded { file_id }` with `trigger_at_frame = decoder_frames_pushed`.
   - The real-time audio callback must keep playing buffered audio until `callback_frames_played >= marker.trigger_at_frame`, and only then mark the track as ended / raise `TrackEnded`.
2. **Remove Mutex Locks & Heap Allocations from Audio Callbacks (`audio_engine.rs`):**
   - Remove `PLAYER_STATE.lock()` and `eq_specs.clone()` from `on_audio_ready` (Android Oboe) and the `cpal` callback closure.
   - Pass pre-computed `f64` DSP coefficient snapshots from the control thread to the audio callback via a lock-free Triple Buffer (or atomic index swap over 3 pre-allocated `DspConfigSnapshot` slots).
3. **Replace `rubato` 64-Tap Resampler & Fix 5.1 Downmix (`audio_engine.rs`):**
   - Prefer opening the output stream at the source track's native sample rate.
   - When resampling is required, replace the 64-tap async resampler and per-packet `Vec` allocations with a pre-allocated `rubato` `FftFixedInOut<f64>` (or `SincFixedIn<f64>` with `sinc_len: 256, f_cutoff: 0.95, oversampling_factor: 256, interpolation: Cubic`) and log/propagate errors instead of silently dropping audio with `if let Ok`.
   - Replace the 5.1 surround drop with the standard ITU-R BS.775 downmix matrix including `FC`, `LFE`, `SL`, and `SR` (`0.7071` coefficient per surround/center/LFE channel).
4. **Fix Streaming Resilience (`media_source.rs`, `range_fetcher.rs`):**
   - Remove the sticky single-failure `cache.failed` dead-end. Add per-chunk retry (up to 3 retries with exponential backoff: 200ms, 500ms, 1200ms) and clear the failure flag when a retry succeeds.
   - Increment `active_generation` on track skip/stop so in-flight HTTP downloads for skipped tracks immediately abort.
   - Key the `CACHED` seek-bar byte-range telemetry by `file_id` so next-track prefetching never overwrites the playing track's seek bar.
   - Add 401 Unauthorized handling: when a range request returns HTTP 401, invoke a token-refresh callback to Dart, update the OAuth token, and retry the chunk transparently.
5. **Fix Android Release Network Permission (`android/app/src/main/AndroidManifest.xml`):**
   - Add `<uses-permission android:name="android.permission.INTERNET" />` to `android/app/src/main/AndroidManifest.xml`.

### VERIFICATION GATE FOR PHASE 2:
- Write and run **Golden Test 4 (`test_offline_render_no_cutoff_ending`)**: feed a complete audio file through the decoder -> SPSC ring -> callback renderer until `TrackEnded` fires, and assert that the total rendered frame count equals the source file's exact frame count and the final rendered frame equals the source file's last frame.
- Run `cargo test` and `cargo clippy` and confirm zero warnings/errors.
```

---

### PROMPT 3: EXECUTE PHASE 3 — REPOSITORY CLEANUP & DOCUMENTATION UNIFICATION

Once Phase 2 passes, paste Prompt 3:

```markdown
Phase 2 is complete. Now execute **PHASE 3 ONLY (Repository Cleanup, Clutter Removal & Documentation Unification)** from `MASTER_PLAN.md`.

### TASKS TO IMPLEMENT IN PHASE 3:
1. **Verify Backup & Untrack Bloated Binaries:**
   - First verify that `/tmp/bitdrop_golden_flacs/` contains our backup copies of `Music/*.flac`.
   - Remove `Music/` (476 MB) and any tracked `.apk` files (`spike-audio`, etc.) from git tracking (`git rm --cached -r Music/` and `git rm --cached` on tracked APKs) and ensure `.gitignore` blocks `Music/`, `*.apk`, `*.aab`, `*.jks`, and `*.keystore`. (Note: Do NOT run `git filter-repo --force` yet; we will do history purging together when syncing with the team).
2. **Delete Dead Patch Scripts & Spike Clutter:**
   - Delete the 12 `patch_*.py` scripts in `app/`, the 31 scripts in `scripts/patch_archive/`, and obsolete `spike_ffi` / `spike-audio` directories.
   - Remove the hardcoded `/home/razib/Desktop/BitDrop/Music` path from `live_core.dart` and `scenario_sheet.dart`.
3. **Release Signing Configuration (`android/app/build.gradle`):**
   - Update `android/app/build.gradle` to read release keystore credentials from `key.properties` (or environment variables) outside git, falling back to debug signing only when `key.properties` is absent in local dev builds.
4. **Single Source-of-Truth `ARCHITECTURE.md`:**
   - Consolidate the 4 drifted audit docs and `task.md` into a single, accurate `ARCHITECTURE.md` that truthfully documents the actual current state of the code (and moves historical docs to `docs/archive/`).

### VERIFICATION GATE FOR PHASE 3:
- Run `cargo test`, `cargo clippy`, and `flutter analyze` to verify deleting the dead clutter broke zero active imports.
```

---

### PROMPT 4: EXECUTE PHASE 4 — ENGINE v2 REFACTOR, UNIFIED RENDERER & TRUE GAPLESS

Once Phase 3 passes, paste Prompt 4:

```markdown
Phase 3 is complete. Now execute **PHASE 4 ONLY (Engine v2 Refactor: Shared `OutputRenderer`, Event StreamSink & True Gapless Playback)** from `MASTER_PLAN.md`.

### TASKS TO IMPLEMENT IN PHASE 4:
1. **Unified `OutputRenderer` (`rust/src/renderer.rs` & `rust/src/audio_engine.rs`):**
   - Eliminate the ~110 lines of duplicated audio callback code between Android (`PlayerCallback` / Oboe) and Desktop/iOS (`cpal` closure).
   - Extract a single platform-agnostic `OutputRenderer` struct that reads frames from the SPSC ring buffer, checks the `BoundaryMarker` SPSC queue, pulls parameter updates from the Triple Buffer, runs the `f64` DSP v2 chain, updates atomic telemetry counters, and writes to the output slice.
   - Ensure desktop `cpal` properly updates the DSP sample rate whenever the output stream opens or changes rate.
2. **Dedicated Control Thread & Dart `StreamSink` Event Push (`rust/src/api.rs`, `audio_handler.dart`):**
   - Implement the Engine v2 Control Thread architecture: Dart sends non-blocking commands in, and Rust pushes state changes (`PlaybackState`, `TrackStarted`, `TrackEnded`, `PositionUpdate`, `BufferTelemetry`, `LimiterTelemetry`) out to Dart via a `flutter_rust_bridge` `StreamSink<EngineEvent>`.
   - Remove the multi-call synchronous FFI polling loop in `audio_handler.dart`.
3. **True Gapless Playback & Accurate Frame-Exact Seek:**
   - Set `FormatOptions { enable_gapless: true, ..Default::default() }` in Symphonia so encoder delay and padding frames are automatically stripped.
   - Pre-open the next queued track (`next_track_source`) on the Decode thread before the current track reaches EOF.
   - When the current track hits EOF and the next track shares the same sample rate, push `BoundaryEvent::TrackChanged { next_file_id }` into the marker queue and continue decoding the next track's first sample directly into the **same SPSC ring buffer** with zero 260 ms fade-out/flush gap!
   - Fix coarse seek drift: after calling Symphonia `reader.seek()`, inspect the packet timestamp and discard leading frames up to the exact target sample frame so audio and lyrics never drift.

### VERIFICATION GATE FOR PHASE 4:
- Write and run **Golden Test 5 (`test_gapless_album_boundary`)**: split a continuous sine wave or musical passage across two FLAC/WAV files, decode both sequentially through the gapless engine into an offline buffer, and assert 100% sample continuity across the track boundary (zero dropped samples, zero inserted zeros, zero phase jump).
- Run `cargo test`, `cargo clippy`, and `flutter analyze`.
```

---

### PROMPT 5: EXECUTE PHASE 5 — CLOUD STREAMING v2 & SQLITE LRU CACHE

Once Phase 4 passes, paste Prompt 5:

```markdown
Phase 4 is complete. Now execute **PHASE 5 ONLY (Streaming v2: Bitrate-Aware Read-Ahead, Parallel Ranges & SQLite LRU Cache)** from `MASTER_PLAN.md`.

### TASKS TO IMPLEMENT IN PHASE 5:
1. **Bitrate-Aware 30-Second Read-Ahead Scheduler (`media_source.rs`, `range_fetcher.rs`):**
   - Replace the late "halfway through current 2 MB chunk" prefetch trigger (which only gave ~1 second of runway on 24/192 FLAC) with a Tokio Fetch Scheduler that calculates the track's byte rate (`size_bytes / duration_secs`) and maintains a rolling **30-second buffered window** ahead of the decode cursor using 2–3 concurrent HTTP range requests, adapting dynamically to measured network throughput.
2. **SQLite Chunk Integrity & CRC32 Verification (`db.rs`, `media_source.rs`):**
   - Replace the unchecked plain-text `.idx` chunk index files with a `cached_chunks` table in our SQLite database:
     `(file_id TEXT, chunk_idx INTEGER, byte_offset INTEGER, byte_len INTEGER, crc32 INTEGER, file_mtime INTEGER, last_accessed_ts INTEGER, PRIMARY KEY (file_id, chunk_idx))`.
   - Verify chunk file size and CRC32 before serving cached chunks; if Android OS storage cleaner truncated or deleted the backing file, automatically invalidate the SQLite entry and re-fetch the chunk instead of playing zeros/silence.
3. **User-Configurable LRU Cache Eviction (`db.rs`, `live_core.dart`):**
   - Wire the storage screen's cache size limit (e.g., 512 MB, 2 GB, 5 GB, 10 GB) to Rust SQLite settings.
   - Whenever new chunks are written and total unpinned cache bytes exceed the user's cap, evict the least-recently-accessed tracks/chunks (`ORDER BY last_accessed_ts ASC`), while exempting any user-pinned albums/tracks and the currently playing track.

### VERIFICATION GATE FOR PHASE 5:
- Write automated Rust tests verifying:
  1. Corrupted/truncated cache files on disk are detected via size/CRC32 mismatch and automatically re-fetched.
  2. Writing beyond the configured cache byte limit triggers LRU eviction of the oldest unpinned chunks while preserving pinned tracks.
- Run `cargo test` and `cargo clippy`.
```

---

### PROMPT 6: EXECUTE PHASE 6 — BIT-PERFECT ANDROID 14+ HAL, AUTOEQ DB & KILL MOCK CORE

Once Phase 5 passes, paste Prompt 6:

```markdown
Phase 5 is complete. Now execute **PHASE 6 ONLY (Platform Bit-Perfect HAL, Real AutoEQ Database & Removing `MockBitDropCore`)** from `MASTER_PLAN.md`.

### TASKS TO IMPLEMENT IN PHASE 6:
1. **Eliminate `MockBitDropCore` from `LiveBitDropCore` (`live_core.dart`, `db.rs`):**
   - Remove the `MockBitDropCore` instance and all forwarding calls inside `LiveBitDropCore`.
   - Persist all EQ states (enabled, mode, 10-band gains, bass/treble tone gains, preamp, auto-preamp, active preset name), device profiles, and app settings inside Rust SQLite so user settings survive app restarts.
   - Connect the UI diagnostics, clipping/limiter gain-reduction meter, and visualizer to real telemetry emitted by the Rust engine.
2. **Replace Placeholder AutoEQ Profiles with Real ParametricEQ Assets (`catalog.dart` / assets):**
   - Delete the fabricated placeholder AutoEQ numbers in `core_mock/catalog.dart` (including the fake DUNU Titan X numbers).
   - Bundle real MIT-licensed AutoEq ParametricEQ profiles in Flutter assets and wire the search & import flow through our real ParametricEQ parser into the Rust DSP engine.
3. **True Bit-Perfect Tier A/B on Android 14+ (API 34+) & Honest Tier C on Android 12–13 (`MainActivity.kt`, `audio_engine.rs`):**
   - In `MainActivity.kt`, on API 34+ (`Build.VERSION_CODES.UPSIDE_DOWN_CAKE`), query `AudioManager.getSupportedMixerAttributes(usbDevice)` and call `AudioManager.setPreferredMixerAttributes()` with `MIXER_BEHAVIOR_BIT_PERFECT` for the track's native sample rate and integer encoding (`PCM_24BIT_PACKED` / `PCM_32BIT` / `PCM_16BIT`) **before** opening the Oboe stream.
   - In Rust (`open_output_stream`), when Bit-Perfect mode is engaged (API 34+ and DSP is in neutral bypass), open the AAudio stream with `PerformanceMode::None`, `SharingMode::Shared`, `Usage::Media`, `ContentType::Music`, and native integer sample format so Android engages `MIXER_BEHAVIOR_BIT_PERFECT` instead of routing through the 48 kHz Fast Mixer.
   - Query `AAudioStream_getHardwareSampleRate()` and `AAudioStream_getHardwareFormat()` after stream open to report the true hardware path to the UI (honest Tier C `System Resampled` on Android 12/S10+, true Tier A `Bit-Perfect` on Android 14+ when DSP is bypassed).

### VERIFICATION GATE FOR PHASE 6:
- Verify zero references to `MockBitDropCore` remain in `live_core.dart` or release code paths.
- Verify EQ and settings persist across engine restarts via SQLite unit tests.
- Run `cargo test`, `cargo clippy`, `flutter analyze`, and `flutter test`.
```

---

### PROMPT 7: EXECUTE PHASE 7 — FINAL CI GATES & END-TO-END AUDIT VERIFICATION

Once Phase 6 passes, paste Prompt 7:

```markdown
Phase 6 is complete. Now execute **PHASE 7 (Final CI Gates & Full Audit Verification)** from `MASTER_PLAN.md`.

### TASKS TO IMPLEMENT IN PHASE 7:
1. **Complete Golden Audio CI Suite (`rust/tests/golden_audio_suite.rs`):**
   Ensure all 5 mandatory CI gate tests from the audit run deterministically on every `cargo test` invocation:
   - `gate_1_eq_frequency_response`: Asserts engine frequency response is within `±0.05 dB` of the mathematical `f64` reference from `20 Hz` to `20 kHz` at `44.1, 48, 96, and 192 kHz`.
   - `gate_2_zero_clipping_all_presets`: Runs every EQ preset (including Graphic Bass and Simple Bass `+6 dB`) with auto-preamp + limiter enabled across full-scale `0.0 dBFS` test audio (and `/tmp/bitdrop_golden_flacs/` if available) and asserts `0` samples exceed `0.0 dBFS`.
   - `gate_3_bit_exact_bypass_hash`: Asserts SHA-256 of output equals SHA-256 of input when EQ, preamp, ReplayGain, balance/mono, and volume are neutral.
   - `gate_4_offline_render_last_frame_exact`: Renders a complete file through Decode -> RingBuffer -> OutputRenderer and asserts the final output frame matches the source file's exact last frame (proving track endings are never cut off).
   - `gate_5_gapless_boundary_continuity`: Renders two sequential tracks across an album boundary and asserts sample-level waveform continuity with zero dropped or padded frames.
2. **GitHub Actions CI Workflow (`.github/workflows/ci.yml`):**
   - Configure CI to run `cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo test`, `flutter analyze`, and `flutter test` on every push and pull request.
3. **Final Audit Checklist Report:**
   - Run all suites and output a final verification table comparing the baseline commit (`4ae1930`) metrics against our new Engine v2 measurements across every single flaw listed in `MASTER_PLAN.md`.
```

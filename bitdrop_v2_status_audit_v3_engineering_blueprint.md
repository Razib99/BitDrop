# BITDROP: POST-v2 STATUS AUDIT, PRODUCTION READINESS & MILESTONE EXECUTION BLUEPRINT

**Reviewed Document:** `bitdrop_status_and_roadmap_for_argon.md` (Nov 6, 2026 | Branch: `main`)  
**Auditor Role:** Principal Systems Architect, Senior Audio DSP Engineer & Android Core Audio Specialist  
**Overall Readiness Score:** **88 / 100 (v1.0 Release Candidate — 2 Short Blockers Before Public Launch)**

---

## 1. EXECUTIVE VERDICT: IS BITDROP READY NOW?

**What you and your coding agent accomplished in the Engine v2 refactor is a massive engineering leap.** By following the phased execution plan, you resolved every single Critical and High audio defect identified in the baseline `4ae1930` audit:
* **Audio & DSP Quality (`dsp.rs` & `renderer.rs`):** Promoted to a lock-free, allocation-free $64\text{-bit}$ float (`f64`) pipeline with FTZ/DAZ hardware flags, 10-band octave graphic EQ + 32-band parametric EQ, a 512-point logarithmic auto-preamp, an $80\text{ ms}$ lookahead peak limiter ($-1.0\text{ dBFS}$ ceiling), and a SHA-256 verified bit-exact bypass path.
* **Cloud & Caching Engine (`cloud/` & `db.rs`):** Upgraded to a bitrate-aware $30\text{-second}$ read-ahead scheduler scaling across $1\text{--}4$ parallel HTTP workers, backed by SQLite `cached_chunks` with per-read CRC32 verification and sparse hole-punching LRU eviction.
* **Product Completeness:** Integrated a $4,900+$ profile AutoEQ SQLite FTS5 database ($< 3\text{ ms}$ BM25 search), an intelligent multi-stage Deezer/iTunes cover art engine with soundtrack propagation, a 3-phase morphing Spotify-style Ambient Aura UI, and **155 passing automated tests** (33 Rust tests including all **5 Golden Audio CI Gates** + 122 Flutter tests) with zero `MockBitDropCore` leakage.

### Is It Ready for v1.0 Release Today?
**Almost—you are ~2 days away from a rock-solid v1.0 release.** Before you ship to users or start the heavy multi-week R&D for **Milestone 1 (Tier D USB Driver)** and **Milestone 4 (Native DSD/DoP)**, there are **4 immediate architectural gaps/bugs** exposed in your status report that should be closed first:

1. **v1.0 Blocker 1 (Milestone 5):** `folders()` and `genres()` in `LiveBitDropCore` currently return empty lists (`[]`). After severing `MockBitDropCore`, tapping Folders or Genres in the UI shows an empty state.
2. **v1.0 Blocker 2 (Milestone 2):** The Signal Path sheet displays `⚠️ Resampled 44.1 -> 44.1 kHz` on Android 12—which is caused by reading the *client* AAudio sample rate instead of the *hardware* sample rate and conflating OS mixing with sample-rate conversion.
3. **Hidden Bug in Part 1.2 (Sparse Hole-Punching LRU Accounting):** Using `fallocate(FALLOC_FL_PUNCH_HOLE)` requires `FALLOC_FL_KEEP_SIZE`, which leaves the file's logical `metadata().len()` unchanged on disk.
4. **Hidden Risk in Part 1.4 (iTunes/Deezer Artwork Scanner Rate-Limiting & Negative Caching):** Scanning a library with hundreds of untagged tracks will trigger HTTP 403/429 blocks from Apple's iTunes Search API unless backed by a persistent negative cache and token-bucket rate limiter.

---

## 2. DEEP FORENSIC AUDIT OF CURRENT IMPLEMENTATION & ROADMAP MILESTONES

### 2.1 Root Cause of the `⚠️ Resampled 44.1 -> 44.1 kHz` Bug (Milestone 2)

Your status report notes:
> *"Currently, playing a 44.1 kHz FLAC on Android 12 displays `⚠️ Resampled 44.1 -> 44.1 kHz` with an alarming warning..."*

#### Why This Happens Under the Hood in Oboe / AAudio
When you open an Oboe stream on Android 12 (API 31) in `SharingMode::Shared` (or when `Exclusive` falls back to `Shared`) at the source track's sample rate ($44,100\text{ Hz}$):
1. Oboe sets the **AAudio Client Stream Rate** (`AAudioStream_getSampleRate()`) to $44,100\text{ Hz}$ so your Rust callback only has to push $44,100\text{ frames/sec}$.
2. However, inside the Android OS `AudioFlinger` server, the USB HAL for your DUNU Titan X is locked to the system mixer clock (typically $48,000\text{ Hz}$).
3. Your current Rust telemetry queries `oboe_stream.get_sample_rate()` (which returns the client rate: $44,100\text{ Hz}$), sees that the device is on Android 12 (`Tier C`), and formats the string `Resampled {source_rate} -> {stream_rate}`—producing the nonsensical string `Resampled 44.1 -> 44.1 kHz`!

#### How to Fix It Completely
Query **both** the client stream rate and the hardware HAL rate (`AAudioStream_getHardwareSampleRate(aaudio_stream)`, available since API 31 / Android 12) and classify the signal path into **4 distinct, honest states**:

| Condition | True Signal Path Behavior | UI Badge Text | Badge Color |
| :--- | :--- | :--- | :--- |
| API 34+ `MIXER_BEHAVIOR_BIT_PERFECT` active $\land$ DSP Bypassed | Hardware bit-exact passthrough to USB DAC | `Bit-Perfect · 96.0 kHz / 24-bit` | Emerald Green |
| API 34+ `MIXER_BEHAVIOR_BIT_PERFECT` active $\land$ DSP/EQ Enabled | 64-bit DSP at native hardware rate (no OS mixer) | `64-Bit DSP · Native 96.0 kHz` | Electric Cyan |
| `source_sr == hw_sr` (e.g., $48.0\text{ kHz} \to 48.0\text{ kHz}$ on Android 12) | Zero sample-rate conversion; routed via Android float mixer | `Native Rate (48.0 kHz) · OS Mixed` | Sky Blue (Info) |
| `source_sr != hw_sr` (e.g., $44.1\text{ kHz}$ source, `hw_sr == 48000`) | Resampled by Android `AudioFlinger` ($44.1 \to 48.0\text{ kHz}$) | `OS Resampled · 44.1 → 48.0 kHz` | Amber (Notice) |

Additionally, display the **Hardware Capability Subtitle** directly from `AudioDeviceInfo.getSampleRates()` and `getEncodings()`:
> *"DUNU Titan X hardware supports up to 384 kHz / 32-bit. Android 12 routes audio via the 48 kHz system mixer (enable Direct USB Driver or Android 14+ for Bit-Perfect bypass)."*

---

### 2.2 Sparse File Hole-Punching (`FALLOC_FL_PUNCH_HOLE`) Pitfalls (Part 1.2)

In Part 1.2, you implemented sparse file hole-punching (`fallocate FALLOC_FL_PUNCH_HOLE`) for LRU chunk eviction. Verify these two critical Linux VFS invariants in your Rust implementation:
1. **`FALLOC_FL_KEEP_SIZE` is Mandatory:** On Linux `ext4` and Android `f2fs`, calling `libc::fallocate(fd, FALLOC_FL_PUNCH_HOLE, offset, len)` **always fails with `EINVAL` or `EOPNOTSUPP`** unless the mode flag is bitwise-OR'd with `FALLOC_FL_KEEP_SIZE`:
   ```rust
   const MODE: libc::c_int = libc::FALLOC_FL_PUNCH_HOLE | libc::FALLOC_FL_KEEP_SIZE;
   ```
    Furthermore, `offset` and `len` should be aligned to $4096\text{-byte}$ filesystem block boundaries (which your $2\text{ MB}$ chunks naturally satisfy, except possibly the final partial chunk of a file).
2. **Disk Usage Accounting (`st_blocks` vs. `st_size`):** Because `FALLOC_FL_KEEP_SIZE` preserves the file's logical length (`st_size`), calling `std::fs::metadata(path)?.len()` on a $150\text{ MB}$ FLAC cache file that had $140\text{ MB}$ of chunks hole-punched will still report $150\text{ MB}$!
   * **Fix:** Always compute total cache usage either from SQLite (`SELECT COALESCE(SUM(byte_len), 0) FROM cached_chunks`) or via Unix allocated blocks (`std::os::unix::fs::MetadataExt::blocks(&meta) * 512`).

---

### 2.3 Online Cover Art Engine: Rate-Limit Protection & Negative Caching (Part 1.4)

Your 4-stage online cover art engine (Deezer Album $\to$ iTunes Album $\to$ iTunes $600\times 600$ Track $\to$ Deezer Track) with soundtrack propagation is a standout feature. However, guard against two production failure modes:
1. **The iTunes Search API ~20 Req/Min Rate Limit:** Apple's `https://itunes.apple.com/search` endpoint enforces a strict per-IP rate limit of roughly $20\text{ requests/minute}$. If a user imports $500$ untagged tracks, firing parallel requests will cause Apple to block the user's IP with HTTP `403`/`429`, and tracks scanned during the block will falsely fall back to the water-droplet placeholder.
   * **Fix:** Put Deezer first (Deezer allows $50\text{ requests / 5 seconds}$, which is $15\times$ more generous than iTunes) and gate iTunes fallback queries behind a $1\text{ request / 3 seconds}$ rate limiter with exponential backoff.
2. **Persistent Negative Caching (`artwork_status`):** If a rare underground bootleg track genuinely has no match on Deezer or iTunes, record `artwork_status = 2` (`Checked_NotFound`) in SQLite so BitDrop does not re-query the network for that track on every subsequent startup.

---

### 2.4 Milestone 3 Blueprint: Adaptive ITU-R BS.1770-4 True-Peak Limiter

Your status report proposes a $4\times$ oversampled polyphase FIR true-peak detector in `dsp.rs` to catch inter-sample peaks up to $+1.5\text{ to }+3.0\text{ dBFS}$.

#### Senior DSP Optimization: Rate-Adaptive Oversampling ($4\times$ / $2\times$ / $1\times$)
Why do inter-sample peaks occur? At $44.1\text{ kHz}$ or $48\text{ kHz}$, a $20\text{ kHz}$ sinusoid has only $\sim 2.2$ samples per period, so two consecutive samples can straddle the true analog crest at $\pm 45^\circ$, hiding up to $20\log_{10}(\sec(\pi / 4)) = +3.01\text{ dB}$ of inter-sample overshoot.
However, when playing a $96\text{ kHz}$ or $192\text{ kHz}$ Hi-Res FLAC, the audio spectrum is **already oversampled** relative to the $20\text{ kHz}$ audible band! Running a $4\times$ oversampler on a $192\text{ kHz}$ stream (synthesizing $768\text{ kHz}$!) wastes $4\times$ the CPU for zero acoustic benefit.

Implement **Rate-Adaptive Polyphase True-Peak Detection**:
* **When $f_s \le 48,000\text{ Hz}$ ($4\times$ Oversampling):** Run the standard 4-phase, 12-tap-per-phase (48-tap prototype) ITU-R BS.1770-4 polyphase FIR interpolator inside the sidechain detector. (Note: Phase 0 can just be the delayed original sample, reducing computation to **3 phases $\times$ 12 taps = 36 FMA operations per sample**!).
* **When $88,200\text{ Hz} \le f_s \le 96,000\text{ Hz}$ ($2\times$ Oversampling):** Compute only the midpoint phase (Phase 2: 12 taps per sample) alongside the direct sample.
* **When $f_s \ge 176,400\text{ Hz}$ ($1\times$ Direct):** Use the direct sample magnitude $\lvert x[n] \rvert$—at $192\text{ kHz}$, a $20\text{ kHz}$ waveform has $9.6$ samples per cycle, meaning maximum theoretical inter-sample error is $< 0.12\text{ dB}$, well within your $-1.0\text{ dBTP}$ ceiling!

> **Crucial Invariant:** The $4\times$ polyphase FIR filter must run **strictly in the sidechain peak-detection path** to compute the scalar gain-reduction envelope $g[n]$. The main audio path still passes directly through the $1.5\text{ ms}$ lookahead delay line and is multiplied by $g[n]$—meaning the oversampling FIR **never colors the audio or alters bit-transparency when $g[n] = 1.0$!**

---

### 2.5 Milestone 5 Blueprint: Hierarchical Folder & Genre Browsing (`db.rs` & `live_core.dart`)

To fix the empty `folders()` and `genres()` methods in `LiveBitDropCore`, do not rely on slow string splitting in Dart. Add two ultra-fast indexed queries in `db.rs`:

1. **Genres Query (`get_genres_summary`):**
   ```sql
   SELECT 
       CASE WHEN genre IS NULL OR TRIM(genre) = '' THEN 'Unknown Genre' ELSE TRIM(genre) END AS genre_name,
       COUNT(*) AS track_count,
       MAX(artwork_path) AS sample_artwork
   FROM tracks
   GROUP BY genre_name
   ORDER BY track_count DESC, genre_name ASC;
   ```
2. **Hierarchical Folders Table & Query (`folders`):**
   During Pass 1 (Google Drive directory traversal or local storage scan), store `parent_folder_id`, `folder_name`, and `folder_path` in SQLite:
   ```sql
   CREATE TABLE IF NOT EXISTS folders (
       folder_id        TEXT PRIMARY KEY,
       parent_id        TEXT,
       name             TEXT NOT NULL,
       full_path        TEXT NOT NULL,
       track_count      INTEGER NOT NULL DEFAULT 0,
       subfolder_count  INTEGER NOT NULL DEFAULT 0,
       sample_artwork   TEXT
   );
   CREATE INDEX IF NOT EXISTS idx_folders_parent ON folders(parent_id, name);
   ```
   For tracks already in the database where only `folder_path` is populated, run a one-time migration on startup that materializes the `folders` table from distinct `folder_path` prefixes so existing libraries populate the Folder Browser immediately without needing a re-scan.

---

### 2.6 Milestone 1 & 4 Guardrails: Tier D UAC2 Driver & Native DSD / DoP

When you move on to **Milestone 1 (Tier D USB Driver)** and **Milestone 4 (Native DSD/DoP)**, enforce these three hardware safety rules:

1. **Kernel Driver Re-Attachment on Exit (`snd-usb-audio`):**
   When your Rust UAC2 driver calls `libusb_set_auto_detach_kernel_driver(handle, 1)` and `libusb_claim_interface(handle, iface)`, Android's `AudioFlinger` loses access to the USB-C DAC. When the user exits BitDrop, switches to "Shared Mode", or unplugs the headset, you **must** call:
   ```rust
   libusb_set_interface_alt_setting(handle, as_iface, 0); // Zero-bandwidth Idle AltSetting
   libusb_release_interface(handle, as_iface);
   libusb_release_interface(handle, ac_iface);
   libusb_attach_kernel_driver(handle, ac_iface);
   libusb_attach_kernel_driver(handle, as_iface);
   ```
   If you do not reset `alt_setting` to `0` and re-attach the kernel driver before closing `libusb`, Android 12 will leave the USB-C port muted for all other apps (YouTube, phone calls) until the user physically unplugs and replugs the dongle!
2. **UAC2 Explicit vs. Implicit / Adaptive Endpoint Detection:**
   High-end desktop/dongle DACs use **Asynchronous Isochronous OUT** (`bmAttributes & 0x0C == 0x04`) with a dedicated 4-byte 16.16 Feedback IN endpoint. However, many compact Type-C IEM cables (including several integrated DSP Type-C cables like the DUNU Titan X) operate in **Adaptive (`0x08`) or Synchronous (`0x0C`) Isochronous Mode** without a separate Feedback IN endpoint!
   * **Fix:** Inspect `bmAttributes` of the Audio Streaming Isochronous OUT endpoint descriptor:
     * If `(bmAttributes & 0x0C) == 0x04` (**Asynchronous**) and `bSynchAddress != 0`: start the Feedback IN URB ring and pace packets from the 16.16 feedback register.
     * If `(bmAttributes & 0x0C) == 0x08` or `0x0C` (**Adaptive / Synchronous**) or `bSynchAddress == 0`: pace the Isochronous OUT microframe packet lengths directly from the nominal $16.16$ host clock ratio $\lfloor \frac{f_s \cdot 65536}{8000} \rfloor$ without opening a feedback IN endpoint!
3. **Hard-Locking DoP Against DSP & True-Peak Limiting:**
   In Milestone 4 (DoP v1.1), 16 bits of 1-bit DSD audio are packed with `0x05`/`0xFA` markers in the top 8 bits of each 24-bit PCM word. If the user enables AutoEQ, Graphic EQ, Preamp, Balance, Dither, or the True-Peak Limiter while a DoP stream is active, the `0x05`/`0xFA` markers will be overwritten, blasting $-0\text{ dBFS}$ white noise into their IEMs.
   * **Fix:** In `OutputRenderer`, if `stream_mode == StreamMode::DoP`: force-bypass the entire `f64` DSP, limiter, balance, volume, and dither pipeline at the hardware level. If the user turns on EQ during DSD playback, automatically switch the decoder from DoP packing to the **Lookup-Table Polyphase FIR DSD-to-PCM ($176.4\text{ kHz}$ `f64`) Decimator**.

---

## 3. RECOMMENDED EXECUTION ROADMAP & AGENT PROMPTS

To ship **BitDrop v1.0** cleanly and then roll out **v1.1 (Audiophile Pro: Tier D UAC2 + DSD)** without destabilizing your 155 passing tests, execute the remaining work in **3 focused sprints** using the copy-paste agent prompts below.

| Sprint | Scope | Est. Effort | Target Outcome |
| :--- | :--- | :--- | :--- |
| **Sprint A (v1.0 Launch Polish)** | Milestone 2 (Signal Path Honesty), Milestone 5 (Folders & Genres Browser), Sparse LRU Block Accounting & Artwork Negative Cache | 1–2 Days | **100% Feature-Complete v1.0 Public Release** |
| **Sprint B (v1.05 Mastering DSP)** | Milestone 3 ($4\times / 2\times / 1\times$ Adaptive ITU-R BS.1770-4 True-Peak Limiter) | 1 Day | **$\le -1.0\text{ dBTP}$ True Inter-Sample Peak Compliance** |
| **Sprint C (v1.1 Hardware & DSD)** | Milestone 1 (Tier D Rust UAC2 Driver for Android 12+) & Milestone 4 (Native DSD64/128 + DoP v1.1) | 4–5 Days | **Bit-Perfect Hardware Bypass on Android 12 S10+ & Native DSD** |

---

### AGENT PROMPT A: SPRINT A — v1.0 LAUNCH POLISH (SIGNAL PATH HONESTY + FOLDERS/GENRES + CACHE FIXES)

Copy and paste this into your coding agent first to make BitDrop 100% v1.0-ready:

```markdown
We have reviewed `bitdrop_status_and_roadmap_for_argon.md`. All 33 Rust tests (including the 5 Golden Audio Gates) and 122 Flutter tests are passing.

Before starting the Tier D USB driver, execute **SPRINT A (v1.0 Launch Polish: Milestone 2 + Milestone 5 + Cache/Artwork Hardening)** so that every screen in the app is 100% functional and accurate.

### TASK 1: FIX SIGNAL PATH REPORTING & HARDWARE SAMPLE RATE QUERY (Milestone 2)
Currently, playing a 44.1 kHz FLAC on Android 12 displays `⚠️ Resampled 44.1 -> 44.1 kHz` because the engine compares `source_sample_rate` against Oboe's client stream rate (`getSampleRate()`) instead of the actual hardware mixer rate (`AAudioStream_getHardwareSampleRate()`), and conflates OS mixing with sample-rate conversion.
1. In the Rust Android Oboe backend, query both the client stream sample rate AND the hardware sample rate (`hw_sample_rate` via Oboe/AAudio hardware rate APIs, falling back to `AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE` / `AudioDeviceInfo` when needed).
2. Disentangle **Sample Rate Conversion (SRC)** from **Android OS Mixing** in `output_device.dart`, `live_core.dart`, and the Signal Path Sheet:
   - **Case 1 (Bit-Perfect Tier A):** API 34+ `MIXER_BEHAVIOR_BIT_PERFECT` active AND DSP in neutral bypass -> Display Emerald badge: `Bit-Perfect · {sr} kHz / {bits}-bit`.
   - **Case 2 (Native Rate + 64-Bit DSP):** Hardware rate matches source rate AND BitDrop 64-bit DSP is active -> Display Cyan badge: `64-Bit DSP · Native {sr} kHz`.
   - **Case 3 (Native Rate · Android Mixed):** `source_sample_rate == actual_output_rate`, routed through Android shared mixer -> Display neutral/info Sky Blue badge: `Native Rate ({sr} kHz) · Android Mixed` (NEVER say `Resampled 44.1 -> 44.1 kHz`!).
   - **Case 4 (Resampled):** `source_sample_rate != actual_output_rate` (e.g., `44.1 kHz -> 48.0 kHz`) -> Display Amber badge: `Resampled · {source_sr} → {actual_sr} kHz`.
3. In the Signal Path hardware node, clearly separate **DAC Hardware Capability** from **OS Routing Ceiling** (e.g., *"Hardware supports up to {max_dac_sr} kHz / {max_dac_bits}-bit · Routed via Android {sdk_int} system mixer"*).

### TASK 2: IMPLEMENT HIERARCHICAL FOLDER & GENRE BROWSING (Milestone 5)
Currently, `folders()` and `genres()` in `LiveBitDropCore` return empty lists.
1. In `db.rs`, implement `get_genres()` and `get_tracks_by_genre(genre)` using indexed SQL queries over `tracks` (grouping null/empty genres under `'Unknown Genre'`, returning track count and representative cover `artwork_path`).
2. In `db.rs`, implement hierarchical folder indexing and browsing:
   - Create a `folders` view/table or indexed query over `folder_path` that extracts directory hierarchy (root folders, subfolders, track counts per folder, and sample artwork) for both Local and Google Drive tracks.
   - Expose `get_folders(parent_path)` and `get_tracks_in_folder(folder_path, recursive)` across `flutter_rust_bridge` to `LiveBitDropCore`.
3. Wire `folders()` and `genres()` in `live_core.dart` and verify the Library screen's Folders and Genres tabs render, navigate, and play folders/genres seamlessly.

### TASK 3: HARDEN SPARSE CACHE ACCOUNTING & ONLINE ARTWORK NEGATIVE CACHE
1. **Sparse Hole-Punching Verification (`cloud/` & `db.rs`):**
   - Ensure any `fallocate` hole-punching call uses `libc::FALLOC_FL_PUNCH_HOLE | libc::FALLOC_FL_KEEP_SIZE`.
   - Ensure total cache byte usage for LRU eviction is calculated from the sum of `byte_len` in the `cached_chunks` SQLite table (or Unix `MetadataExt::blocks() * 512`), NEVER from logical `std::fs::Metadata::len()` (since `FALLOC_FL_KEEP_SIZE` keeps logical file length unchanged after punching holes).
2. **Online Cover Art Negative Cache & Rate Limiting:**
   - Add an `artwork_checked` status column (or negative cache marker) in `tracks` so tracks that genuinely have no match on Deezer or iTunes are not re-queried on every app launch.
   - Ensure iTunes fallback queries are rate-limited to avoid Apple's ~20 req/min IP block during bulk library scans.

### VERIFICATION GATE FOR SPRINT A:
- Add unit tests in Rust (`db.rs`) for `get_genres()`, hierarchical `get_folders()`, and sparse LRU byte accounting.
- Add widget/unit tests in Flutter verifying that `44.1 -> 44.1 kHz` on Android 12 renders as `Native Rate (44.1 kHz) · Android Mixed` and never `Resampled 44.1 -> 44.1 kHz`.
- Run `cargo test`, `cargo clippy`, and `flutter test` and confirm 100% pass rate.
```

---

### AGENT PROMPT B: SPRINT B — MILESTONE 3 (ADAPTIVE ITU-R BS.1770-4 TRUE-PEAK LIMITER)

Once Sprint A passes, paste Prompt B to upgrade the peak limiter to full ITU-R BS.1770-4 True-Peak compliance:

```markdown
Sprint A is complete. Now execute **SPRINT B (Milestone 3: Adaptive 4x Oversampled ITU-R BS.1770-4 True-Peak Limiter)** in `app/rust/src/api/dsp.rs`.

### TECHNICAL SPECIFICATION:
1. **Sidechain-Only Polyphase FIR True-Peak Detector:**
   - To preserve 100% transparency in the main audio signal path, the polyphase FIR interpolator MUST run strictly inside the **sidechain peak detector** of our `f64` lookahead limiter to compute the true inter-sample peak `peak_env`, while the main audio continues to pass cleanly through the pre-allocated `1.5 ms` delay line.
2. **Standard 4-Phase, 12-Tap ITU-R BS.1770-4 Coefficients in `f64`:**
   - Implement a 4-phase, 12-tap-per-phase (48-tap windowed sinc prototype) polyphase FIR filter in `f64` with zero heap allocations (fixed-size history ring `[f64; 12]` per channel).
   - Phase 0 is the direct sample; Phases 1, 2, and 3 compute the $t + 0.25T$, $t + 0.50T$, and $t + 0.75T$ inter-sample reconstructions.
3. **Rate-Adaptive Oversampling Factor (CPU & Battery Optimization):**
   - For $f_s \le 48,000\text{ Hz}$: Evaluate all 4 phases ($4\times$ oversampling).
   - For $88,200\text{ Hz} \le f_s \le 96,000\text{ Hz}$: Evaluate Phase 0 and Phase 2 only ($2\times$ oversampling).
   - For $f_s \ge 176,400\text{ Hz}$: Evaluate Phase 0 only ($1\times$ direct sample, since $\ge 176.4\text{ kHz}$ is already $\ge 4\times$ oversampled relative to $20\text{ kHz}$).
4. **Verification Gate (Golden Audio True-Peak Test):**
   - Add a deterministic unit test `test_true_peak_inter_sample_clipping`: generate a $11,025\text{ Hz}$ ($f_s / 4$) sinusoid at $44,100\text{ Hz}$ with a $\frac{\pi}{4}$ ($45^\circ$) phase offset whose discrete samples sit at $0.0\text{ dBFS}$ ($\pm 1.0$) while its true inter-sample analog peak reaches $+3.01\text{ dBTP}$ ($\pm \sqrt{2}$).
   - Pass this signal through the Lookahead True-Peak Limiter (ceiling $-1.0\text{ dBTP}$) and verify that the $4\times$ reconstructed output stays strictly $\le -1.0\text{ dBTP}$ (with $< 0.05\text{ dB}$ tolerance).
   - Re-run all 5 Golden Audio CI Gates (`cargo test`) and confirm Gate 3 (Bit-Exact Bypass) and Gate 2 remain 100% green.
```

---

### AGENT PROMPT C: SPRINT C — MILESTONE 1 & 4 (TIER D UAC2 USB DRIVER & NATIVE DSD/DoP)

Once Sprints A and B are complete, use Prompt C to build the custom Android USB DAC driver and DSD engine:

```markdown
Sprints A and B are complete. Now execute **SPRINT C (Milestone 1: Tier D User-Space UAC2 Driver & Milestone 4: Native DSD / DoP v1.1)**.

### PART 1: TIER D USER-SPACE UAC2 DRIVER (`MainActivity.kt` & `app/rust/src/usb_dac/`)
1. **Kotlin USB Host Broker (`MainActivity.kt`):**
   - Add an opt-in setting `"Exclusive USB DAC Mode (Tier D)"` so users on Android 12–13 (like our Samsung S10+ testbed) can bypass `AudioFlinger` 48 kHz resampling.
   - When enabled and a USB audio device (`UsbConstants.USB_CLASS_AUDIO`) is connected, request permission via `UsbManager.requestPermission()`, open the device via `UsbManager.openDevice()`, and pass `connection.fileDescriptor`, `vendorId`, and `productId` to Rust via FFI.
2. **Rust `libusb` UAC1/UAC2 Isochronous Engine:**
   - Initialize `libusb` with `LIBUSB_OPTION_NO_DEVICE_DISCOVERY` and wrap the Android file descriptor using `libusb_wrap_sys_device`.
   - Enable `libusb_set_auto_detach_kernel_driver(handle, 1)` and claim the Audio Control (AC) and Audio Streaming (AS) interfaces.
   - Parse UAC2 (and UAC1 fallback) descriptors to discover supported sample rates, bit depths (`I16`, `I24_3LE`, `I32`), Clock Source entity ID (`CS_SAM_FREQ_CONTROL = 0x01`), and Feature Unit ID (`FU_VOLUME_CONTROL = 0x02`).
   - Inspect the Isochronous OUT endpoint's `bmAttributes`:
     - If **Asynchronous (`(bmAttributes & 0x0C) == 0x04`)** and `bSynchAddress != 0`: submit 4 Isochronous IN transfers to read the 16.16 fixed-point explicit feedback rate and dynamically pace the 12 in-flight Isochronous OUT transfers.
     - If **Adaptive (`0x08`) or Synchronous (`0x0C`)** (common on integrated Type-C IEM DACs like the DUNU Titan X): pace the 12 in-flight Isochronous OUT transfers using a 16.16 fractional phase accumulator locked to the nominal sample rate ratio $\lfloor (f_s \times 65536) / 8000 \rfloor$.
   - **CRITICAL CLEANUP INVARIANT:** Whenever Tier D playback stops, the DAC is unplugged, or the app closes, reset the AS interface to Alternate Setting `0`, call `libusb_release_interface`, and call `libusb_attach_kernel_driver` so Android's `snd-usb-audio` driver cleanly regains control of the USB port.

### PART 2: NATIVE DSD (`.dsf` / `.dff`) & DoP v1.1 ENGINE
1. **DSF/DFF Demuxer & Tag Reader:**
   - Implement a `DsfFormatReader` (and `DffFormatReader`) parsing the `'DSD '`, `'fmt '`, and `'data'` chunks (including the trailing ID3v2 metadata block in `.dsf` files and LSB-to-MSB byte bit-reversal LUT when `bits_per_sample == 1`).
2. **Dual-Mode DSD Output Pipeline:**
   - **DoP v1.1 Bit-Perfect Mode (when DAC supports DoP and DSP is disabled):** Pack 16 bits (2 bytes) of DSD per channel into 24-bit/32-bit PCM frames at $176.4\text{ kHz}$ (DSD64) or $352.8\text{ kHz}$ (DSD128) with alternating `0x05` / `0xFA` markers in the MSB byte.
   - **CRITICAL SAFETY INVARIANT FOR DoP:** When DoP mode is active, hard-bypass ALL software volume, de-click ramps, EQ, dither, and the True-Peak limiter so the `0x05`/`0xFA` markers can NEVER be modified. Use the DSD silence byte (`0x69`) during start/stop transitions.
   - **Byte-Indexed Polyphase FIR DSD-to-PCM Decimator (when DSP is enabled or sink is PCM-only):** Implement a precomputed 256-entry byte lookup table polyphase FIR low-pass decimator ($f_c = 24\text{ kHz}$) converting DSD64/128 cleanly to $88.2\text{ kHz}$ or $176.4\text{ kHz}$ `f64` PCM.

### VERIFICATION GATE FOR SPRINT C:
- Write unit tests verifying:
  1. Synthetic `.dsf` container parsing, bit-reversal, and DoP `0x05`/`0xFA` frame packing.
  2. DoP safety lock: attempting to enable EQ or change software volume while in DoP mode either stays bit-exact (hardware volume only) or cleanly switches to the DSD-to-PCM FIR decimator without corrupting a single `0x05`/`0xFA` marker.
  3. UAC2 descriptor parser and 16.16 fractional packet length accumulator accuracy at $44.1, 48, 96, \text{ and } 192\text{ kHz}$.
- Run `cargo test`, `cargo clippy`, and `flutter test`.
```
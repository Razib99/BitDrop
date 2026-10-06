# BitDrop — UI/UX Design Brief

> **For:** the design agent building BitDrop's UI/UX.
> **Status:** Phase 0 (the engine is not built yet). This brief covers **design + clickable prototype + state contract**, not production Flutter code.
> **Read this whole file before doing anything.**

---

## 0. Your role and your first steps

You are BitDrop's **lead product designer**, combining a senior mobile UX designer with someone who understands hi-fi audio. Your job is to design an app that does everything good in **Poweramp**, fixes what Poweramp gets wrong, and adds what no player has: **cloud-native lossless streaming with an honest signal path**.

**Read these first (they're in this repo):**
1. `README.md`: product vision, architecture, tiered audio output.
2. `bitdrop_audit.md`: technical constraints and risks. The UI must not contradict them.
3. `spike-drive/src/models.rs`: the real metadata fields the engine already extracts (`StreamInfo`, `FlacMetadata`, `PictureBlockInfo`, `RangeMeasurement`). Use these names in the state contract where they apply.

**Rules for working in this repo:**
- Create everything under a new top-level `design/` folder. **Don't modify anything outside `design/`.**
- Don't run `git commit` or `git push`. The owner reviews and commits.
- No network-dependent build steps. The prototype must open by double-clicking `design/prototype/index.html`.

---

## 1. The product in one paragraph

BitDrop is a mobile music player for people with large **lossless** libraries (FLAC, ALAC, WAV/AIFF; 16/44.1 up to 24/192) stored in **their own cloud storage**, starting with Google Drive. It streams straight from the user's Drive to their phone and USB DAC/IEM with **no BitDrop server in between**. It caches compressed audio on disk so playback survives bad networks, reads track tags without downloading whole files, and **tells the user exactly what happens to their audio** on the way to their ears (bit-perfect, native rate, or resampled by the system). It includes an audiophile-grade parametric EQ with AutoEQ profiles for IEMs.

The owner's original pain: *"Lossless files fill my phone. I have 2 TB on Google Drive. I want to listen to them like they're local, at full quality."*

---

## 2. Who it's for

| Persona | Context | What they need from the UI |
|---|---|---|
| **The IEM owner** (primary, the project owner) | Budget-to-mid IEM with a USB-C DAC plug (e.g. DUNU Titan X), Android phone, big FLAC library on Drive, sometimes on mobile data | Instant library, no storage worries, reliable playback, an EQ tuned for their IEM, clear "is this actually lossless?" feedback |
| **The DAC enthusiast** | Dedicated USB DAC/amp, Android 14+ phone, cares about bit-perfect | Precise technical readouts, signal-path transparency, per-device profiles, no silent quality loss |
| **The commuter** | Mostly metered data, patchy signal | Offline pinning, clear data usage controls, playback that doesn't stutter, visible buffer health |

---

## 3. "Like Poweramp, but much better"

### Keep from Poweramp
- Fast, gesture-friendly Now Playing (swipe artwork to skip)
- A strong EQ: parametric **and** graphic, presets, preamp, tone, balance
- Gapless playback, ReplayGain, folder browsing, lock screen and notification controls, widgets
- Deep customization, but **tasteful** (a few curated layouts and accent options, not skins)

### Fix from Poweramp
| Poweramp problem | BitDrop answer |
|---|---|
| Settings maze: hundreds of options in deep trees | Flat, grouped settings with plain-language explanations and search in settings |
| Dense, dated visuals; skins break consistency | One coherent design system in Light and Dark, with artwork-adaptive accent |
| "Hi-Res output" toggles with unclear real effect | **Signal Path** view showing *requested vs. actual* output, with honest labels |
| Local-only; cloud needs hacks | Cloud is first-class: every item shows whether it streams, is cached, or is pinned offline |
| EQ is powerful but intimidating | Visual frequency-response editor with draggable nodes plus AutoEQ search by IEM model |

### What's new (BitDrop-only)
1. **Signal Path**: a live pipeline from source → decoder → DSP → output → device, with a tier verdict.
2. **Cache-aware seek bar**: shows which parts of the track are already on disk (possibly several separate ranges after seeks).
3. **Cloud availability states** on every track, album and queue item.
4. **Gapless-honest queue**: marks where a short gap will happen because the sample rate changes.
5. **Hearing safety gate** for outputs that bypass software volume.
6. **Per-device profiles**: plug in a DAC and its EQ, volume and safety settings apply automatically.

---

## 4. Product rules the UI must enforce

1. **Honest signal path.** Never show "Bit-perfect" unless the engine confirms Tier A **and** no DSP or digital volume is active. Labels come from what was actually negotiated, never from what was requested.

   | Tier | Exact label | Meaning | Color semantics |
   |---|---|---|---|
   | A | **Bit-perfect** | Untouched samples at native rate (Android 14+, supported DAC) | Distinct "achievement" color, used sparingly |
   | B | **Native rate** | No resampling, but system volume/mixing may apply | Calm positive |
   | C | **Resampled by system · 48 kHz** (show the actual rate) | Android mixes at a fixed rate | **Neutral, not an error.** Never red or alarming |
   | — | **Native rate · DSP active** | Tier A device, but EQ/volume/ReplayGain is on | DSP/amber accent |
   | iOS | **Native rate** (until verified) | iOS has no bit-perfect API | Same as B |

   Each label must use **text + icon**, never color alone.
2. **The UI is a client.** All playback, queue, library and settings state lives in the Rust core. Every screen must have designs for **loading, empty, error, offline and partial** states, not just the happy path.
3. **Cloud is first-class.** Every track has an availability state (see §7.4), shown consistently everywhere.
4. **Hearing safety.** Any output path where software volume is off (Tier A) must go through the safety gate first (§8.14).
5. **No fake data.** No decorative visualizers driven by fake values, no invented "quality scores." A spectrum or level meter is allowed only as an *optional* element fed by real, low-rate data from the core (≤30 updates/s). Buffer and cache indicators reflect real values.
6. **Precise format chips.** Show formats exactly: `FLAC · 24/96`, `ALAC · 16/44.1`, `WAV · 24/192`, `MP3 · 320k` (styled visibly differently: lossy), `APE` (greyed, "Unsupported format"). Use tabular figures for all numbers.
7. **Zero-server honesty.** No features that would need a BitDrop server: no social, no BitDrop account, no cross-device sync, no web lyrics or metadata lookups. Lyrics are **embedded-only** (or out of scope for v1).

---

## 5. Platform, devices, technical constraints

- **Android first** (minimum Android 12), **iOS later**. Design platform-neutral on a **Material 3** foundation with a custom theme. Note any iOS adaptations (e.g. no Bit-perfect tier, iOS-style sheets) in the design system.
- **Reference frame:** **412 × 869 dp** (Samsung Galaxy S10+, the test device). Also check **360 dp width** (small phones) and **landscape Now Playing**. A tablet two-pane layout is a stretch goal; a sketch is enough.
- **Flutter feasibility:** everything must be buildable in Flutter at 60 fps on 2019 hardware (S10+). Use backdrop blur sparingly (one layer on Now Playing at most). No web-only tricks. Prefer effects Flutter does cheaply (gradients, opacity, transforms, clipping).
- **System-rendered surfaces:** Android 13+ draws media notifications and lock screen controls **from MediaSession data**. You can only control artwork, title/artist/album, and a few custom actions. Design what goes *into* them; don't design a custom lock screen.
- **Fonts and icons must be open-licensed and bundleable** (OFL or Apache). Suggestions: Inter / Manrope / IBM Plex Sans for UI; JetBrains Mono / IBM Plex Mono or a tabular-figure variant for technical readouts; Material Symbols Rounded or Phosphor for icons, plus custom glyphs for tiers and cloud states.

---

## 6. Visual direction

**Concept: "Precision instrument."** Calm, confident and quiet by default. Rich detail appears where an enthusiast looks for it (signal path, EQ, format info). Inspiration: the faceplates of high-end hi-fi gear (machined aluminium, VU meters, engraved labels), translated into **flat, modern UI**. Not skeuomorphic, no fake knobs. **Album art is the hero** and the main source of color.

- **Dark mode:** near-black base (around `#0B0C0E`) with 3–4 surface levels for depth. Offer an **OLED pure-black** option.
- **Light mode:** warm off-white "paper" base, not stark white. Technical readouts stay highly legible.
- **Accent:** propose one **brand accent**, plus an **artwork-derived accent** on Now Playing with an automatic contrast guard (fall back to the brand accent if contrast fails).
- **Typography:** a clear type scale (display → caption). Technical numbers (`24/96`, `−6.2 dB`, `8.4 Mbps`, `03:41`) always use **tabular figures**.
- **Shape:** consistent radii (e.g. 4/8/12/16/28 dp), 4 dp spacing grid.
- **Semantic colors** (light and dark variants, all WCAG AA): Bit-perfect, Native rate, Resampled (neutral), DSP active, Buffering, Pinned offline, Cached, Warning, Error.
- **Mood boards are optional.** Explain the decisions in `DESIGN_SYSTEM.md`.

---

## 7. Information architecture

### 7.1 Navigation (propose and justify; this is the starting point)
- **Bottom navigation (4):** Home · Library · Search · Settings
- **Mini player** docked above the bottom nav whenever something is queued
- **Now Playing** is a full-screen sheet that expands from the mini player (swipe up / tap)
- Queue, Signal Path and EQ open **from Now Playing** as sheets or pushed screens, and are also reachable from Settings

### 7.2 Sitemap
```
Onboarding ─► Welcome → Connect Google Drive → Choose music folders → First scan → Audio device check → (Hearing safety gate if Tier A)
Home
Library ─► Albums | Artists | Tracks | Folders | Genres | Playlists
          ├─ Album detail
          ├─ Artist detail
          ├─ Folder browser (Drive path)
          └─ Playlist detail / editor
Search
Now Playing ─► Queue · Signal Path · Equalizer & DSP (→ AutoEQ browser) · Volume · Output device · Sleep timer
Settings ─► Audio output · Playback · Sources & accounts · Library & scanning · Network & data · Storage & offline · Appearance · Diagnostics · About
```

### 7.3 Global surfaces
Mini player · snackbars/toasts · inline banners (offline, re-auth needed, scanning, rate-limited) · bottom sheets · dialogs · multi-select action bar.

### 7.4 Cloud availability states (design an icon and treatment for each)
| State | Meaning | Where it's shown |
|---|---|---|
| Cloud | Streams from Drive; nothing cached | Default; may show no icon to reduce noise. Decide and justify |
| Partially cached | Some byte ranges on disk | Track row, queue row |
| Cached | Fully on disk, but may be evicted | Track row, album badge |
| **Pinned offline** | Guaranteed available offline | Track row, album card badge, filter |
| Downloading | Pin in progress (progress ring) | Track row, album card |
| Unavailable offline | No network and not cached | Greyed but visible |
| Unsupported format | APE / WavPack / DSF / DFF / Opus | Greyed, reason on tap |
| Missing | Deleted or moved in Drive | Tombstoned row, "Remove" action |

---

## 8. Screen-by-screen specification

For **every** screen, design: default state, loading/skeleton, empty, error, offline, **Light and Dark**.

### 8.1 Onboarding
1. **Welcome:** value proposition in one line ("Your lossless library, streamed from your own cloud."), privacy promise ("No BitDrop servers. Your files go straight from Drive to your phone.").
2. **Connect Google Drive:** follow Google's "Sign in with Google" branding guidelines. Explain *why* read-only access to the whole Drive is needed, in plain language. Design the **"unverified app" warning** explainer, since the app is in Google testing mode for now.
3. **Choose music folders:** Drive folder picker with checkboxes, file counts and sizes; "Scan entire Drive" option with a warning about time and quota.
4. **First scan:** the library appears **within seconds from folder/file names** (skeleton library), then fills in tags and artwork in the background. Show progress such as "Reading tags · 2,340 of 10,412" and let the user start playing immediately.
5. **Audio device check:** detect the connected output, show its tier with a friendly explanation (e.g. for Android 12: "Android 12 mixes all audio at 48 kHz, so your music is resampled before reaching the DAC. Bit-perfect needs Android 14+ and a supported DAC."). Option to skip.
6. **Hearing safety gate** (only if Tier A is possible), see §8.14.

### 8.2 Home
- Optional connected-device card: "DUNU Titan X · Resampled by system · 48 kHz" → Audio output settings
- Continue listening (last queue/position)
- Recently added from Drive
- Pinned offline
- Hi-Res picks (albums ≥ 24/88.2)
- Rediscover (not played in 6+ months, from local play history only)
- Scan/sync status card while scanning
- Empty state for a brand-new library; offline state that shows only playable content

### 8.3 Library
- Tabs: **Albums · Artists · Tracks · Folders · Genres · Playlists**
- Album grid (2 or 3 columns, or list). Card: artwork, title, artist, top **format chip** (highest resolution in the album), availability badge
- **Sort:** Name, Artist, Year, Recently added, **Resolution** (audiophile touch), Size, Duration
- **Filter chips:** Hi-Res only · Lossless only · Available offline · Format (FLAC/ALAC/WAV/AIFF/MP3/AAC)
- Fast scroller with a letter bubble
- **Enrichment state:** rows built from file paths before tags are read show path-derived names, shimmer on the missing fields, and a generated placeholder artwork color
- **Multi-select** (long-press): Play · Play next · Add to queue · Add to playlist · Pin offline · Unpin

### 8.4 Album detail
- Large artwork header; title, artist, year, genre, track count, total duration
- Format summary: `FLAC · 24/96 · 1.12 GB`
- **Mixed-format note** when relevant: "2 tracks are 16/44.1. Short gaps when the rate changes."
- Actions: **Play** · **Shuffle** · **Pin offline (1.12 GB)** · overflow (add to queue/playlist, go to artist, open folder)
- Track list: number, title, duration, format only if it differs from the album, availability icon, now-playing indicator
- Disc grouping (Disc 1 / Disc 2); CUE-sheet albums appear as normal tracks
- Footer: source path in Drive (`/Music/Steely Dan/1977 - Aja`)

### 8.5 Artist detail
Header, albums (by year), tracks played most (local history), "Appears on."

### 8.6 Folder browser
Breadcrumb Drive path; folders first, then audio files with format chips; non-audio files hidden (with a toggle); "Play folder" (recursive), "Shuffle folder", "Pin folder", "Set as library root."

### 8.7 Search
Instant results as you type, grouped into Top result · Tracks · Albums · Artists · Folders. **Format-aware queries** via chips or tokens (e.g. `24/192`, `flac`, `hi-res`). Recent searches. Offline mode searches only playable items, with a clear note.

### 8.8 Playlists
List, create, rename, reorder, delete; playlist detail with total duration, size and offline status; "Pin playlist offline."

### 8.9 Now Playing ★ (highest priority, design 2 directions first)
- **Top bar:** collapse chevron, "Playing from: Album · Aja", overflow (go to album/artist, pin, sleep timer, share track info as text)
- **Artwork:** large and rounded. **Swipe left/right to skip**; long-press opens the album
- **Title / artist / album** plus a favorite toggle
- **Format line:** `FLAC · 24-bit / 96 kHz · 2.9 Mbps` (tabular)
- **Signal path pill** (tappable → §8.10): e.g. `● Bit-perfect · 24/96 → USB DAC` or `◐ Resampled by system · 48 kHz`
- **Cache-aware seek bar** with three visual layers: *played*, *cached on disk* (can be several separate ranges), *not downloaded*. Scrubbing into an uncached region shows a "will buffer" hint. Elapsed and remaining times are tabular. **No waveform seek bar in v1** (it would need the whole file decoded).
- **Transport:** shuffle · previous · **play/pause** (large; becomes a buffering spinner when stalled) · next · repeat
- **Secondary row:** Queue · EQ (with an "active" dot) · Volume · Output device · Pin offline · Sleep timer
- **Buffer health:** hidden when healthy; shown when constrained ("Buffering ahead · 3 s").
- **Next-up peek:** "Next: Deacon Blues · gapless" or "Next: Ripple · short gap (44.1 → 96 kHz)"
- **Background:** subtle artwork-derived gradient or tint. Text contrast must pass AA.
- **Landscape layout:** artwork left, controls right.
- **Optional layouts** (Appearance setting): offer 2–3 curated Now Playing styles, e.g. *Artwork-first*, *Technical* (larger signal path and readouts), *Minimal*. This is BitDrop's tasteful answer to Poweramp skins.

### 8.10 Signal Path sheet ★
A vertical pipeline diagram, with every stage tappable for detail:
```
SOURCE     Google Drive · Aja.flac · FLAC 24/96 · 87.2 MB · 64% cached
DECODER    FLAC → 24-bit integer PCM
DSP        Bypassed (true bypass)   |   Active: Parametric EQ (8 bands, preamp −6.2 dB), Volume −12.0 dB
OUTPUT     Requested PCM 24-bit / 96 kHz  →  Actual PCM 24-bit / 96 kHz  ✓ match   (or a clearly shown mismatch)
DEVICE     DUNU Titan X (USB) · Hardware volume: unknown
VERDICT    [Tier label] + one-paragraph plain-language explanation + "How to get bit-perfect" link
```
**Network section:** download rate, seconds buffered ahead, bytes on disk vs. file size, dropouts this session (expect 0). Include examples for Tier A, Tier B, Tier C, DSP active, and an iOS variant.

### 8.11 Queue
- Current track pinned at the top; "Up next" list with drag handles and swipe-to-remove
- Each row shows **readiness**: Ready offline · Start cached · Will stream
- **Transition markers** between rows: "gapless" or "short gap · 44.1 → 96 kHz"
- Actions: Clear · Save as playlist · Shuffle remaining
- Collapsible **History** (previously played)
- "Playing from" grouping when the queue mixes sources

### 8.12 Equalizer & DSP ★
- **Modes:** Parametric · Graphic (10-band) · AutoEQ · Tone
- **Frequency response graph:** log axis 20 Hz–20 kHz, ±15 dB, 0 dB line. Draggable nodes (drag = frequency/gain, pinch or a secondary control = Q). The combined curve is bold, individual bands are faint "ghost" curves. Optional **target curve overlay** when an AutoEQ profile is active.
- **Band list:** enable toggle, filter type (Peak, Low shelf, High shelf, Low-pass, High-pass), frequency (Hz), gain (dB), Q. Numeric fields with steppers.
- **Preamp:** slider with an **auto-preamp suggestion** and a **headroom/clipping indicator** ("Peak +1.3 dB, clipping risk") plus a clipped-samples counter from the core
- **Master bypass** (true bypass) and **A/B compare** (press and hold to hear bypass)
- **Presets:** save, rename, delete, import (AutoEQ `ParametricEQ.txt` file or paste), export
- **Per-device auto-apply:** "Use this preset whenever *DUNU Titan X* is connected"
- **Bit-perfect impact banner** on Tier A devices: "EQ is on. Output is Native rate, not Bit-perfect."
- **Tone tab:** Bass and Treble shelves, L/R balance
- **Excluded:** reverb, "3D," "bass boost" gimmicks

### 8.13 AutoEQ browser
Search headphones/IEMs by name ("Titan X"), results with measurement source and a curve preview, apply as a new preset, see the applied preamp. Design the empty-search state, the no-results state (offer import from file), and the applied-confirmation state.

### 8.14 Volume and hearing safety
- **Volume panel:** in-app volume in dB (e.g. −60 to 0 dB), tabular readout, plus a label saying what it controls: *Hardware (DAC)* · *Digital (24-bit, dithered)* · *System*
- **Hearing safety gate** (multi-step modal, remembered per device):
  1. "Remove your IEMs or headphones" (illustration)
  2. "We'll play a quiet test tone"
  3. "Do your volume keys change the loudness?" → Yes / No
  4. If No: "Safety attenuation is on (−20 dB digital). Output will show as Native rate." with a way to change it later
- Re-runnable from Settings → Audio output

### 8.15 Mini player, notification, lock screen, widget
- **Mini player:** artwork thumbnail, title/artist, play/pause, next, thin progress line, tier dot. Swipe up opens Now Playing; swipe sideways skips.
- **Notification / lock screen:** specify the artwork, metadata and custom actions (e.g. Favorite, Pin) that go into MediaSession. Show how they render in Android's system media controls.
- **Home-screen widgets** (stretch): 4×1 and 4×2.

### 8.16 Settings (flat, searchable, every option explained in one line)
- **Audio output:** current device card (tier plus explanation), "Prefer bit-perfect when available," output bit depth when DSP is active (24/32-bit), **per-device profiles** (EQ, volume, safety), re-run safety gate, safety attenuation
- **Playback:** gapless (always on, informational), crossfade (**disabled while Bit-perfect**, with reason), ReplayGain (Off / Track / Album plus preamp; off while Bit-perfect), audio focus behavior (pause vs. duck; ducking unavailable in Bit-perfect), resume behavior, sleep timer default
- **Sources & accounts:** Google Drive account card (email, status, **re-authorization needed** banner, testing-mode note), library root folders, "Add source" with S3 / WebDAV / OpenSubsonic shown as *Coming later*, sign out
- **Library & scanning:** sync now, last synced, scan on Wi-Fi only, include Shared drives / "Shared with me", show unsupported files, artwork preference (embedded vs. `folder.jpg`), rebuild library
- **Network & data:** stream on mobile data (Allow / Ask / Never), prefetch on mobile data (Off / Current track / Next tracks), Wi-Fi prefetch depth, estimated data used this month
- **Storage & offline:** cache budget slider (e.g. 2–64 GB), **storage breakdown bar** (Pinned · Cache · Artwork · Database · Free), pinned albums list with sizes, clear cache
- **Appearance:** Light / Dark / System, OLED pure black, accent (Brand / From artwork / pick from palette), grid density, "Show technical details everywhere" toggle, Now Playing layout
- **Diagnostics:** signal path history, dropout counter, network stats, device capability probe (supported sample rates, encodings, mixer attributes), **export debug report** (explicitly *scrubbed of file names and tags*)
- **About:** version, open-source licenses, privacy statement ("There are no BitDrop servers. Your music and account never leave your devices and Google.")

### 8.17 Global and edge states catalogue (design each one)
| Situation | Treatment |
|---|---|
| Offline | Banner; unplayable items greyed; filters default to "Available offline" |
| Buffering / underrun | Play button becomes a spinner, "Buffering… 3 s"; short fade, never a hard cut |
| Google re-consent needed (every ~7 days in testing mode) | Non-blocking banner with a "Reconnect" action; cached playback keeps working |
| Rate-limited by Drive | "Google Drive is busy. Scan paused, resuming in 40 s." |
| File removed from Drive | Tombstoned row, skipped in the queue with a toast |
| USB DAC disconnected | Playback pauses; toast "DUNU Titan X disconnected. Paused."; device card updates |
| Sample-rate change between tracks | Short-gap marker in the queue; nothing alarming |
| Unsupported format in the queue | Skipped with a toast explaining why |
| Storage full | Pinning paused, link to Storage settings |
| No music found | Friendly empty state, "Choose different folders" |
| Scan interrupted / resumed | "Scan resumed · 6,120 of 10,412" |

---

## 9. Microcopy and tone

- Plain, confident, short. Technical where the user asked for detail (Signal Path, EQ), plain everywhere else.
- **Never shame Tier C.** "Resampled by system · 48 kHz", not "Low quality."
- Explain *why* in one sentence, with "Learn more" for detail.
- Numbers: `24/96`, `44.1 kHz`, `−6.2 dB` (true minus sign), `8.4 Mbps`, `1.12 GB`.
- Put every user-facing string that matters (tier labels, errors, banners) in `COPY.md` so engineering can reuse them verbatim.

---

## 10. Motion

- Purposeful and quick: 150–300 ms, standard Material easing; shared-element transition from mini player to Now Playing and from album art to album detail.
- Seek bar cached ranges grow smoothly; no busy animation.
- Respect **reduce motion** (cross-fades instead of movement).
- No looping decorative animations on battery-sensitive screens.

---

## 11. Accessibility (required)

- WCAG **AA** contrast in **both** modes, including text on artwork-tinted backgrounds
- Touch targets ≥ 48 × 48 dp
- Text scaling up to 200% without broken layouts (show at least Now Playing and Album detail at 200%)
- Screen reader labels for every icon-only control; tier and availability states announced as text
- Color is never the only signal (tiers, cloud states, clipping)
- EQ graph has a non-gesture alternative (the band list with numeric fields)

---

## 12. Sample data (use throughout; no real cover art)

Use **generated artwork** (gradients or abstract shapes seeded from the album name). Don't use real covers or trademarked logos. "Google Drive" may appear as text and in the official Sign in with Google button only.

| Artist — Album (Year) | Format | Notes for states |
|---|---|---|
| Steely Dan — Aja (1977) | FLAC 24/96 | Main Now Playing example; "Deacon Blues" next (gapless) |
| Miles Davis — Kind of Blue (1959) | FLAC 24/192 | Pinned offline |
| Daft Punk — Random Access Memories (2013) | FLAC 24/88.2 | Partially cached |
| Pink Floyd — The Dark Side of the Moon (1973) | FLAC 24/192 | Downloading (pin in progress, 42%) |
| Fleetwood Mac — Rumours (1977) | ALAC 24/96 | Cached |
| Norah Jones — Come Away With Me (2002) | FLAC 16/44.1 | CD-quality example |
| Radiohead — OK Computer (1997) | FLAC 16/44.1 | Mixed queue → "short gap 44.1 → 96 kHz" |
| Hans Zimmer — Interstellar OST (2014) | WAV 24/48 | Large files |
| Various — Late Night Lossy (2019) | MP3 320k | Lossy styling |
| Various — Audiophile Test Disc | APE | Unsupported format |
| Grateful Dead — Live/Dead (1969) | FLAC 16/44.1, single file + CUE | CUE album shown as tracks |
| One track | — | "Missing from Drive" tombstone |

**Devices for state demos:** *DUNU Titan X (USB-C) on Galaxy S10+ (Android 12)* → Tier C, 48 kHz. *USB DAC on Android 14+ phone* → Tier A. *Same, with EQ on* → Native rate · DSP active. *iPhone* → Native rate.
**Library size for counters:** 10,412 tracks · 812 albums · 1.86 TB.

---

## 13. Deliverables

```
design/
├── README.md                 # Index: how to open the prototype, screen list with status, decisions log
├── DESIGN_SYSTEM.md          # Principles, color (light+dark), type scale, spacing, radii, elevation/surfaces,
│                             #   iconography, motion, and component specs (see list below)
├── tokens/
│   └── bitdrop.tokens.json   # Design tokens, light + dark (W3C Design Tokens format). Name them so they map
│                             #   cleanly to Flutter ColorScheme / TextTheme / ThemeExtension
├── COPY.md                   # Microcopy glossary: tier labels, states, errors, onboarding text
├── UI_STATE_CONTRACT.md      # Per screen: data it reads from the Rust core + commands it sends
│                             #   (play, pause, seek, enqueue, set_eq_band, pin_album, …). Reuse field names
│                             #   from spike-drive/src/models.rs where they apply
└── prototype/
    ├── index.html            # Opens with a double-click. No build step, no CDN dependency
    ├── styles/               # CSS generated from or mirroring the tokens
    ├── scripts/              # Vanilla JS only
    └── assets/               # Self-hosted fonts (OFL), icons, generated artwork
```

**Component specs required in DESIGN_SYSTEM.md:** buttons, icon buttons, chips, **format chip**, **tier pill**, **availability badges**, list rows (track/album/artist/folder), album card, sliders, **cache-aware seek bar**, **EQ graph and node**, band row, bottom nav, **mini player**, sheets, dialogs, banners, snackbars, progress (linear/ring), text fields/steppers, segmented controls, empty-state pattern, skeleton/shimmer pattern.

**Prototype requirements:**
- A phone viewport at 412 × 869 dp, centered on desktop
- A floating **control panel** (outside the phone frame) with **Light / Dark** toggle, **Tier A / B / C / DSP / iOS**, **Online / Offline**, **Scanning on/off**, **Text size 100% / 200%**
- Every screen in §8 reachable by clicking through the app itself
- Realistic sample data from §12

---

## 14. Process and checkpoints

1. **Read** the files in §0.
2. **Checkpoint 1: stop and present** (no prototype yet):
   - `DESIGN_SYSTEM.md` draft (color, type, core components) in Light and Dark
   - Final IA and navigation decision with rationale
   - **Two distinct Now Playing directions** as static prototype pages
   - Wait for the owner to choose before continuing.
3. **Build** in this priority order: Now Playing → Signal Path → Library + Album detail → EQ + AutoEQ → Queue → Onboarding + Safety gate → Home → Search → Settings (all subpages) → Global states → Widgets/tablet (stretch).
4. **Write** `UI_STATE_CONTRACT.md` and `COPY.md` as you go, not at the end.
5. **Self-review** against §15 in both modes, then present a summary of what's done, what's open, and the decisions you made.

---

## 15. Definition of done

- [ ] Every screen in §8 exists in the prototype in **Light and Dark**
- [ ] Every screen has loading, empty, error and offline states where applicable
- [ ] Tier labels exactly match §4 and never claim Bit-perfect with DSP active
- [ ] Cloud availability states (§7.4) appear consistently on rows, cards and the queue
- [ ] Seek bar shows non-contiguous cached ranges
- [ ] EQ graph plus band list, preamp with clipping indicator, bypass and A/B, AutoEQ flow
- [ ] Hearing safety gate flow complete
- [ ] AA contrast verified in both modes (list checked pairs in `DESIGN_SYSTEM.md`)
- [ ] 200% text check on Now Playing and Album detail
- [ ] Tokens JSON covers every color, type and spacing value used in the prototype (no hard-coded values)
- [ ] `UI_STATE_CONTRACT.md` covers every screen
- [ ] Nothing outside `design/` modified

---

## 16. Out of scope

- Production Flutter code (that's the next phase; your tokens and specs feed it directly)
- Paywalls, subscriptions, ads (business model undecided)
- Any server-backed feature (see §4.7)
- Real album artwork or third-party logos (except the official Google sign-in button)
- Tier D (exclusive USB driver) UI. Leave space for it in Audio output settings as "Coming later" at most

# BitDrop — UI/UX Design & Prototype Prompt

> **How to use:** Copy everything below the line into the UI agent as its task. It's self-contained.

---

## 0. Your role and the deliverable

You are a **senior product designer and Flutter UI engineer**. Design and build the complete UI/UX for **BitDrop**, an audiophile music player that streams lossless music straight from the user's own cloud storage. It aims to match **Poweramp**'s depth and beat it on clarity, honesty and cloud-native design.

**Deliverable:** a runnable **Flutter prototype** with **Light and Dark themes**, every screen in this brief, realistic **mock data**, and a **scenario switcher** that puts the UI into each important state. There's **no real audio, networking or authentication**. The real engine (written in Rust) gets connected later through the data contract in Section 9, so the UI must be built strictly against that contract.

Also write a `DESIGN.md` that documents the design system and your key decisions.

---

## 1. Product context (read carefully; it drives the design)

**The user problem.** Audiophiles with IEMs (in-ear monitors) and USB DACs (digital-to-analog converters) keep huge lossless libraries (FLAC/ALAC/WAV, 30–80 MB per track, up to 24-bit/192 kHz). Phone storage fills up. Their music already sits in 2 TB+ cloud drives, but:
- Cloud music apps send audio through the phone's system mixer, which **resamples** it (usually to 48 kHz). That's unacceptable to this audience.
- Audiophile players (Poweramp, UAPP, Neutron) only play **local files**.
- Server setups (Navidrome + Symfonium) mean running a **24/7 server**.

**BitDrop** connects straight to Google Drive (S3, WebDAV and OpenSubsonic come later), indexes the library on the device, streams with a smart disk cache, and sends audio to the DAC through the best path the phone allows. It **always tells the truth** about that path.

**Key technical facts the UI must reflect:**

1. **Output tiers.** The phone and DAC decide what's possible, and the app detects it:
   - **Bit-perfect**: samples untouched, native sample rate, volume handled by the DAC hardware (Android 14+ with a supporting device and DAC).
   - **Native rate**: no resampling, but the system may apply software volume or mix in other sounds.
   - **Resampled**: the system converts to its own fixed rate (typically 48 kHz). This applies to Android 12–13, unsupported DACs and the phone speaker.
   - Turning on **DSP** (EQ, ReplayGain, software volume, safety attenuation) means the output is no longer bit-perfect, and the UI must say so.
2. **Cloud + cache.** Each track is in one of these states: cloud-only (streams), partially cached, fully cached, pinned for offline, downloading, unavailable (deleted, no access, or offline with no cache), or unsupported format.
3. **No server, ever.** Files go only from the user's cloud to their phone. This is a privacy promise and should be stated plainly during onboarding and in Settings.
4. **Gapless playback** works when consecutive tracks share a format. A switch in sample rate can cause a tiny gap, and the UI explains this honestly.
5. **Hearing safety.** In bit-perfect mode there's no software volume, so a sensitive IEM on a DAC with no hardware volume could play at full scale. A one-time **safety check** flow is required.
6. **Library scanning** works in two passes: an instant library built from folder and file names, then tags filled in in the background (Wi-Fi only by default). The library is usable within seconds, even while scanning continues.
7. **Platforms:** Android 12+ and iOS. Phones first, with tablets and foldables supported. On iOS the best possible tier is "Native rate".

**The primary user** is an enthusiast who knows terms like FLAC, 24/96, DAC, IEM, EQ, AutoEQ and ReplayGain, and expects detail. **Secondary user:** someone who just wants their Drive music to play well. Design for both through **progressive disclosure**: simple on the surface, deep on demand.

---

## 2. Benchmark: Poweramp, what to match and what to beat

**Match (table stakes):** a deep equalizer (graphic and parametric, preamp, tone), gapless playback, ReplayGain, folder browsing, rich Now Playing with visualizers, gestures, album-art-driven colors, customizable layouts, lock screen and notification controls, sleep timer, queue control.

**Beat:**

| Poweramp weakness | BitDrop answer |
|---|---|
| Settings maze with hundreds of buried options | **Searchable settings**, clear grouping, sensible defaults, an "Advanced" disclosure per group |
| Opaque output path; users can't tell what reaches the DAC | **Signal Path**: a live, tappable diagram from source to decoder to DSP to volume to output to device, with requested vs. actual format |
| No cloud library | **Cloud-native library** with clear availability states, a cache map on the seek bar, smart offline pinning |
| Cramped, fiddly EQ | **Full-screen EQ editor** with draggable bands, **AutoEQ search** for the user's IEM, A/B compare, a clipping meter |
| Dated library browsing | Modern, fast, typographically strong library with format and quality badges |
| Same settings for every device | **Per-device profiles**: plugging in "DUNU Titan X" auto-applies its EQ and volume preferences |

---

## 3. Design principles (in priority order)

1. **Honest by design.** Never show a quality claim the engine hasn't confirmed. Labels come from data and are never inferred in UI code.
2. **Music first, data on demand.** Album art and titles lead. Technical detail is one tap away and always reachable.
3. **Instrument-grade precision.** It should feel like well-made audio gear: precise alignment, tabular monospace numbers for technical readouts, restrained color, calm motion.
4. **Calm under failure.** Buffering, offline and errors are handled gracefully with clear next steps and no alarming red walls.
5. **Fast to use.** Two taps to any album, one gesture to control playback, no blocking modals except the safety check.
6. **Accessible.** WCAG AA contrast, 48 dp touch targets, screen-reader labels, text scaling to 200%, and **color is never the only signal**.

**Visual direction:** modern, premium, minimal, with a hint of studio equipment (meters, monospace readouts) used sparingly. Think of a high-end DAC's front panel crossed with a refined editorial music app. **Avoid:** neon "gamer" looks, skeuomorphic knobs everywhere, glassmorphism overload, gradient soup, fake "Hi-Res enhancer" stickers.

---

## 4. Design system

Implement all tokens in a theme layer: Material 3 `ThemeData` plus a custom `ThemeExtension` for BitDrop-specific tokens. **No hard-coded colors, sizes or text styles in widgets.** You may refine values, but keep the semantics and meet AA contrast. Document any change in `DESIGN.md`.

### 4.1 Color tokens

| Token | Dark | Light | Usage |
|---|---|---|---|
| `bg` | `#0E0F12` | `#F7F7F9` | App background |
| `surface1` | `#16181D` | `#FFFFFF` | Cards, sheets |
| `surface2` | `#1D2027` | `#F1F2F5` | Raised and grouped areas, mini player |
| `surface3` | `#252932` | `#E7E9EE` | Inputs, pressed states |
| `outline` | `#2F3440` | `#D6D9E0` | Dividers, borders |
| `textPrimary` | `#F2F4F7` | `#0F1115` | Primary text |
| `textSecondary` | `#A6ADBB` | `#4B5262` | Secondary text, metadata |
| `textTertiary` | `#6B7280` | `#8A90A0` | Disabled and decorative only (not body text) |
| `accent` | `#8B93FF` | `#4F46E5` | Brand accent, primary actions, progress |
| `onAccent` | `#0E0F12` | `#FFFFFF` | Text and icons on accent |
| `tierBitPerfect` | `#34D399` | `#047857` | Bit-perfect |
| `tierNativeRate` | `#38BDF8` | `#0369A1` | Native rate |
| `tierResampled` | `#FBBF24` | `#B45309` | Resampled by system |
| `dspActive` | `#F472B6` | `#BE185D` | DSP/EQ active indicators |
| `error` | `#F87171` | `#B91C1C` | Errors, clipping |
| `success` | `#34D399` | `#047857` | Completed, downloaded |
| `cacheFill` | accent @ 35% | accent @ 25% | Cached ranges on the seek bar |

Tier and DSP colors **always come with an icon and a text label**. **Adaptive color:** Now Playing may tint its background from the album art's dominant color (supplied in mock data). Clamp luminance so text contrast still passes. The user can turn this off.

### 4.2 Typography
- **UI font:** Inter (bundle it; no runtime downloads).
- **Technical font:** JetBrains Mono (or IBM Plex Mono) with **tabular figures**, for sample rates, bit depths, bitrates, times, dB, Hz and Q.

| Style | Size/Line | Weight |
|---|---|---|
| display | 32/40 | 600 |
| headline | 24/32 | 600 |
| title | 20/28 | 600 |
| titleSmall | 16/24 | 600 |
| body | 15/22 | 400 |
| bodySmall | 13/18 | 400 |
| label | 12/16 | 500 |
| monoLabel | 11/14 | 500, +0.5 tracking, uppercase for badges |
| monoReadout | 13/18 | 500 |

### 4.3 Spacing, shape, elevation
- **Spacing (4-pt grid):** 4, 8, 12, 16, 20, 24, 32, 40, 56. Screen side margins: 16 (phone), 24 (tablet).
- **Radii:** badge 6, chip/input 10, card 14, album art in grids 8, Now Playing art 16, bottom sheet 24 (top corners).
- **Elevation:** dark mode uses surface steps, not shadows. Light mode uses soft shadows (y=1–8, blur 2–24, black at 6–10%).

### 4.4 Motion
- Durations: micro 120 ms, standard 220 ms, emphasized 320 ms. Curves: Material 3 emphasized decelerate for entering, accelerate for exiting.
- **Signature motions:**
  - Mini player expands into Now Playing with a shared-element transition on the album art.
  - Art crossfades on track change.
  - The Signal Path nodes animate when the tier changes.
  - The playhead pulses while buffering.
  - EQ curves morph smoothly.
- Honor the system **reduce-motion** setting with crossfades only.

### 4.5 Iconography and haptics
- Material Symbols Rounded, weight 400, with a consistent optical size.
- Haptics:
  - Light tick when an EQ band snaps to 0 dB and when scrubbing crosses a track or chapter boundary.
  - Medium tick on play and pause.
  - Nothing on scroll.

---

## 5. Information architecture

**Bottom navigation (phone), 4 tabs:** **Home · Library · Search · Sources**. Settings opens from an avatar or gear button in each tab's top bar. **The mini player** stays docked above the nav bar whenever something is loaded.

**Full-screen and modal destinations:** Now Playing, Queue, Signal Path (bottom sheet), Equalizer/DSP, Output & Devices, Safety Check (modal flow), Album, Artist, Folder, Playlist, Offline & Storage, Settings (searchable), Diagnostics, Onboarding.

**Tablet, foldable and landscape:** a navigation rail replaces the bottom bar. Library uses list and detail side by side. Now Playing puts the art on the left and controls, signal path and queue on the right.

---

## 6. Screen specifications

For each screen, design **both themes** and the **empty, loading, error and populated** states where they apply.

### 6.1 Onboarding (first run)
1. **Welcome:** logo, the tagline "Your lossless library. Your cloud. No compromises." and a "Get started" button.
2. **Privacy promise:** "BitDrop has no servers. Your music and account stay between your phone and your cloud." Three short points: on-device indexing, no uploads, no tracking of file names.
3. **Connect a source:** Google Drive card (active). S3-compatible, WebDAV and OpenSubsonic/Navidrome cards are visibly marked "Coming soon".
4. **Choose music folders:** a Drive folder tree with checkboxes and estimated track counts, plus a "Scan entire Drive" option with a warning that it's slower.
5. **Scanning begins.** Don't block: "Your library is ready to browse. Details will fill in over Wi-Fi." Go to Home with the scan banner showing.
6. **Optional:** notification permission explained in context (Android 13+), and a "Have a USB DAC? Plug it in any time." hint.

### 6.2 Home
- Top bar: greeting or "BitDrop", plus settings.
- **Current output card** (compact): device name, tier chip, format capability ("DUNU Titan X · USB · Resampled to 48 kHz"). Tapping opens Output & Devices.
- **Continue listening:** last album or playlist with progress.
- **Recently added** (horizontal album row), **Most played**, **Ready offline** (pinned and cached albums), **Hi-Res picks** (24-bit and above).
- **Library status banner** while scanning or with problems: "Reading tags · 8,214 of 12,480 · Wi-Fi only", or "Google Drive needs you to reconnect", or "Scanning paused · Drive is limiting requests · retrying in 32 s".
- Empty state with no source: an illustration and a "Connect Google Drive" button.

### 6.3 Library
- Segmented tabs: **Albums · Artists · Tracks · Folders · Genres · Playlists**.
- Toolbar: sort (Title, Artist, Year, Recently added, Sample rate, Bit depth), view toggle (grid/list), filter.
- **Filter sheet:** Format (FLAC, ALAC, WAV, AIFF, MP3/AAC), Quality (Hi-Res ≥24-bit or >48 kHz, CD 16/44.1, Lossy), Availability (Offline, Cached, Cloud only), Show unsupported files.
- **Album grid card:** art (radius 8) with an **availability glyph** in the corner, title, artist, and a **format badge** (`FLAC 24/96`).
- **Track row:** 48 dp art (or track number inside an album), title, "artist · album", then on the right a format badge, availability glyph and duration (mono). Swipe right for "Play next", swipe left for "Add to queue". Long-press for multi-select.
- **Unsupported files** (APE, WavPack, DSF/DFF, Opus) appear greyed out with "APE — not supported yet", are never hidden, and can be filtered out.
- **Skeleton state:** while tags are still loading, rows show names taken from file paths with a subtle shimmer on fields still pending.
- **Folders:** breadcrumb navigation, folder rows with item count and total size, "Play folder" and "Pin folder" actions.

### 6.4 Album detail
- Large art header with an adaptive-color backdrop, title, artist (link), year, genre.
- **Tech summary row (mono):** `FLAC · 24-bit · 96 kHz · 12 tracks · 1.42 GB · 58:31`.
- Actions: **Play**, **Shuffle**, **Download for offline** (shows a progress ring while downloading; pinned state looks different), overflow menu.
- Track list grouped by disc. Each row shows per-track badges only when they differ from the album.
- A **gapless note** appears only when formats vary within the album: "Tracks 4–5 change sample rate; a brief gap may occur."
- Footer: total size, source path ("Drive › Music › Hi-Res › …"), last modified.

### 6.5 Artist detail
Header with an art collage, album grid sorted by year, popular tracks, "Shuffle artist".

### 6.6 Search
- Instant results as you type, grouped as Top result / Tracks / Albums / Artists / Folders.
- Filter chips (format, quality, offline only), recent searches, and an empty state with tips such as `Try "24/192" or "ALAC"`.
- Matches are highlighted.

### 6.7 Mini player
A 64 dp bar showing art, title and artist, a small **tier dot** (color plus shape), and a play/pause button. A thin 2 dp progress line on top includes the buffered segment. Swipe left/right to skip, tap or swipe up to expand, long-press for the output device.

### 6.8 Now Playing (hero screen)
Portrait phone layout, top to bottom:
1. Top bar: collapse chevron, "Playing from **Album name**" (tappable), overflow menu (sleep timer, go to album or artist, track info, share-safe info, pin).
2. **Album art**, square, radius 16, 24 dp side margins. Swipe left/right to skip. Double-tap does nothing (avoids accidental actions).
3. Title (title style, marquee if long), "artist · album" (secondary), favorite button.
4. **Signal chip**, tappable to open the Signal Path sheet: tier icon + label + format + device, e.g. `◆ Bit-perfect · 24/96 → FiiO KA17` or `▲ Resampled · 96 → 48 kHz · Titan X`. Add a small pink **DSP** badge if any processing is active.
5. **Cache-aware seek bar (signature component):**
   - The track line shows **played** (accent), **cached ranges** (cacheFill, can be non-contiguous after seeks) and **not yet fetched** (outline).
   - While scrubbing, a time bubble says whether that point is "Cached" or "Will stream".
   - While buffering, the playhead pulses and a caption reads "Buffering · 3.1 s of 5 s".
   - Times are mono. Tapping the end time toggles remaining time.
6. Transport: shuffle, previous, **play/pause** (72 dp filled accent circle), next, repeat (off/all/one).
7. Bottom action row: **Queue**, **EQ** (pink dot when active), **Output** (device icon), **Lyrics** (shown only if embedded lyrics exist), **More**.
8. Background: adaptive color gradient from the art (toggle in Appearance).

**Three Now Playing styles** (Settings › Appearance), the Poweramp-style customization:
- **Classic:** as above.
- **Minimal:** small art, large typography, focused on text and tech info.
- **Studio:** stereo **VU or peak meters** with a clip indicator and a **spectrum analyzer**, plus a full tech readout panel (source format, output format, bitrate, buffer seconds). Visualizer data is mocked and animated.

**Volume:** when the DAC controls volume (bit-perfect), show a hint: "Volume is controlled by your DAC. Use the volume keys." Otherwise an optional in-app fine volume slider in dB.

Landscape: art on the left, everything else on the right.

### 6.9 Signal Path (bottom sheet, the key differentiator)
- **Vertical node diagram**, each node with status color, icon, label and detail (mono):
  1. **Source**: Google Drive, with cache status ("64% cached · streaming 3.4 Mbps")
  2. **Decoder**: `FLAC 24-bit / 96 kHz`
  3. **DSP**: `Off — bypassed` or `EQ (Titan X AutoEQ) · Preamp −6.2 dB`
  4. **Volume**: `DAC hardware` / `Software, 24-bit dithered` / `System`
  5. **Output**: `Bit-perfect USB` / `Native rate` / `Android mixer → 48 kHz`
  6. **Device**: `DUNU Titan X · USB-C`, with the device's supported formats
- A **verdict banner** at the top in the tier color, with icon and label.
- **Plain-language explanation**, e.g. "Android 12 mixes all audio at 48 kHz before it reaches your DAC. Bit-perfect output needs Android 14 or later and a supported DAC."
- An expandable **"Requested vs. actual"** table for experts.
- Contextual actions: "Turn off EQ for bit-perfect", "Run safety check", "Open diagnostics".

### 6.10 Queue
- "Now playing" pinned at the top, then **Up next** (user-added) and **Autoplay from album/playlist** sections.
- Drag handles to reorder, swipe to remove, an undo snackbar.
- Each row shows availability. The next track shows **"Preloaded for gapless"** when ready, or **"Will stream"**.
- Actions: Save as playlist, Clear, Shuffle remaining.

### 6.11 Equalizer & DSP (full screen)
- Header: master **Bypass** switch, and when active a pink banner: "EQ is active — output is no longer bit-perfect."
- Mode tabs: **Simple** (bass/treble tone plus a few curated presets), **Graphic** (10-band ISO: 31, 62, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz, ±12 dB), **Parametric** (up to 10 bands).
- **Parametric editor:**
  - Response graph with a log frequency axis (20 Hz–20 kHz) and a ±15 dB axis. Combined curve in accent, individual band curves faint.
  - **Draggable nodes:** drag to set frequency and gain, pinch or use the side handle for Q. A haptic tick at 0 dB.
  - Band list below: type (Peak, Low shelf, High shelf, Low-pass, High-pass), frequency (Hz), gain (dB), Q, all as precise mono inputs. Add and remove bands.
- **Preamp** slider with an **auto-preamp** suggestion and a **clipping meter** (turns red with a count of clipped samples).
- **A/B compare:** hold to hear the bypassed sound.
- **Presets:** **AutoEQ** browser (search by IEM/headphone model, e.g. "DUNU Titan X"; results list the measurement source and target), user presets, and **import** of AutoEQ `ParametricEQ.txt` by paste or file.
- **Assign to device:** "Auto-apply when DUNU Titan X is connected."
- Additional DSP section: **ReplayGain** (Off/Track/Album, preamp), **Balance**, **Mono**. Each one notes when it affects bit-perfect output.

### 6.12 Output & Devices
- **Current device card:** name, connection type (USB / Bluetooth / Phone speaker), **tier chip**, supported sample rates as chips (44.1, 48, 88.2, 96, 176.4, 192 kHz), bit depths (16, 24, 32), hardware volume (Yes / No / Unknown), and a "Run safety check" button.
- **Per-device profile:** EQ preset, ReplayGain, safety attenuation, preferred volume.
- **Known devices** list, with each device's saved profile.
- **Events:**
  - DAC connected: a banner reading "DUNU Titan X connected · Apply 'Titan X AutoEQ'?"
  - DAC disconnected: playback pauses and a banner says "USB DAC disconnected — playback paused."

### 6.13 Hearing Safety Check (modal flow, the only blocking modal)
Triggered before the first bit-perfect playback on a new phone and DAC pair.
1. "Remove your earphones." Explains why: no software volume in bit-perfect mode, and sensitive IEMs can be dangerously loud.
2. "Press volume down a few times." Plays a quiet test tone, with a live indicator of whether the volume keys change the DAC level.
3. Result: "Hardware volume works" (continue), or "Your DAC has no volume control" with **safety attenuation recommended** (−12 dB digital; note it disables bit-perfect). A confirm checkbox comes before continuing.

### 6.14 Sources
- **Source account card** per account: provider logo, account email, status ("Synced 5 min ago · 12,480 tracks · 2 folders"), current activity (listing or reading tags with a progress bar), and actions: Rescan, Edit folders, Reconnect, Remove.
- **Add source** sheet with Google Drive plus "Coming soon" providers.
- States: syncing, up to date, needs reconnection (warning style, one-tap Reconnect), rate-limited (paused with countdown), offline.
- An advanced line: "Changes since last sync: +24 new, 3 changed, 1 removed."

### 6.15 Offline & Storage
- A **storage bar** split into Pinned (offline) / Cache / Free on device.
- **Cache limit** slider (1–64 GB) and a "Clear cache" button (pinned albums stay).
- **Pinned** list (albums, playlists, folders) with sizes and unpin. **Download queue** with progress, pause and resume.
- Toggles: "Download only on Wi-Fi", "Pin over mobile data: Ask / Allow / Never".

### 6.16 Settings (searchable)
A **search field at the top** filters every setting by name and description, jumping to and highlighting the result. Groups (each with an "Advanced" disclosure):
- **Audio output:** prefer bit-perfect when available, safety attenuation, per-device profiles, run safety check.
- **Playback:** gapless (on), crossfade (off; disabled with an explanation when bit-perfect is on), ReplayGain, resume on headset connect, sleep timer default.
- **Streaming & data:** on mobile data (Stream / Cached only / Ask), prefetch next tracks (Wi-Fi only / Always / Never), start-up buffering (Fast / Balanced / Safe).
- **Offline & storage:** links to 6.15.
- **Library:** sources and folders, show unsupported files, group compilations, ignore leading "The", artist separator characters, rescan.
- **Equalizer:** default preset, per-device auto-apply.
- **Appearance:** Theme (**System / Light / Dark**), Now Playing style (Classic / Minimal / Studio), adaptive color from album art, album grid density, format badges (Always / Hi-Res only / Never), reduce motion.
- **Notifications & lock screen.**
- **Diagnostics:** open diagnostics, export diagnostic report (states clearly that file names are removed).
- **Privacy:** a plain statement of the no-server model; "Sign out and delete local data".
- **About:** version, open-source licenses.

### 6.17 Diagnostics (power users)
Live cards with mono readouts and small sparkline charts:
- **Output:** requested vs. actual format, tier, device.
- **Buffer:** seconds of decodable audio ahead, PCM buffer fill %, **underrun count**.
- **Network:** current throughput, active byte-range requests, requests per minute vs. budget, last error.
- **Cache:** hit rate, size, current file's cached percentage.
- **Decoder:** format, decode load %.

### 6.18 Playlists
List of playlists (smart "Recently added", "Most played", "Hi-Res" plus user-created), playlist detail like the album screen, create and rename, add from track menus.

### 6.19 System surfaces (spec only; the OS renders them)
Media notification and lock screen artwork. Compact actions: previous, play/pause, next, favorite. Metadata string: "Artist — Album".

---

## 7. Component library

Build these as reusable widgets and show **all of them, in all states, in both themes**, on a **Component Gallery** screen reachable from Settings › Developer:

`FormatBadge` (Hi-Res filled / CD outline / Lossy muted / Unsupported struck-through) · `TierChip` (bit-perfect ◆ / native ● / resampled ▲ / unknown ?; each with color + shape + label) · `DspBadge` · `AvailabilityGlyph` (cloud, partial ring with %, cached, pinned, downloading animated, unavailable, unsupported) · `TrackRow` · `AlbumCard` · `ArtistTile` · `FolderRow` · `CacheSeekBar` · `BufferingIndicator` · `MiniPlayer` · `TransportControls` · `SignalPathDiagram` + `SignalNode` · `EqGraph` + `EqBandNode` · `PreampMeter` · `VuMeter` · `SpectrumView` · `DeviceCard` · `SourceCard` · `StatusBanner` (info / warning / error / success, with action) · `StorageBar` · `SettingsTile` (switch, choice, slider, navigation) · `SectionHeader` · `EmptyState` · `SkeletonLoader` · `SegmentedTabs` · `FilterChipRow` · `BottomSheetScaffold` · `ConfirmDialog`.

---

## 8. States and edge cases (all must be designed and reachable)

First run with no source · scan in progress (instant library with shimmer) · scan paused by rate limit (countdown) · source needs reconnection · offline with partial cache (unplayable tracks dimmed, cached ones playable) · buffering (escalating: "Buffering…" then "Slow connection — building a bigger buffer") · track unavailable (deleted or access revoked; skipped automatically with a snackbar) · unsupported format in queue (skipped with an explanation) · DAC connected · DAC disconnected (paused) · bit-perfect active · native rate · resampled · DSP active (labels change everywhere) · no hardware volume (safety attenuation on) · phone speaker / Bluetooth output (resampled; Bluetooth note: "Bluetooth uses its own codec — lossless bit-perfect isn't possible") · storage nearly full · empty search · empty playlist · long titles (marquee or ellipsis rules) · very large libraries (fast scrolling with an alphabet scrubber).

---

## 9. Data contract: build the UI only against this

The UI is a **display-only client**. It renders state from streams and sends commands. **It never computes tiers, labels or playback logic itself.** Implement this interface in Dart, plus a **mock implementation**. The real Rust engine will implement the same contract later. Names may be refined, but keep the shape.

```dart
abstract class BitDropCore {
  // Streams (the mock emits realistic, time-varying data)
  Stream<PlaybackState> get playback;      // sealed: Idle, Loading, Buffering(buffered, target, attempt), Playing, Paused, Error(kind, message)
  Stream<PositionInfo> get position;       // positionMs, durationMs, cachedRanges: List<Range>, bufferAheadMs  (~30 Hz)
  Stream<NowPlaying?> get nowPlaying;      // track, album, context
  Stream<SignalPath> get signalPath;       // see below
  Stream<QueueState> get queue;            // items with availability + preloadedForGapless
  Stream<OutputDevice?> get outputDevice;  // name, type, supportedRates, bitDepths, hardwareVolume (yes/no/unknown)
  Stream<List<SourceAccount>> get sources; // status, counts, activity, lastSync
  Stream<SyncStatus> get syncStatus;       // phase (listing/tags/idle/paused), progress, retryIn
  Stream<List<AppBanner>> get banners;     // global banners (reconnect, DAC events, rate limit…)
  Stream<EqState> get eq;                  // mode, bands, preamp, bypass, clippedSamples, assignedDevice
  Stream<StorageState> get storage;
  Stream<DiagnosticsSnapshot> get diagnostics;

  // Queries
  Future<Paged<Album>> albums(AlbumQuery q);
  Future<Paged<Track>> tracks(TrackQuery q);
  Future<Paged<Artist>> artists(ArtistQuery q);
  Future<FolderListing> folder(String? folderId);
  Future<SearchResults> search(String text, SearchFilters f);
  Future<List<AutoEqProfile>> searchAutoEq(String model);

  // Commands (fire-and-forget; results come back through the streams)
  Future<void> send(PlayerCommand cmd);    // sealed: PlayContext, Pause, Resume, Seek, Next, Previous, SetShuffle, SetRepeat,
                                           // Enqueue, PlayNext, Reorder, Remove, SetEq, SetBypass, SetPreamp, Pin, Unpin,
                                           // Rescan, ReconnectSource, RunSafetyCheck, SetSetting…
}

class SignalPath {
  final OutputTier tier;            // bitPerfect | nativeRate | resampled | unknown
  final AudioFormat source;         // codec, bitDepth, sampleRate, bitrateKbps
  final AudioFormat requested;
  final AudioFormat actual;         // what was really negotiated
  final bool dspActive;
  final List<String> dspChain;      // e.g. ["EQ: Titan X AutoEQ", "Preamp −6.2 dB"]
  final VolumeMode volume;          // dacHardware | softwareDithered | system
  final OutputDevice? device;
  final String explanation;         // plain-language, supplied by the core
}

enum Availability { cloudOnly, partiallyCached, cached, pinned, downloading, unavailable, unsupported }
```

**Rules:**
- Widgets subscribe to the **narrowest** stream they need. Position ticks must only rebuild the seek bar and time labels, never whole screens.
- All user-visible quality labels come from `SignalPath` and `Track`/`Album` fields.
- Keep local UI state ephemeral only (scrub position while dragging, open sheets).

### 9.1 Scenario switcher (developer overlay)
A floating debug button (debug builds only) opens a sheet that switches the mock core between scenarios instantly:
1. **Bit-perfect:** Android 14, "FiiO KA17" USB DAC, FLAC 24/96, DAC hardware volume.
2. **Native rate:** Android 14, generic DAC, no bit-perfect mixer.
3. **Resampled:** Galaxy S10+ (Android 12) + "DUNU Titan X" USB-C → 48 kHz.
4. **DSP active:** scenario 1 plus AutoEQ enabled (labels must change).
5. **Phone speaker** and **Bluetooth headphones**.
6. **Weak network:** repeated buffering, escalating targets.
7. **Offline:** partial cache.
8. **DAC unplugged** mid-playback.
9. **Source needs reconnection.**
10. **First run:** no sources.
11. **Scanning:** library partially enriched.
12. **Rate limited:** scan paused with countdown.
13. **Unsupported track** reached in queue.
14. **No hardware volume:** safety check result plus attenuation on.

Also include theme toggling (System/Light/Dark) and text-scale presets (100/130/200%) in this sheet.

### 9.2 Mock catalog
Use **fictional** artists and albums and **generated artwork** (gradient and geometric placeholders with a precomputed `dominantColor`). Include the variety below, about 10 tracks per album, realistic durations and file sizes, plus a few long titles to test truncation:

| Album | Artist | Format |
|---|---|---|
| Northern Lights Sessions | Aurora Fields | FLAC 24/96 |
| Quiet Machines | The Lowlands | FLAC 16/44.1 |
| Glass Harbor | Mira Okafor | FLAC 24/192 |
| Midnight Transit | Kenji Sato Trio | ALAC 24/48 |
| Field Recordings, Vol. 2 | Hollow Pines | WAV 24/96 |
| Low Orbit | Station Seven | FLAC 24/88.2 |
| Paper Lanterns | Lumen Choir | FLAC 16/44.1, single file + CUE |
| Concrete Bloom | Vesna | MP3 320 (lossy) |
| Archive Tapes | Delta Echo | APE (unsupported) |
| Sunday Pressure | The Copper Line | DSF / DSD64 (unsupported) |
| Mixed Signals (compilation) | Various Artists | Mixed 16/44.1 and 24/96 (tests the gapless note) |

Include folder structures that mirror the albums ("Music › Hi-Res › Mira Okafor › Glass Harbor"), 3 playlists, 2 AutoEQ profiles (including "DUNU Titan X"), and 3 known devices.

---

## 10. Copy and tone

- Short, confident, precise. Plain language first, technical detail second.
- Use these exact quality labels: **"Bit-perfect"**, **"Native rate"**, **"Resampled"** (with detail such as "96 → 48 kHz"), **"DSP active"**.
- **Never** use: "Hi-Res enhanced", "upscaled quality", "studio-grade AI", "lossless" for lossy files, or any claim the data doesn't support.
- Errors explain **what happened + what BitDrop is doing + what you can do**, e.g. "Google Drive is limiting requests. Scanning will resume in 32 s. Playback isn't affected."
- Put all strings in one localization file (ARB) so they're easy to translate later.

---

## 11. Platform and responsive rules

- **Android:** Material 3 conventions, predictive back, edge-to-edge with correct insets.
- **iOS:** the same visual design, with iOS swipe-back, sheets with grabbers, safe areas, and Cupertino-appropriate switches and dialogs where they differ. The Signal Path tops out at "Native rate".
- **Sizes:** design at 360×800 (small Android), 390×844 (iPhone/S10+-class), 430×932 (large), and tablet/foldable at 840 dp+ width with a nav rail and two panes.
- Support portrait and landscape for Now Playing. Lock other screens to portrait on phones if that helps quality.

---

## 12. Tech stack and structure

- Flutter (latest stable), Dart 3, null-safe, `flutter analyze` clean.
- State: **Riverpod**. Routing: **go_router**. Bundled fonts (Inter, JetBrains Mono). Avoid heavy dependencies and anything that does audio or networking.
- Charts and EQ graph: custom painters (no chart library needed).

```
app/
├── lib/
│   ├── main.dart
│   ├── app.dart                    # router, theme mode
│   ├── theme/                      # tokens, light/dark ThemeData, ThemeExtensions
│   ├── core_api/                   # BitDropCore interface + models (Section 9)
│   ├── core_mock/                  # mock implementation, catalog, scenarios
│   ├── features/
│   │   ├── onboarding/ home/ library/ album/ artist/ folders/ search/
│   │   ├── now_playing/ signal_path/ queue/ equalizer/ output/ safety/
│   │   ├── sources/ storage/ settings/ diagnostics/ playlists/
│   │   └── dev/                    # scenario switcher, component gallery
│   ├── widgets/                    # component library (Section 7)
│   └── l10n/                       # ARB strings
├── assets/fonts/
├── DESIGN.md
└── pubspec.yaml
```

---

## 13. Milestones (finish and self-review each before moving on)

1. **Design system:** tokens, both themes, typography, component gallery with every component and state.
2. **Shell and playback:** navigation, mini player, Now Playing (Classic), cache-aware seek bar, Signal Path sheet, mock core with scenarios 1–8.
3. **Library:** Home, Library (all tabs), Album, Artist, Folders, Search, Playlists, skeleton/scan states.
4. **Control:** Queue, Equalizer/DSP (all modes, AutoEQ, import), Output & Devices, Safety Check.
5. **Management:** Onboarding, Sources, Offline & Storage, searchable Settings, Diagnostics, Minimal and Studio Now Playing styles.
6. **Polish:** every edge state from Section 8, tablet/foldable/landscape layouts, iOS adaptations, accessibility pass (semantics labels, contrast check, 200% text), motion and reduce-motion, performance (no jank while position ticks).

---

## 14. Acceptance criteria

- [ ] `flutter run` works on an Android device and the iOS simulator. `flutter analyze` shows zero warnings.
- [ ] Every screen in Section 6 is reachable and populated with mock data, in **both Light and Dark**, and theme switching is instant.
- [ ] All 14 scenarios switch live and the UI updates correctly. Quality labels always match `SignalPath`.
- [ ] No hard-coded colors or text styles outside `theme/`. All strings are in ARB.
- [ ] Every tier/DSP/availability indicator has icon + text, not just color. AA contrast is verified for text tokens.
- [ ] The seek bar renders non-contiguous cached ranges, and scrubbing shows "Cached" / "Will stream".
- [ ] The parametric EQ graph is interactive (drag nodes, edit numerically) and shows the clipping meter and preamp.
- [ ] Position updates rebuild only the seek-bar subtree (verify with Flutter DevTools).
- [ ] `DESIGN.md` documents tokens, components, the screen inventory and decisions.

**Begin with Milestone 1.** Before writing code, give a short plan: the screen inventory, the component list, and any changes you propose to the tokens.

# BitDrop 🎵

**Audiophile Cloud Music Player** — Stream lossless audio (FLAC/ALAC/WAV) directly from your Google Drive with bit-perfect USB DAC output.

## The Problem

Audiophile IEM/DAC users store lossless music files (often 30-80MB each) on their phones, consuming massive storage. Cloud players exist but resample everything through Android's mixer, destroying bit-perfect delivery. Server-based solutions (Navidrome + Symfonium) require maintaining a 24/7 server.

## The Solution

BitDrop streams directly from Google Drive (and other cloud storage) to your USB DAC, negotiating the best possible output path:

| Tier | Condition | Output Quality |
|------|-----------|---------------|
| **A** | Android 14+, DAC supports BIT_PERFECT | Untouched samples at native rate |
| **B** | Android 14+, DEFAULT mixer only | Native rate, no resampling |
| **C** | Android 12-13, or unsupported DAC | System resampled (usually 48kHz) |

## Architecture

```
Flutter UI (Dart) — Dumb rendering client
    │ flutter_rust_bridge v2
Rust Core — Single source of truth
    ├── State Machine & DB (rusqlite + FTS5)
    ├── StorageProvider (Drive / S3 / WebDAV)
    ├── Fetch Scheduler & Sparse Disk Cache
    │       │ Blocking Read + Seek
    ├── Decoder Thread (symphonia)
    │       │ SPSC Ring (rtrb, 0.5-2s)
    └── Output Thread (RT-safe, no allocations)
    │ UniFFI / JNI
Android Shell (Kotlin) — OS bridge only
    ├── Media3 MediaLibraryService
    ├── AudioMixerAttributes (Tier negotiation)
    └── Google Identity / TokenProvider
```

## Key Constraints

1. **Zero Server** — All processing on-device to avoid Google's CASA security audit
2. **Disk, Not RAM** — Compressed bytes cached to sparse files; only 0.5-2s PCM in memory
3. **RT Discipline** — Audio output thread: no alloc, no locks, no I/O, no Dart/JVM calls
4. **Honest Labels** — Never claim bit-perfect unless hardware confirms it

## Project Structure

```
BitDrop/
├── spike-audio/     # Phase 0: Audio capability probe (Kotlin)
├── spike-drive/     # Phase 0: Google Drive range fetch prototype
├── app/             # Main application (Flutter + Rust, Phase 1+)
└── README.md
```

## Development Status

**Phase 0: Feasibility Spikes** (Current)

## Test Hardware

| Device | OS | Audio Tier |
|--------|-----|-----------|
| Samsung Galaxy S10+ | Android 12 (API 31) | Tier C |

| IEM/DAC | Type | Notes |
|---------|------|-------|
| DUNU Titan X (Type-C) | Built-in DAC | Undisclosed DAC chip; capabilities TBD via Spike 1 |

## Tech Stack

| Layer | Technology |
|-------|-----------|
| UI | Flutter / Dart |
| Core | Rust (symphonia, rtrb, reqwest, rusqlite) |
| Bridge (Dart↔Rust) | flutter_rust_bridge v2 |
| Bridge (Kotlin↔Rust) | UniFFI |
| Android Shell | Kotlin, Media3, AudioMixerAttributes |
| Output | AAudio (ndk crate) or AudioTrack (JNI) |

## License

TBD

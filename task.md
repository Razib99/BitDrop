# BitDrop Task Tracker

## UI Phase (Claude Agent)
- [x] Scaffold app UI architecture
- [x] Implement routing and core providers
- [x] Implement widgets and mock data

## Spike 3: Rust FFI Backend (In Progress)
- [x] Scaffold `flutter_rust_bridge` codegen in `app/`
- [x] Integrate `symphonia` crate (v0.5.3) for FLAC probing
- [x] Wire FFI metadata call into `main.dart`
- [x] Implement advanced FLAC track parsing and buffer processing

## Spike 4: NDK AudioTrack Bridge (In Progress)
- [x] Add `oboe` (AAudio wrapper) crate to Rust backend
- [x] Initialize AAudio stream context
- [x] Bridge `symphonia` PCM buffer outputs to `oboe` streams

## Legacy Phase 0 Tracker
- [x] Spike 1 (Audio Probe Kotlin scaffolding)
- [x] Spike 2 (Google Drive Range Fetcher Rust scaffolding)

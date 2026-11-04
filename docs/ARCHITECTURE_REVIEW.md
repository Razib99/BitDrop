# Architecture review follow-up

## Implemented

The streaming/cache and playback coordination paths were rewritten around explicit ownership. Downloads share the streaming writer, chunk failures are terminal until an explicit retry, cancellation interrupts pending I/O, OAuth refresh crosses the bridge, and preloads carry separate generations. Single-owner DSP endpoints replace unrestricted shared access. See `ARCHITECTURE.md` for invariants and verification commands.

Additional fixes cover queue removal ordering, stale credential completions, stop/replay subscriptions, flush-frame accounting, short-track gate release, idempotent engine initialization, failed scan pruning, and pin/open-file protection during cache clearing. Search results now invalidate when the library changes. Native integration setup reports library-load failures directly and CI builds the shared library first.

## Further refactoring candidates

- `LiveBitDropCore` still handles library queries, settings persistence, EQ commands, output policy, and presentation state. Extract those into focused components as each feature changes; the new playback transport boundary establishes the same pattern for queue tests. A broad mechanical rewrite would increase the regression surface without resolving an additional demonstrated defect.
- `cloud/db.rs` mixes schema creation, library queries, pin/cache records, and AutoEQ seed data. Split repositories around those responsibilities while preserving transaction boundaries and migrations.
- Folder identity is still based partly on display paths. Store stable root-folder identifiers before supporting distinct selected folders with identical names or moving folders between roots.
- `LiveBitDropCore.folder()` and `genres()` still return empty results. These are incomplete product features, not completed native library queries.
- The device probe selects among connected outputs, and the signal-path UI uses advertised capabilities. A connected device and a successful preference request do not establish the active hardware route or end-to-end bit integrity. Feed the actual stream device/format and mixer acceptance into this path before treating the highest tier as verified.
- The limiter measures sample peaks, not reconstructed inter-sample peaks. Add oversampled reference measurements before promising true-peak compliance.
- Existing golden gapless tests exercise synthetic PCM and renderer boundaries. Add real decoded files covering resampler delay, different sample rates, embedded artwork, and supported containers to verify the entire decode/transition path.

## Device acceptance work

Exercise real Google Drive token expiration, queue changes during slow opens, USB insertion/removal, Android background/service recreation, and output-rate/format changes on physical devices. Local tests cover transport and concurrency behavior but cannot certify those hardware and account flows.

## Follow-up regression fixes

A second review identified shared-reader seek cancellation, delayed EOF after stop, and indefinite token replacement reuse. Large shared seeks now preserve other readers' requests; explicit cancellation is reported once before a reader can join the current generation. Stopped playback ignores queued EOF events. Credential replacements have a five-second reuse window to coalesce concurrent failures rather than serving an expired replacement indefinitely. Dedicated regression tests cover all three cases.

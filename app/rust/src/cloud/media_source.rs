use anyhow::Result;
use futures_util::StreamExt;
use parking_lot::{Condvar, Mutex};
use reqwest::header::{HeaderMap, HeaderValue, AUTHORIZATION, CONTENT_RANGE, RANGE};
use std::cmp;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, AtomicU64, AtomicU8, AtomicUsize, Ordering};
use std::sync::{Arc, Weak};
use symphonia::core::io::MediaSource;

/// Positional I/O abstraction that enables thread-safe pread/pwrite without seek contention.
pub trait PositionalIo {
    fn read_at(&self, buf: &mut [u8], offset: u64) -> io::Result<usize>;
    fn write_at(&self, buf: &[u8], offset: u64) -> io::Result<usize>;
}

impl PositionalIo for File {
    #[cfg(unix)]
    fn read_at(&self, buf: &mut [u8], offset: u64) -> io::Result<usize> {
        use std::os::unix::fs::FileExt;
        FileExt::read_at(self, buf, offset)
    }

    #[cfg(unix)]
    fn write_at(&self, buf: &[u8], offset: u64) -> io::Result<usize> {
        use std::os::unix::fs::FileExt;
        FileExt::write_at(self, buf, offset)
    }

    #[cfg(windows)]
    fn read_at(&self, buf: &mut [u8], offset: u64) -> io::Result<usize> {
        use std::os::windows::fs::FileExt;
        FileExt::seek_read(self, buf, offset)
    }

    #[cfg(windows)]
    fn write_at(&self, buf: &[u8], offset: u64) -> io::Result<usize> {
        use std::os::windows::fs::FileExt;
        FileExt::seek_write(self, buf, offset)
    }
}

fn write_all_at(file: &impl PositionalIo, mut bytes: &[u8], mut offset: u64) -> io::Result<()> {
    while !bytes.is_empty() {
        match file.write_at(bytes, offset) {
            Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
            Ok(n) => {
                bytes = &bytes[n..];
                offset += n as u64;
            }
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

fn read_exact_at(
    file: &impl PositionalIo,
    mut bytes: &mut [u8],
    mut offset: u64,
) -> io::Result<()> {
    while !bytes.is_empty() {
        match file.read_at(bytes, offset) {
            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Ok(n) => {
                bytes = &mut bytes[n..];
                offset += n as u64;
            }
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

fn validate_range_response(
    response: &reqwest::Response,
    start: u64,
    end: u64,
    total: u64,
) -> Result<()> {
    anyhow::ensure!(
        response.status() == reqwest::StatusCode::PARTIAL_CONTENT,
        "Expected HTTP 206, received {}",
        response.status()
    );
    let expected = format!("bytes {}-{}/{}", start, end, total);
    anyhow::ensure!(
        response
            .headers()
            .get(CONTENT_RANGE)
            .and_then(|h| h.to_str().ok())
            == Some(expected.as_str()),
        "Unexpected Content-Range"
    );
    if let Some(len) = response.content_length() {
        anyhow::ensure!(len == end - start + 1, "Unexpected range body length");
    }
    Ok(())
}

pub const CHUNK_SIZE: u64 = 2 * 1024 * 1024; // 2 MB logical chunk unit
pub const DEFAULT_LOOKAHEAD_SECS: u64 = 30; // 30-second rolling runway lookahead

/// How many byte-range fetches are in flight right now.
pub static FETCHES_IN_FLIGHT: AtomicUsize = AtomicUsize::new(0);

/// Total bytes pulled from the network this session.
pub static BYTES_FETCHED: AtomicUsize = AtomicUsize::new(0);

/// Cache hit and miss telemetry counters.
pub static CACHE_HITS: AtomicU64 = AtomicU64::new(0);
pub static CACHE_MISSES: AtomicU64 = AtomicU64::new(0);

/// Time to first byte for the most recent chunk request.
pub static LAST_TTFB_MS: AtomicU32 = AtomicU32::new(0);

/// Rolling minute request count and minute timestamp.
pub static REQUESTS_LAST_MINUTE: AtomicU32 = AtomicU32::new(0);
pub static LAST_REQUEST_MINUTE_TS: AtomicU64 = AtomicU64::new(0);

/// Exponential moving average of measured network download throughput in bytes/second.
/// Initialized to 5 MB/s (typical fast mobile broadband).
pub static MEASURED_THROUGHPUT_BPS: AtomicU64 = AtomicU64::new(5_000_000);

pub fn cache_hit_rate() -> f64 {
    let hits = CACHE_HITS.load(Ordering::Relaxed);
    let misses = CACHE_MISSES.load(Ordering::Relaxed);
    let total = hits + misses;
    if total == 0 {
        1.0
    } else {
        hits as f64 / total as f64
    }
}

pub fn last_ttfb_ms() -> u32 {
    LAST_TTFB_MS.load(Ordering::Relaxed)
}

pub fn requests_per_minute() -> u32 {
    let current_minute = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() / 60)
        .unwrap_or(0);
    let last_minute = LAST_REQUEST_MINUTE_TS.load(Ordering::Relaxed);
    if current_minute == last_minute {
        REQUESTS_LAST_MINUTE.load(Ordering::Relaxed)
    } else {
        0
    }
}

pub fn record_network_request(ttfb_ms: u32) {
    LAST_TTFB_MS.store(ttfb_ms, Ordering::Relaxed);
    let current_minute = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() / 60)
        .unwrap_or(0);
    let last_minute = LAST_REQUEST_MINUTE_TS.load(Ordering::Relaxed);
    if current_minute != last_minute {
        LAST_REQUEST_MINUTE_TS.store(current_minute, Ordering::Relaxed);
        REQUESTS_LAST_MINUTE.store(1, Ordering::Relaxed);
    } else {
        REQUESTS_LAST_MINUTE.fetch_add(1, Ordering::Relaxed);
    }
}

pub fn update_measured_throughput(sample_bps: u64) {
    if sample_bps == 0 {
        return;
    }
    let old = MEASURED_THROUGHPUT_BPS.load(Ordering::Relaxed);
    let updated = ((old * 3) + sample_bps) / 4;
    MEASURED_THROUGHPUT_BPS.store(updated, Ordering::Relaxed);
}

pub fn measured_throughput_bps() -> u64 {
    MEASURED_THROUGHPUT_BPS.load(Ordering::Relaxed)
}

pub fn set_measured_throughput_bps(bps: u64) {
    MEASURED_THROUGHPUT_BPS.store(bps, Ordering::Relaxed);
}

/// Dynamic concurrency limit based on network throughput:
/// - Slow / cellular (< 2 MB/s): 2 concurrent fetches
/// - Standard broadband (2 - 8 MB/s): 3 concurrent fetches
/// - High-speed Wi-Fi / gigabit (> 8 MB/s): 4 concurrent fetches
pub fn current_concurrency_limit() -> usize {
    let bps = MEASURED_THROUGHPUT_BPS.load(Ordering::Relaxed);
    if bps < 2_000_000 {
        2
    } else if bps < 8_000_000 {
        3
    } else {
        4
    }
}

/// Context necessary for fetching chunks over HTTP byte ranges.
#[derive(Clone, Debug)]
pub struct FetchContext {
    pub url: String,
    pub auth_token: Option<String>,
    pub index_path: PathBuf,
}

/// Computes the nominal byte rate for a track based on SQLite metadata or duration/size heuristic.
pub fn calculate_nominal_byte_rate(
    file_id: &str,
    total_size: u64,
    db: Option<&Arc<parking_lot::Mutex<crate::cloud::db::MetadataDb>>>,
) -> u64 {
    let track_opt = if let Some(custom_db) = db {
        custom_db.lock().get_track(file_id).ok().flatten()
    } else {
        crate::api::cloud_library::with_db(|d| d.get_track(file_id).map_err(anyhow::Error::from))
            .ok()
            .flatten()
    };

    let rate = if let Some(track) = track_opt {
        if track.duration_ms > 0 {
            (total_size * 1000) / (track.duration_ms as u64)
        } else if track.sample_rate > 0 && track.bits_per_sample > 0 {
            let channels = track.channels.max(1) as u64;
            let bytes_per_sample = track.bits_per_sample.div_ceil(8) as u64;
            let raw_bps = (track.sample_rate as u64) * channels * bytes_per_sample;
            (raw_bps as f64 * 0.65) as u64
        } else {
            total_size / 240
        }
    } else {
        total_size / 240
    };

    // Clamp between 64 KB/s and 10 MB/s
    rate.clamp(64_000, 10_000_000)
}

use std::collections::HashMap;

lazy_static::lazy_static! {
    /// Telemetry cache for UI seek-bar visualization: key = file_id -> (total_bytes, completed_chunk_indices).
    pub static ref CACHED: Mutex<HashMap<String, (u64, Vec<u64>)>> = Mutex::new(HashMap::new());

    /// Global multi-threaded I/O runtime for network fetch actors.
    static ref GLOBAL_IO_RT: tokio::runtime::Runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .enable_all()
        .thread_name("bitdrop-cloud-io")
        .build()
        .expect("Failed to initialize bitdrop global I/O runtime");

    /// Shared HTTP client with connection pooling and adaptive HTTP/2 windowing.
    static ref HTTP_CLIENT: reqwest::Client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .pool_max_idle_per_host(16)
        .build()
        .expect("Failed to build HTTP client");
    /// Currently active sparse track cache for instantaneous cancellation on seek/skip/stop.
    static ref ACTIVE_CACHE: Mutex<Weak<SparseTrackCache>> = Mutex::new(Weak::new());
    static ref OPEN_CACHES: Mutex<HashMap<PathBuf, Weak<SparseTrackCache>>> = Mutex::new(HashMap::new());
    static ref FETCH_SLOTS: tokio::sync::Semaphore = tokio::sync::Semaphore::new(4);
}

pub fn set_active_cache(cache: Option<&Arc<SparseTrackCache>>) {
    *ACTIVE_CACHE.lock() = cache.map(Arc::downgrade).unwrap_or_default();
}

pub fn abort_active_fetches() {
    if let Some(cache) = ACTIVE_CACHE.lock().upgrade() {
        cache.cancel_fetches();
    }
}

pub fn forget_cached_ranges() {
    let mut guard = CACHED.lock();
    guard.clear();
}

pub fn cached_byte_ranges(file_id: Option<&str>) -> (u64, Vec<(u64, u64)>) {
    let guard = CACHED.lock();
    let entry = if let Some(fid) = file_id {
        guard.get(fid)
    } else {
        guard.values().next()
    };
    let Some((total, chunks)) = entry else {
        return (0, Vec::new());
    };

    let mut sorted = chunks.clone();
    sorted.sort_unstable();

    let mut out: Vec<(u64, u64)> = Vec::new();
    for idx in sorted {
        let start = idx * CHUNK_SIZE;
        let end = cmp::min(start + CHUNK_SIZE, *total);
        match out.last_mut() {
            Some(last) if last.1 >= start => last.1 = cmp::max(last.1, end),
            _ => out.push((start, end)),
        }
    }
    (*total, out)
}

pub fn fetches_in_flight() -> usize {
    FETCHES_IN_FLIGHT.load(Ordering::Relaxed)
}

pub fn bytes_fetched() -> usize {
    BYTES_FETCHED.load(Ordering::Relaxed)
}

#[repr(u8)]
#[derive(Clone, Copy)]
enum ChunkState {
    Idle,
    Fetching,
    Ready,
    Failed,
}

pub fn valid_file_id(file_id: &str) -> bool {
    !file_id.is_empty() && file_id != "." && file_id != ".." && !file_id.contains(['/', '\\'])
}

/// Live caches are protected from eviction, including metadata reads and preloads.
pub fn with_live_cache_ids<T>(f: impl FnOnce(Vec<String>) -> T) -> T {
    let mut caches = OPEN_CACHES.lock();
    caches.retain(|_, cache| cache.strong_count() > 0);
    let ids = caches
        .values()
        .filter_map(Weak::upgrade)
        .map(|c| c.file_id.clone())
        .collect();
    f(ids)
}

/// Clears only unused, unpinned audio files while serializing against cache opens.
pub fn clear_inactive_caches(dirs: &[String]) -> u64 {
    let mut caches = OPEN_CACHES.lock();
    caches.retain(|_, cache| cache.strong_count() > 0);
    let mut protected: std::collections::HashSet<String> = caches
        .values()
        .filter_map(Weak::upgrade)
        .map(|c| c.file_id.clone())
        .collect();
    let pinned = crate::api::cloud_library::with_db(|db| Ok(db.get_pinned_tracks()?));
    // Without the index, pin protection cannot be established.
    let Ok(pinned) = pinned else {
        return 0;
    };
    protected.extend(pinned);
    let mut freed = 0;
    for dir in dirs {
        let Ok(entries) = fs::read_dir(dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Some(ext) = path.extension().and_then(|e| e.to_str()) else {
                continue;
            };
            if !matches!(ext, "sparse" | "idx" | "dat" | "tmp") {
                continue;
            }
            let Some(file_id) = path.file_stem().and_then(|n| n.to_str()) else {
                continue;
            };
            if protected.contains(file_id) {
                continue;
            }
            let len = entry.metadata().map(|m| m.len()).unwrap_or(0);
            if fs::remove_file(&path).is_ok() {
                freed += len;
                if ext == "sparse" {
                    let _ = crate::api::cloud_library::with_db_mut(|db| {
                        Ok(db.delete_all_cached_chunks(file_id)?)
                    });
                    CACHED.lock().remove(file_id);
                }
            }
        }
    }
    freed
}

pub fn remove_inactive_cache(dir: &Path, file_id: &str) -> Result<bool> {
    anyhow::ensure!(valid_file_id(file_id), "Invalid cloud file identifier");
    let path = dir.join(format!("{}.sparse", file_id));
    let mut caches = OPEN_CACHES.lock();
    if caches.get(&path).and_then(Weak::upgrade).is_some() {
        return Ok(false);
    }
    crate::api::cloud_library::with_db_mut(|db| {
        db.delete_all_cached_chunks(file_id)?;
        for path in [path.clone(), dir.join(format!("{}.idx", file_id))] {
            match fs::remove_file(path) {
                Ok(()) => {}
                Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                Err(e) => return Err(e.into()),
            }
        }
        Ok(())
    })
    .map_err(anyhow::Error::msg)?;
    caches.remove(&path);
    CACHED.lock().remove(file_id);
    Ok(true)
}

pub struct SparseTrackCache {
    pub file_id: String,
    pub file: File,
    pub total_size: u64,
    pub chunk_written_bytes: Box<[AtomicU32]>,
    chunk_states: Box<[AtomicU8]>,
    readers: AtomicUsize,
    pub sync_mutex: Mutex<()>,
    pub data_arrived: Condvar,
    pub active_generation: AtomicU64,
    generation_changed: tokio::sync::Notify,
    pub db: Option<Arc<parking_lot::Mutex<crate::cloud::db::MetadataDb>>>,
    pub nominal_byte_rate: AtomicU64,
    pub lookahead_secs: AtomicU64,
    pub current_position: AtomicU64,
    pub fetch_ctx: parking_lot::Mutex<Option<FetchContext>>,
}

impl SparseTrackCache {
    pub fn new(sparse_path: &Path, index_path: &Path, total_size: u64) -> io::Result<Arc<Self>> {
        let file_id = sparse_path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("unknown")
            .to_string();
        Self::new_with_db(&file_id, sparse_path, index_path, total_size, None)
    }

    pub fn new_with_db(
        file_id: &str,
        sparse_path: &Path,
        index_path: &Path,
        total_size: u64,
        db: Option<Arc<parking_lot::Mutex<crate::cloud::db::MetadataDb>>>,
    ) -> io::Result<Arc<Self>> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(sparse_path)?;

        // Ensure file length matches total size (creates sparse metadata on ext4/f2fs without allocating disk blocks)
        if file.metadata()?.len() < total_size {
            file.set_len(total_size)?;
        }

        let chunk_count = total_size.div_ceil(CHUNK_SIZE) as usize;
        let mut written = Vec::with_capacity(chunk_count);
        let mut states = Vec::with_capacity(chunk_count);
        for _ in 0..chunk_count {
            written.push(AtomicU32::new(0));
            states.push(AtomicU8::new(ChunkState::Idle as u8));
        }

        let nominal_rate = calculate_nominal_byte_rate(file_id, total_size, db.as_ref());

        let cache = Arc::new(Self {
            file_id: file_id.to_string(),
            file,
            total_size,
            chunk_written_bytes: written.into_boxed_slice(),
            chunk_states: states.into_boxed_slice(),
            readers: AtomicUsize::new(0),
            sync_mutex: Mutex::new(()),
            data_arrived: Condvar::new(),
            active_generation: AtomicU64::new(1),
            generation_changed: tokio::sync::Notify::new(),
            db,
            nominal_byte_rate: AtomicU64::new(nominal_rate),
            lookahead_secs: AtomicU64::new(DEFAULT_LOOKAHEAD_SECS),
            current_position: AtomicU64::new(0),
            fetch_ctx: parking_lot::Mutex::new(None),
        });

        // 1. Query SQLite for cached chunks belonging to this file_id
        let records = cache.get_chunks_for_file(file_id);

        if !records.is_empty() {
            let actual_file_len = cache.file.metadata().map(|m| m.len()).unwrap_or(0);
            for rec in records {
                let idx = rec.chunk_idx as usize;
                if idx < chunk_count {
                    let chunk_start = idx as u64 * CHUNK_SIZE;
                    let chunk_len = ((total_size - chunk_start).min(CHUNK_SIZE)) as u32;

                    // Verify bounds and verify CRC32 from sparse file on disk
                    if actual_file_len >= chunk_start + chunk_len as u64 {
                        let mut verify_buf = vec![0u8; chunk_len as usize];
                        if let Ok(n) = cache.file.read_at(&mut verify_buf, chunk_start) {
                            if n == chunk_len as usize {
                                let mut hasher = crc32fast::Hasher::new();
                                hasher.update(&verify_buf);
                                if hasher.finalize() == rec.crc32 {
                                    // CRC32 integrity verified!
                                    cache.chunk_written_bytes[idx]
                                        .store(chunk_len, Ordering::Relaxed);
                                    continue;
                                }
                            }
                        }
                    }

                    // CRC32 mismatch or truncated file! Invalidate SQLite record so it re-fetches cleanly
                    eprintln!(
                        "[bitdrop] CRC32 mismatch or truncated chunk {} for {}, invalidating cache entry",
                        idx, file_id
                    );
                    cache.delete_chunk(file_id, rec.chunk_idx);
                }
            }
        } else if index_path.exists() {
            // Migration from legacy .idx file:
            // Read .idx, verify bytes, compute CRC32, populate SQLite
            if let Ok(content) = fs::read_to_string(index_path) {
                let actual_file_len = cache.file.metadata().map(|m| m.len()).unwrap_or(0);
                for line in content.lines() {
                    if let Ok(idx) = line.trim().parse::<usize>() {
                        if idx < chunk_count {
                            let chunk_start = idx as u64 * CHUNK_SIZE;
                            let chunk_len = ((total_size - chunk_start).min(CHUNK_SIZE)) as u32;
                            if actual_file_len >= chunk_start + chunk_len as u64 {
                                let mut verify_buf = vec![0u8; chunk_len as usize];
                                if let Ok(n) = cache.file.read_at(&mut verify_buf, chunk_start) {
                                    if n == chunk_len as usize {
                                        let mut hasher = crc32fast::Hasher::new();
                                        hasher.update(&verify_buf);
                                        let crc = hasher.finalize();
                                        let now = std::time::SystemTime::now()
                                            .duration_since(std::time::UNIX_EPOCH)
                                            .unwrap_or_default()
                                            .as_secs()
                                            as i64;
                                        let rec = crate::cloud::db::CachedChunkRecord {
                                            file_id: file_id.to_string(),
                                            chunk_idx: idx as u32,
                                            byte_offset: chunk_start,
                                            byte_len: chunk_len,
                                            crc32: crc,
                                            file_mtime: now,
                                            last_accessed_ts: now,
                                        };
                                        cache.record_chunk(&rec);
                                        cache.chunk_written_bytes[idx]
                                            .store(chunk_len, Ordering::Relaxed);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if index_path.exists() && !cache.get_chunks_for_file(file_id).is_empty() {
            let _ = fs::remove_file(index_path);
        }
        Ok(cache)
    }

    pub fn record_chunk(&self, chunk: &crate::cloud::db::CachedChunkRecord) {
        if let Some(db) = &self.db {
            let _ = db.lock().record_cached_chunk(chunk);
        } else {
            let _ = crate::api::cloud_library::with_db_mut(|db| {
                db.record_cached_chunk(chunk).map_err(anyhow::Error::from)
            });
        }
    }

    pub fn delete_chunk(&self, file_id: &str, chunk_idx: u32) {
        if let Some(db) = &self.db {
            let _ = db.lock().delete_cached_chunk(file_id, chunk_idx);
        } else {
            let _ = crate::api::cloud_library::with_db_mut(|db| {
                db.delete_cached_chunk(file_id, chunk_idx)
                    .map_err(anyhow::Error::from)
            });
        }
    }

    pub fn get_chunks_for_file(&self, file_id: &str) -> Vec<crate::cloud::db::CachedChunkRecord> {
        if let Some(db) = &self.db {
            db.lock().get_cached_chunks(file_id).unwrap_or_default()
        } else {
            crate::api::cloud_library::with_db(|db| {
                db.get_cached_chunks(file_id).map_err(anyhow::Error::from)
            })
            .unwrap_or_default()
        }
    }

    pub fn touch_chunk(&self, file_id: &str, chunk_idx: u32) {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;
        if let Some(db) = &self.db {
            let _ = db.lock().touch_chunk_access(file_id, chunk_idx, now);
        } else {
            let _ = crate::api::cloud_library::with_db_mut(|db| {
                db.touch_chunk_access(file_id, chunk_idx, now)
                    .map_err(anyhow::Error::from)
            });
        }
    }

    pub fn set_fetch_context(&self, ctx: FetchContext) {
        let mut guard = self.fetch_ctx.lock();
        *guard = Some(ctx);
    }

    pub fn schedule_read_ahead(self: &Arc<Self>) {
        let total_chunks = self.chunk_written_bytes.len();
        if total_chunks == 0 {
            return;
        }

        let current_pos = self.current_position.load(Ordering::Relaxed);
        let byte_rate = self.nominal_byte_rate.load(Ordering::Relaxed);
        let lookahead = self.lookahead_secs.load(Ordering::Relaxed);

        let runway_bytes = byte_rate.saturating_mul(lookahead).max(2 * CHUNK_SIZE);
        let target_byte = current_pos
            .saturating_add(runway_bytes)
            .min(self.total_size);

        let current_chunk = (current_pos / CHUNK_SIZE) as usize;
        let target_chunk = if target_byte > 0 {
            ((target_byte - 1) / CHUNK_SIZE) as usize
        } else {
            0
        };
        let end_chunk = target_chunk.min(total_chunks.saturating_sub(1));

        let max_concurrency = current_concurrency_limit();

        for idx in current_chunk..=end_chunk {
            if FETCHES_IN_FLIGHT.load(Ordering::Relaxed) >= max_concurrency {
                break;
            }

            let chunk_start = idx as u64 * CHUNK_SIZE;
            let chunk_len = ((self.total_size - chunk_start).min(CHUNK_SIZE)) as u32;
            let written = self.chunk_written_bytes[idx].load(Ordering::Acquire);

            if written < chunk_len {
                self.trigger_chunk_fetch(idx);
            }
        }
    }

    fn retry_failed_chunks(&self) {
        for state in &self.chunk_states {
            let _ = state.compare_exchange(
                ChunkState::Failed as u8,
                ChunkState::Idle as u8,
                Ordering::AcqRel,
                Ordering::Acquire,
            );
        }
    }

    /// Cancellation and byte publication use the wait mutex to prevent lost wakeups.
    pub fn cancel_fetches(&self) {
        let _guard = self.sync_mutex.lock();
        self.active_generation.fetch_add(1, Ordering::SeqCst);
        self.data_arrived.notify_all();
        self.generation_changed.notify_waiters();
    }

    fn publish_bytes(&self, chunk_idx: usize, written: u32) {
        let _guard = self.sync_mutex.lock();
        self.chunk_written_bytes[chunk_idx].store(written, Ordering::Release);
        self.data_arrived.notify_all();
    }

    pub fn trigger_chunk_fetch(self: &Arc<Self>, chunk_idx: usize) {
        if chunk_idx >= self.chunk_written_bytes.len()
            || self.chunk_states[chunk_idx]
                .compare_exchange(
                    ChunkState::Idle as u8,
                    ChunkState::Fetching as u8,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                )
                .is_err()
        {
            return;
        }
        let Some(ctx) = self.fetch_ctx.lock().clone() else {
            self.chunk_states[chunk_idx].store(ChunkState::Idle as u8, Ordering::Release);
            return;
        };
        let cache = Arc::clone(self);
        let generation = self.active_generation.load(Ordering::Acquire);
        // Reserve before spawning, so the scheduler observes queued work as well.
        FETCHES_IN_FLIGHT.fetch_add(1, Ordering::Relaxed);
        GLOBAL_IO_RT.spawn(async move {
            let result = cache.fetch_chunk(chunk_idx, generation, &ctx).await;
            {
                let _guard = cache.sync_mutex.lock();
                let state = if generation != cache.active_generation.load(Ordering::Acquire) {
                    ChunkState::Idle
                } else if let Err(ref error) = result {
                    eprintln!(
                        "[bitdrop] chunk {} of {} failed: {}",
                        chunk_idx, cache.file_id, error
                    );
                    ChunkState::Failed
                } else {
                    ChunkState::Ready
                };
                cache.chunk_states[chunk_idx].store(state as u8, Ordering::Release);
                FETCHES_IN_FLIGHT.fetch_sub(1, Ordering::Relaxed);
                cache.data_arrived.notify_all();
            }
            // Cancellation does not restart stale work. A reader schedules the new runway.
            if generation == cache.active_generation.load(Ordering::Acquire) {
                cache.schedule_read_ahead();
            }
        });
    }

    async fn fetch_chunk(&self, idx: usize, generation: u64, ctx: &FetchContext) -> Result<()> {
        // Register before checking the generation so cancellation cannot be missed.
        let changed = self.generation_changed.notified();
        tokio::pin!(changed);
        changed.as_mut().enable();
        if self.active_generation.load(Ordering::Acquire) != generation {
            return Ok(());
        }
        tokio::select! {
            biased;
            _ = changed => Ok(()),
            result = async {
                let _permit = FETCH_SLOTS.acquire().await?;
                let mut last_error = anyhow::anyhow!("Chunk fetch did not complete");
                for attempt in 0..4 {
                    match self.fetch_attempt(idx, ctx).await {
                        Ok(()) => return Ok(()),
                        Err(error) => last_error = error,
                    }
                    if attempt < 3 {
                        tokio::time::sleep(std::time::Duration::from_millis([200, 500, 1200][attempt])).await;
                    }
                }
                Err(last_error)
            } => result,
        }
    }

    async fn fetch_attempt(&self, idx: usize, ctx: &FetchContext) -> Result<()> {
        let start = idx as u64 * CHUNK_SIZE;
        let len = (self.total_size - start).min(CHUNK_SIZE) as u32;
        // Resume only after bytes that were actually written; retries never overwrite
        // bytes that have already been published to the decoder.
        let mut written = self.chunk_written_bytes[idx].load(Ordering::Acquire);
        if written < len {
            let request_start = start + written as u64;
            let token = self
                .fetch_ctx
                .lock()
                .as_ref()
                .and_then(|c| c.auth_token.clone());
            let mut headers = HeaderMap::new();
            headers.insert(
                RANGE,
                HeaderValue::from_str(&format!(
                    "bytes={}-{}",
                    request_start,
                    start + len as u64 - 1
                ))?,
            );
            if let Some(ref token) = token {
                headers.insert(
                    AUTHORIZATION,
                    HeaderValue::from_str(&format!("Bearer {}", token))?,
                );
            }
            let began = std::time::Instant::now();
            let response = HTTP_CLIENT.get(&ctx.url).headers(headers).send().await?;
            record_network_request(began.elapsed().as_millis().min(u32::MAX as u128) as u32);
            if response.status() == reqwest::StatusCode::UNAUTHORIZED {
                if let Some(ref rejected) = token {
                    if let Some(refreshed) = crate::cloud::auth::refresh_token(rejected).await {
                        if let Some(context) = self.fetch_ctx.lock().as_mut() {
                            context.auth_token = Some(refreshed);
                        }
                    }
                }
                anyhow::bail!("Cloud session expired or authorization was rejected");
            }
            validate_range_response(
                &response,
                request_start,
                start + len as u64 - 1,
                self.total_size,
            )?;
            let mut stream = response.bytes_stream();
            while let Some(bytes) = stream.next().await {
                let bytes = bytes?;
                anyhow::ensure!(
                    bytes.len() <= (len - written) as usize,
                    "Range response exceeds requested chunk"
                );
                write_all_at(&self.file, &bytes, start + written as u64)?;
                written += bytes.len() as u32;
                BYTES_FETCHED.fetch_add(bytes.len(), Ordering::Relaxed);
                self.publish_bytes(idx, written);
            }
            anyhow::ensure!(written == len, "Truncated range response");
            let elapsed_ms = began.elapsed().as_millis();
            if elapsed_ms > 30 {
                update_measured_throughput(
                    ((start + len as u64 - request_start) as u128 * 1000 / elapsed_ms) as u64,
                );
            }
        }

        let mut bytes = vec![0; len as usize];
        read_exact_at(&self.file, &mut bytes, start)?;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;
        self.record_chunk(&crate::cloud::db::CachedChunkRecord {
            file_id: self.file_id.clone(),
            chunk_idx: idx as u32,
            byte_offset: start,
            byte_len: len,
            crc32: crc32fast::hash(&bytes),
            file_mtime: now,
            last_accessed_ts: now,
        });
        {
            let mut cached = CACHED.lock();
            if let Some((_, chunks)) = cached.get_mut(&self.file_id) {
                if !chunks.contains(&(idx as u64)) {
                    chunks.push(idx as u64);
                }
            }
        }
        // Legacy indexes are read during migration only. SQLite owns completion state.
        self.prune_cache(ctx);
        Ok(())
    }

    fn prune_cache(&self, ctx: &FetchContext) {
        let limit = crate::api::cloud_library::cloud_cache_get_limit();
        if limit == 0 {
            return;
        }
        with_live_cache_ids(|protected| {
            let prune = |db: &mut crate::cloud::db::MetadataDb| -> Result<()> {
                if db.get_cache_stats(&[])?.unpinned_bytes > limit {
                    let evicted = db.prune_lru_chunks(limit, &protected, Some(&self.file_id))?;
                    if let Some(dir) = ctx.index_path.parent() {
                        apply_chunk_evictions(dir, &evicted, db);
                    }
                }
                Ok(())
            };
            if let Some(db) = &self.db {
                let _ = prune(&mut db.lock());
            } else {
                let _ = crate::api::cloud_library::with_db_mut(prune);
            }
        });
    }
}

pub struct CloudMediaSource {
    file_id: String,
    position: u64,
    generation: u64,
    cache: Arc<SparseTrackCache>,
}

impl CloudMediaSource {
    pub fn new(
        file_id: String,
        url: String,
        auth_token: Option<String>,
        total_size: u64,
        cache_dir: PathBuf,
    ) -> Result<Self> {
        fs::create_dir_all(&cache_dir)?;
        let sparse_path = cache_dir.join(format!("{}.sparse", file_id));
        let index_path = cache_dir.join(format!("{}.idx", file_id));

        anyhow::ensure!(total_size > 0, "Cloud file is empty");
        anyhow::ensure!(valid_file_id(&file_id), "Invalid cloud file identifier");
        let cache = {
            let mut caches = OPEN_CACHES.lock();
            if let Some(cache) = caches.get(&sparse_path).and_then(Weak::upgrade) {
                anyhow::ensure!(
                    cache.total_size == total_size,
                    "Cloud file size changed while open"
                );
                cache
            } else {
                let cache = SparseTrackCache::new_with_db(
                    &file_id,
                    &sparse_path,
                    &index_path,
                    total_size,
                    None,
                )?;
                caches.insert(sparse_path, Arc::downgrade(&cache));
                cache
            }
        };
        cache.readers.fetch_add(1, Ordering::Relaxed);
        cache.retry_failed_chunks();

        cache.set_fetch_context(FetchContext {
            url,
            auth_token,
            index_path,
        });

        // Populate initial seek-bar telemetry from already cached chunks
        {
            let mut existing = Vec::new();
            for (idx, written) in cache.chunk_written_bytes.iter().enumerate() {
                let chunk_len = ((total_size - (idx as u64 * CHUNK_SIZE)).min(CHUNK_SIZE)) as u32;
                if written.load(Ordering::Relaxed) >= chunk_len {
                    existing.push(idx as u64);
                }
            }
            let mut guard = CACHED.lock();
            guard.insert(file_id.clone(), (total_size, existing));
        }

        // Proactively schedule initial 30s runway chunks immediately
        cache.schedule_read_ahead();

        Ok(Self {
            file_id,
            position: 0,
            generation: cache.active_generation.load(Ordering::Acquire),
            cache,
        })
    }

    pub fn seek_to_current_generation(&mut self) {
        self.generation = self.cache.active_generation.load(Ordering::Acquire);
    }

    pub fn cache(&self) -> &Arc<SparseTrackCache> {
        &self.cache
    }

    pub fn nominal_byte_rate(&self) -> u64 {
        self.cache.nominal_byte_rate.load(Ordering::Relaxed)
    }

    pub fn set_nominal_byte_rate(&self, rate: u64) {
        self.cache.nominal_byte_rate.store(rate, Ordering::Relaxed);
        self.cache.schedule_read_ahead();
    }

    pub fn lookahead_secs(&self) -> u64 {
        self.cache.lookahead_secs.load(Ordering::Relaxed)
    }

    pub fn set_lookahead_secs(&self, secs: u64) {
        self.cache.lookahead_secs.store(secs, Ordering::Relaxed);
        self.cache.schedule_read_ahead();
    }

    pub fn schedule_read_ahead(&self) {
        self.cache.schedule_read_ahead();
    }

    pub fn trigger_chunk_fetch(&self, chunk_idx: usize) {
        self.cache.trigger_chunk_fetch(chunk_idx);
    }

    #[inline]
    fn ensure_bytes_available(&self, chunk_idx: usize, needed_end: u32) -> io::Result<()> {
        // Fast path: requested slice already written to disk / page cache.
        // Cached data is always valid regardless of generation changes.
        if self.cache.chunk_written_bytes[chunk_idx].load(Ordering::Acquire) >= needed_end {
            CACHE_HITS.fetch_add(1, Ordering::Relaxed);
            return Ok(());
        }

        if self.cache.active_generation.load(Ordering::Acquire) != self.generation {
            return Err(io::Error::new(io::ErrorKind::Interrupted, "Read cancelled"));
        }
        CACHE_MISSES.fetch_add(1, Ordering::Relaxed);

        // Trigger fetch of current chunk and fill rolling runway
        self.cache.trigger_chunk_fetch(chunk_idx);
        self.cache.schedule_read_ahead();

        // Slow path: park thread on Condvar until the requested slice arrives
        let mut guard = self.cache.sync_mutex.lock();
        while self.cache.chunk_written_bytes[chunk_idx].load(Ordering::Acquire) < needed_end {
            if self.cache.active_generation.load(Ordering::Relaxed) != self.generation {
                return Err(io::Error::new(io::ErrorKind::Interrupted, "Track skipped"));
            }
            if self.cache.chunk_states[chunk_idx].load(Ordering::Acquire)
                == ChunkState::Failed as u8
            {
                return Err(io::Error::other("Network fetch failed after retries"));
            }
            self.cache
                .data_arrived
                .wait_for(&mut guard, std::time::Duration::from_millis(100));
            drop(guard);
            self.cache.trigger_chunk_fetch(chunk_idx);
            guard = self.cache.sync_mutex.lock();
        }

        Ok(())
    }
}

impl Read for CloudMediaSource {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.position >= self.cache.total_size || buf.is_empty() {
            return Ok(0); // EOF
        }

        self.cache
            .current_position
            .store(self.position, Ordering::Relaxed);

        let chunk_idx = (self.position / CHUNK_SIZE) as usize;
        let chunk_offset = (self.position % CHUNK_SIZE) as u32;
        let chunk_total_len =
            ((self.cache.total_size - (chunk_idx as u64 * CHUNK_SIZE)).min(CHUNK_SIZE)) as u32;

        let max_readable_in_chunk = (chunk_total_len - chunk_offset) as usize;
        let to_read = buf.len().min(max_readable_in_chunk);
        let needed_end = chunk_offset + (to_read as u32);

        loop {
            match self.ensure_bytes_available(chunk_idx, needed_end) {
                Ok(()) => break,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {
                    self.generation = self.cache.active_generation.load(Ordering::Acquire);
                    if self.cache.readers.load(Ordering::Acquire) > 1 {
                        // In a shared cache, another reader's seek/cancellation does not
                        // stall this reader. Re-join the active generation and retry.
                        continue;
                    }
                    return Err(error);
                }
                Err(error) => return Err(error),
            }
        }

        // Positional zero-seek read directly from unified kernel page cache
        let bytes_read = self
            .cache
            .file
            .read_at(&mut buf[..to_read], self.position)?;
        self.position += bytes_read as u64;
        self.cache
            .current_position
            .store(self.position, Ordering::Relaxed);
        self.cache.touch_chunk(&self.file_id, chunk_idx as u32);

        // Continuous rolling 30-second read-ahead scheduler
        self.cache.schedule_read_ahead();

        Ok(bytes_read)
    }
}

impl Seek for CloudMediaSource {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        let new_pos = match pos {
            SeekFrom::Start(p) => p as i64,
            SeekFrom::End(p) => self.cache.total_size as i64 + p,
            SeekFrom::Current(p) => self.position as i64 + p,
        };

        if new_pos < 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Seek before start of file",
            ));
        }

        let new_pos = cmp::min(new_pos as u64, self.cache.total_size);
        let old_chunk = (self.position / CHUNK_SIZE) as usize;
        let new_chunk = (new_pos / CHUNK_SIZE) as usize;

        self.position = new_pos;
        self.cache
            .current_position
            .store(new_pos, Ordering::Relaxed);

        // Shared readers may still need the existing requests at their own positions.
        if (new_chunk as isize - old_chunk as isize).abs() > 2
            && self.cache.readers.load(Ordering::Acquire) == 1
        {
            self.cache.cancel_fetches();
        }
        self.generation = self.cache.active_generation.load(Ordering::Acquire);
        self.cache.retry_failed_chunks();

        self.cache.schedule_read_ahead();
        Ok(self.position)
    }
}

impl MediaSource for CloudMediaSource {
    fn is_seekable(&self) -> bool {
        true
    }

    fn byte_len(&self) -> Option<u64> {
        Some(self.cache.total_size)
    }
}

impl Drop for CloudMediaSource {
    fn drop(&mut self) {
        if self.cache.readers.fetch_sub(1, Ordering::AcqRel) == 1 {
            self.cache.cancel_fetches();
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
pub fn deallocate_chunk_range(file: &std::fs::File, offset: u64, len: u64) {
    use std::os::unix::io::AsRawFd;
    // FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE = 0x02 | 0x01 = 0x03
    unsafe {
        libc::fallocate(
            file.as_raw_fd(),
            3,
            offset as libc::off_t,
            len as libc::off_t,
        );
    }
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
pub fn deallocate_chunk_range(_file: &std::fs::File, _offset: u64, _len: u64) {
    // Non-Linux platforms: hole punching is platform-specific
}

/// Evicts chunks from physical disk and active cache. On Linux/Android, punches holes in sparse files.
/// When all chunks of a file are evicted, deletes the .sparse and .idx files completely.
pub fn apply_chunk_evictions<P: AsRef<Path>>(
    chunk_dir: P,
    evicted: &[crate::cloud::db::EvictedChunk],
    db: &crate::cloud::db::MetadataDb,
) {
    let dir = chunk_dir.as_ref();
    for chunk in evicted {
        let sparse_path = dir.join(format!("{}.sparse", chunk.file_id));
        if sparse_path.exists() {
            if let Ok(file) = OpenOptions::new().write(true).open(&sparse_path) {
                deallocate_chunk_range(&file, chunk.byte_offset, chunk.byte_len as u64);
            }
        }

        // Check if all chunks for this track are gone
        if db.count_cached_chunks_for_file(&chunk.file_id).unwrap_or(0) == 0 {
            let _ = std::fs::remove_file(&sparse_path);
            let idx_path = dir.join(format!("{}.idx", chunk.file_id));
            let _ = std::fs::remove_file(idx_path);
        }

        // Update in-memory telemetry
        let mut guard = CACHED.lock();
        if let Some((_, ref mut chunks)) = guard.get_mut(&chunk.file_id) {
            chunks.retain(|&idx| idx != chunk.chunk_idx as u64);
        }

        // Update active cache if it matches
        if let Some(active) = ACTIVE_CACHE.lock().upgrade() {
            if active.file_id == chunk.file_id {
                let idx = chunk.chunk_idx as usize;
                if idx < active.chunk_written_bytes.len() {
                    active.chunk_written_bytes[idx].store(0, Ordering::Release);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloud::db::MetadataDb;
    use std::fs::File;
    use std::io::Write;

    #[test]
    fn test_sparse_cache_sqlite_and_crc32_verification() {
        let temp_dir =
            std::env::temp_dir().join(format!("bitdrop_test_cache_{}", std::process::id()));
        let _ = fs::remove_dir_all(&temp_dir);
        fs::create_dir_all(&temp_dir).unwrap();

        let db = Arc::new(parking_lot::Mutex::new(
            MetadataDb::new_in_memory().unwrap(),
        ));
        let file_id = "test_track_integrity";
        let sparse_path = temp_dir.join(format!("{}.sparse", file_id));
        let index_path = temp_dir.join(format!("{}.idx", file_id));
        let total_size = 4 * 1024 * 1024; // 4 MB (2 chunks)

        // Write deterministic 2MB chunk 0 data
        let mut chunk0_data = vec![0xABu8; (CHUNK_SIZE) as usize];
        chunk0_data[0] = 0x12;
        chunk0_data[100] = 0x34;

        let mut hasher = crc32fast::Hasher::new();
        hasher.update(&chunk0_data);
        let valid_crc = hasher.finalize();

        {
            let mut f = File::create(&sparse_path).unwrap();
            f.write_all(&chunk0_data).unwrap();
            // Truncate/extend to total_size
            f.set_len(total_size).unwrap();
        }

        // 1. Record valid chunk 0 in SQLite
        let now = 1700000000;
        let rec = crate::cloud::db::CachedChunkRecord {
            file_id: file_id.to_string(),
            chunk_idx: 0,
            byte_offset: 0,
            byte_len: CHUNK_SIZE as u32,
            crc32: valid_crc,
            file_mtime: now,
            last_accessed_ts: now,
        };
        db.lock().record_cached_chunk(&rec).unwrap();

        // 2. Open cache: chunk 0 should be verified and ready
        let cache = SparseTrackCache::new_with_db(
            file_id,
            &sparse_path,
            &index_path,
            total_size,
            Some(Arc::clone(&db)),
        )
        .unwrap();

        assert_eq!(
            cache.chunk_written_bytes[0].load(Ordering::Relaxed),
            CHUNK_SIZE as u32,
            "Chunk 0 must be verified via CRC32"
        );
        assert_eq!(
            cache.chunk_written_bytes[1].load(Ordering::Relaxed),
            0,
            "Chunk 1 must not be written yet"
        );

        // 3. Corrupt chunk 0 on disk (flip 1 byte)
        {
            let f = OpenOptions::new().write(true).open(&sparse_path).unwrap();
            f.write_at(&[0xFF], 100).unwrap(); // corrupted byte at offset 100
        }

        // 4. Reopen cache: CRC32 mismatch must be detected and invalidated
        let cache_corrupted = SparseTrackCache::new_with_db(
            file_id,
            &sparse_path,
            &index_path,
            total_size,
            Some(Arc::clone(&db)),
        )
        .unwrap();

        assert_eq!(
            cache_corrupted.chunk_written_bytes[0].load(Ordering::Relaxed),
            0,
            "Corrupted chunk 0 must be invalidated to 0 bytes so it re-fetches"
        );
        assert!(
            db.lock().get_cached_chunk(file_id, 0).unwrap().is_none(),
            "Corrupted chunk 0 record must be removed from SQLite"
        );

        let _ = fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn test_sparse_cache_legacy_idx_migration() {
        let temp_dir =
            std::env::temp_dir().join(format!("bitdrop_test_mig_{}", std::process::id()));
        let _ = fs::remove_dir_all(&temp_dir);
        fs::create_dir_all(&temp_dir).unwrap();

        let db = Arc::new(parking_lot::Mutex::new(
            MetadataDb::new_in_memory().unwrap(),
        ));
        let file_id = "legacy_track";
        let sparse_path = temp_dir.join(format!("{}.sparse", file_id));
        let index_path = temp_dir.join(format!("{}.idx", file_id));
        let total_size = 2 * 1024 * 1024; // 2 MB (1 chunk)

        let chunk_data = vec![0x7Fu8; total_size as usize];
        {
            let mut f = File::create(&sparse_path).unwrap();
            f.write_all(&chunk_data).unwrap();
        }
        {
            let mut idx_file = File::create(&index_path).unwrap();
            writeln!(idx_file, "0").unwrap();
        }

        // Open cache: should migrate legacy .idx to SQLite with calculated CRC32
        let cache = SparseTrackCache::new_with_db(
            file_id,
            &sparse_path,
            &index_path,
            total_size,
            Some(Arc::clone(&db)),
        )
        .unwrap();

        assert_eq!(
            cache.chunk_written_bytes[0].load(Ordering::Relaxed),
            total_size as u32
        );

        let chunk_rec = db.lock().get_cached_chunk(file_id, 0).unwrap().unwrap();
        let mut hasher = crc32fast::Hasher::new();
        hasher.update(&chunk_data);
        assert_eq!(chunk_rec.crc32, hasher.finalize());

        let _ = fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn test_bitrate_aware_nominal_rate_calculation() {
        let db = Arc::new(parking_lot::Mutex::new(
            MetadataDb::new_in_memory().unwrap(),
        ));

        // Case A: Track with known duration (240s, 276 MB hi-res FLAC)
        db.lock()
            .conn
            .execute(
                "INSERT INTO tracks (file_id, name, folder_path, title, artist, album, album_artist, genre, year, track_number, disc_number, duration_ms, sample_rate, channels, bits_per_sample, size_bytes, tags_read, artwork_path)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)",
                rusqlite::params![
                    "hires_track", "test.flac", "/music", "HiRes Test", "Artist", "Album", "Artist", "Jazz", 2024, 1, 1, 240_000, 192_000, 2, 24, 276_480_000i64, 1, ""
                ],
            )
            .unwrap();

        let rate_hires = calculate_nominal_byte_rate("hires_track", 276_480_000, Some(&db));
        // Expecting 276_480_000 * 1000 / 240_000 = 1_152_000 B/s
        assert_eq!(rate_hires, 1_152_000);

        // Case B: Track with unknown duration (duration_ms = 0), but known 192kHz 24-bit stereo
        db.lock()
            .conn
            .execute(
                "INSERT INTO tracks (file_id, name, folder_path, title, artist, album, album_artist, genre, year, track_number, disc_number, duration_ms, sample_rate, channels, bits_per_sample, size_bytes, tags_read, artwork_path)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)",
                rusqlite::params![
                    "hires_nodur", "nodur.flac", "/music", "NoDur Test", "Artist", "Album", "Artist", "Classical", 2024, 2, 1, 0, 192_000, 2, 24, 276_480_000i64, 1, ""
                ],
            )
            .unwrap();

        let rate_nodur = calculate_nominal_byte_rate("hires_nodur", 276_480_000, Some(&db));
        // raw = 192000 * 2 * 3 = 1_152_000 * 0.65 = 748_800 B/s
        assert_eq!(rate_nodur, 748_800);

        // Case C: Untagged / not in DB (fallback total_size / 240)
        let rate_untagged = calculate_nominal_byte_rate("unknown_file", 240_000_000, Some(&db));
        assert_eq!(rate_untagged, 1_000_000);
    }

    #[test]
    fn test_throughput_concurrency_scaling() {
        // Slow throughput: < 2 MB/s
        set_measured_throughput_bps(1_500_000);
        assert_eq!(current_concurrency_limit(), 2);

        // Standard throughput: 5 MB/s
        set_measured_throughput_bps(5_000_000);
        assert_eq!(current_concurrency_limit(), 3);

        // High throughput: 12 MB/s
        set_measured_throughput_bps(12_000_000);
        assert_eq!(current_concurrency_limit(), 4);

        // Test EMA smoothing:
        set_measured_throughput_bps(4_000_000);
        update_measured_throughput(8_000_000);
        // (4_000_000 * 3 + 8_000_000) / 4 = 5_000_000
        assert_eq!(measured_throughput_bps(), 5_000_000);
    }

    #[test]
    fn test_bitrate_aware_30s_rolling_read_ahead_scheduler() {
        let temp_dir =
            std::env::temp_dir().join(format!("bitdrop_test_sched_{}", std::process::id()));
        let _ = fs::remove_dir_all(&temp_dir);
        fs::create_dir_all(&temp_dir).unwrap();

        let db = Arc::new(parking_lot::Mutex::new(
            MetadataDb::new_in_memory().unwrap(),
        ));
        let file_id = "test_sched_track";
        let sparse_path = temp_dir.join(format!("{}.sparse", file_id));
        let index_path = temp_dir.join(format!("{}.idx", file_id));
        let total_size = 60 * 1024 * 1024; // 60 MB (30 chunks of 2 MB)

        let cache = SparseTrackCache::new_with_db(
            file_id,
            &sparse_path,
            &index_path,
            total_size,
            Some(Arc::clone(&db)),
        )
        .unwrap();

        assert_eq!(cache.chunk_written_bytes.len(), 30);

        // 1. CD Quality (16/44.1): ~110 KB/s rate. Lookahead = 30s.
        // Runway bytes = (110_000 * 30).max(4 MB) = 4 MB (chunks 0 and 1)
        cache.nominal_byte_rate.store(110_000, Ordering::Relaxed);
        cache.lookahead_secs.store(30, Ordering::Relaxed);
        cache.current_position.store(0, Ordering::Relaxed);

        // Runway check math
        let runway = (110_000u64 * 30).max(2 * CHUNK_SIZE);
        assert_eq!(runway, 4 * 1024 * 1024);
        let end_chunk = ((runway - 1) / CHUNK_SIZE) as usize;
        assert_eq!(
            end_chunk, 1,
            "CD audio 30s runway should require only chunks 0..=1"
        );

        // 2. Hi-Res 24/192: ~1,152,000 B/s (~1.15 MB/s). Lookahead = 30s.
        // Runway bytes = 1,152_000 * 30 = 34,560,000 bytes (~34.5 MB).
        cache.nominal_byte_rate.store(1_152_000, Ordering::Relaxed);
        let hires_runway = (1_152_000u64 * 30).max(2 * CHUNK_SIZE);
        let hires_end_chunk = ((hires_runway - 1) / CHUNK_SIZE) as usize;
        assert_eq!(
            hires_end_chunk, 16,
            "Hi-Res audio 30s runway requires chunks 0..=16"
        );

        // 3. Advancing position shifts the rolling runway forward
        // Seek to 20 MB (chunk 10)
        cache
            .current_position
            .store(20 * 1024 * 1024, Ordering::Relaxed);
        let pos = cache.current_position.load(Ordering::Relaxed);
        let target_byte = (pos + hires_runway).min(total_size);
        let target_end_chunk = ((target_byte - 1) / CHUNK_SIZE) as usize;
        assert_eq!(
            target_end_chunk, 26,
            "Position at chunk 10 shifts rolling runway to chunk 26"
        );

        let _ = fs::remove_dir_all(&temp_dir);
    }

    #[test]
    fn test_apply_chunk_evictions_sparse_file_cleanup() {
        let temp_dir =
            std::env::temp_dir().join(format!("bitdrop_test_evict_{}", std::process::id()));
        let _ = fs::remove_dir_all(&temp_dir);
        fs::create_dir_all(&temp_dir).unwrap();

        let db = MetadataDb::new_in_memory().unwrap();

        // Create dummy sparse and idx files for track_A
        let sparse_a = temp_dir.join("track_A.sparse");
        let idx_a = temp_dir.join("track_A.idx");
        fs::write(&sparse_a, vec![0u8; 4 * 1024 * 1024]).unwrap();
        fs::write(&idx_a, b"idx_data").unwrap();

        assert!(sparse_a.exists());
        assert!(idx_a.exists());

        // Eviction record for track_A chunk 0
        let evictions = vec![crate::cloud::db::EvictedChunk {
            file_id: "track_A".to_string(),
            chunk_idx: 0,
            byte_offset: 0,
            byte_len: 2 * 1024 * 1024,
        }];

        // Since count_cached_chunks_for_file("track_A") is 0 in db,
        // apply_chunk_evictions should delete both sparse and idx files.
        apply_chunk_evictions(&temp_dir, &evictions, &db);

        assert!(
            !sparse_a.exists(),
            "Sparse file should be deleted when 0 chunks remain"
        );
        assert!(
            !idx_a.exists(),
            "Index file should be deleted when 0 chunks remain"
        );

        let _ = fs::remove_dir_all(&temp_dir);
    }
}

#[cfg(test)]
#[path = "cache_tests.rs"]
mod cache_tests;

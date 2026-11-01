use anyhow::Result;
use futures_util::StreamExt;
use parking_lot::{Condvar, Mutex};
use reqwest::header::{HeaderMap, HeaderValue, AUTHORIZATION, RANGE};
use std::cmp;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
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

pub const CHUNK_SIZE: u64 = 2 * 1024 * 1024; // 2 MB logical chunk unit

/// How many byte-range fetches are in flight right now.
pub static FETCHES_IN_FLIGHT: AtomicUsize = AtomicUsize::new(0);

/// Total bytes pulled from the network this session.
pub static BYTES_FETCHED: AtomicUsize = AtomicUsize::new(0);

use std::collections::HashMap;

pub type TokenProviderCallback = Box<dyn Fn() -> Option<String> + Send + Sync>;

/// Global token provider callback for refreshing 401 expired OAuth tokens.
pub static TOKEN_PROVIDER: Mutex<Option<TokenProviderCallback>> = Mutex::new(None);

pub fn set_token_provider<F>(f: F)
where
    F: Fn() -> Option<String> + Send + Sync + 'static,
{
    let mut guard = TOKEN_PROVIDER.lock();
    *guard = Some(Box::new(f));
}

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
    static ref ACTIVE_CACHE: Mutex<Option<Arc<SparseTrackCache>>> = Mutex::new(None);
}

pub fn set_active_cache(cache: Arc<SparseTrackCache>) {
    let mut guard = ACTIVE_CACHE.lock();
    if let Some(old) = guard.replace(cache) {
        old.active_generation.fetch_add(1, Ordering::SeqCst);
        old.data_arrived.notify_all();
    }
}

pub fn abort_active_fetches() {
    let mut guard = ACTIVE_CACHE.lock();
    if let Some(cache) = guard.take() {
        cache.active_generation.fetch_add(1, Ordering::SeqCst);
        cache.data_arrived.notify_all();
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

pub struct SparseTrackCache {
    pub file: File,
    pub total_size: u64,
    pub chunk_written_bytes: Box<[AtomicU32]>,
    pub chunk_fetching: Box<[AtomicBool]>,
    pub chunk_failed: Box<[AtomicBool]>,
    pub sync_mutex: Mutex<()>,
    pub data_arrived: Condvar,
    pub active_generation: AtomicU64,
    pub failed: AtomicBool,
}

impl SparseTrackCache {
    pub fn new(sparse_path: &Path, index_path: &Path, total_size: u64) -> io::Result<Arc<Self>> {
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
        let mut fetching = Vec::with_capacity(chunk_count);
        let mut failed = Vec::with_capacity(chunk_count);
        for _ in 0..chunk_count {
            written.push(AtomicU32::new(0));
            fetching.push(AtomicBool::new(false));
            failed.push(AtomicBool::new(false));
        }

        // Check if an index file exists with previously completed chunks
        if index_path.exists() {
            if let Ok(content) = fs::read_to_string(index_path) {
                for line in content.lines() {
                    if let Ok(idx) = line.trim().parse::<usize>() {
                        if idx < chunk_count {
                            let chunk_len = ((total_size - (idx as u64 * CHUNK_SIZE)).min(CHUNK_SIZE)) as u32;
                            written[idx].store(chunk_len, Ordering::Relaxed);
                        }
                    }
                }
            }
        }

        Ok(Arc::new(Self {
            file,
            total_size,
            chunk_written_bytes: written.into_boxed_slice(),
            chunk_fetching: fetching.into_boxed_slice(),
            chunk_failed: failed.into_boxed_slice(),
            sync_mutex: Mutex::new(()),
            data_arrived: Condvar::new(),
            active_generation: AtomicU64::new(1),
            failed: AtomicBool::new(false),
        }))
    }
}

pub struct CloudMediaSource {
    file_id: String,
    url: String,
    auth_token: Option<String>,
    position: u64,
    generation: u64,
    cache: Arc<SparseTrackCache>,
    index_path: PathBuf,
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

        let cache = SparseTrackCache::new(&sparse_path, &index_path, total_size)?;

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

        set_active_cache(Arc::clone(&cache));

        Ok(Self {
            file_id,
            url,
            auth_token,
            position: 0,
            generation: 1,
            cache,
            index_path,
        })
    }

    fn trigger_chunk_fetch(&self, chunk_idx: usize) {
        if chunk_idx >= self.cache.chunk_written_bytes.len() {
            return;
        }

        // Atomic check-and-set: prevent duplicate in-flight fetches for the same chunk
        if self.cache.chunk_fetching[chunk_idx].swap(true, Ordering::SeqCst) {
            return; // Already being fetched
        }

        let chunk_start = chunk_idx as u64 * CHUNK_SIZE;
        let chunk_len = ((self.cache.total_size - chunk_start).min(CHUNK_SIZE)) as u32;
        let chunk_end = chunk_start + chunk_len as u64 - 1;

        let cache = Arc::clone(&self.cache);
        let url = self.url.clone();
        let token = self.auth_token.clone();
        let file_id = self.file_id.clone();
        let index_path = self.index_path.clone();
        let generation = self.generation;

        GLOBAL_IO_RT.spawn(async move {
            FETCHES_IN_FLIGHT.fetch_add(1, Ordering::Relaxed);

            let backoffs = [
                std::time::Duration::from_millis(200),
                std::time::Duration::from_millis(500),
                std::time::Duration::from_millis(1200),
            ];

            let mut current_token = token;
            let mut final_res: Result<()> = Ok(());

            for attempt in 0..=3 {
                if cache.active_generation.load(Ordering::Relaxed) != generation {
                    // Superseded by newer track request
                    FETCHES_IN_FLIGHT.fetch_sub(1, Ordering::Relaxed);
                    cache.chunk_fetching[chunk_idx].store(false, Ordering::Release);
                    return;
                }

                let range_val = format!("bytes={}-{}", chunk_start, chunk_end);
                let mut headers = HeaderMap::new();
                if let Ok(hv) = HeaderValue::from_str(&range_val) {
                    headers.insert(RANGE, hv);
                }

                if let Some(ref t) = current_token {
                    if let Ok(hv) = HeaderValue::from_str(&format!("Bearer {}", t)) {
                        headers.insert(AUTHORIZATION, hv);
                    }
                }

                let send_res = HTTP_CLIENT.get(&url).headers(headers).send().await;
                match send_res {
                    Ok(response) => {
                        let status = response.status();
                        // 401 Unauthorized handling: request token refresh and retry
                        if status.as_u16() == 401 {
                            eprintln!("[bitdrop] HTTP 401 Unauthorized for chunk {} of {}, requesting token refresh", chunk_idx, file_id);
                            let refreshed = {
                                let provider_guard = TOKEN_PROVIDER.lock();
                                provider_guard.as_ref().and_then(|cb| cb())
                            };
                            if let Some(new_token) = refreshed {
                                current_token = Some(new_token);
                            }
                            if let Some(&delay) = backoffs.get(attempt) {
                                tokio::time::sleep(delay).await;
                                continue;
                            } else {
                                final_res = Err(anyhow::anyhow!("HTTP 401 Unauthorized persistent"));
                                break;
                            }
                        }

                        if !status.is_success() && status.as_u16() != 206 {
                            final_res = Err(anyhow::anyhow!("HTTP error status: {}", status));
                            if let Some(&delay) = backoffs.get(attempt) {
                                tokio::time::sleep(delay).await;
                                continue;
                            } else {
                                break;
                            }
                        }

                        let mut stream = response.bytes_stream();
                        let mut written_in_chunk: u32 = 0;
                        let mut stream_err = None;

                        while let Some(item) = stream.next().await {
                            if cache.active_generation.load(Ordering::Relaxed) != generation {
                                FETCHES_IN_FLIGHT.fetch_sub(1, Ordering::Relaxed);
                                cache.chunk_fetching[chunk_idx].store(false, Ordering::Release);
                                return;
                            }

                            match item {
                                Ok(bytes) => {
                                    let slice_len = bytes.len() as u32;
                                    let write_pos = chunk_start + written_in_chunk as u64;

                                    if let Err(e) = cache.file.write_at(&bytes, write_pos) {
                                        stream_err = Some(anyhow::anyhow!("Disk write error: {:?}", e));
                                        break;
                                    }
                                    written_in_chunk += slice_len;

                                    cache.chunk_written_bytes[chunk_idx].store(written_in_chunk, Ordering::Release);
                                    BYTES_FETCHED.fetch_add(slice_len as usize, Ordering::Relaxed);

                                    // Wake up any threads waiting in Read::read() for this slice
                                    cache.data_arrived.notify_all();
                                }
                                Err(e) => {
                                    stream_err = Some(anyhow::anyhow!("Stream interrupted: {:?}", e));
                                    break;
                                }
                            }
                        }

                        if let Some(err) = stream_err {
                            final_res = Err(err);
                            if attempt < 3 {
                                tokio::time::sleep(backoffs[attempt]).await;
                                continue;
                            } else {
                                break;
                            }
                        }

                        // Chunk completed successfully! Clear any previous failure flags.
                        if written_in_chunk >= chunk_len {
                            cache.chunk_written_bytes[chunk_idx].store(chunk_len, Ordering::Release);
                            cache.chunk_failed[chunk_idx].store(false, Ordering::Release);
                            cache.failed.store(false, Ordering::Release);

                            let mut guard = CACHED.lock();
                            if let Some((_, ref mut chunks)) = guard.get_mut(&file_id) {
                                if !chunks.contains(&(chunk_idx as u64)) {
                                    chunks.push(chunk_idx as u64);
                                }
                            }
                            // Append chunk completion to index file
                            if let Ok(mut idx_file) = OpenOptions::new().create(true).append(true).open(&index_path) {
                                use std::io::Write;
                                let _ = writeln!(idx_file, "{}", chunk_idx);
                            }
                        }

                        final_res = Ok(());
                        break;
                    }
                    Err(e) => {
                        final_res = Err(anyhow::anyhow!("Connection error: {:?}", e));
                        if attempt < 3 {
                            tokio::time::sleep(backoffs[attempt]).await;
                            continue;
                        } else {
                            break;
                        }
                    }
                }
            }

            if let Err(e) = final_res {
                eprintln!("[bitdrop] failed streaming chunk {} for {} after retries: {:?}", chunk_idx, file_id, e);
                cache.chunk_failed[chunk_idx].store(true, Ordering::Release);
                cache.failed.store(true, Ordering::Release);
            }

            cache.chunk_fetching[chunk_idx].store(false, Ordering::Release);
            FETCHES_IN_FLIGHT.fetch_sub(1, Ordering::Relaxed);
            cache.data_arrived.notify_all();
        });
    }

    #[inline]
    fn ensure_bytes_available(&self, chunk_idx: usize, needed_end: u32) -> io::Result<()> {
        // Fast path (Lock-free): requested slice already written to disk / page cache
        if self.cache.chunk_written_bytes[chunk_idx].load(Ordering::Acquire) >= needed_end {
            return Ok(());
        }

        // Trigger fetch of current chunk
        self.trigger_chunk_fetch(chunk_idx);

        // Slow path: park thread on Condvar until the requested slice arrives
        let mut guard = self.cache.sync_mutex.lock();
        while self.cache.chunk_written_bytes[chunk_idx].load(Ordering::Acquire) < needed_end {
            if self.cache.active_generation.load(Ordering::Relaxed) != self.generation {
                return Err(io::Error::new(io::ErrorKind::Interrupted, "Track skipped"));
            }
            if self.cache.chunk_failed[chunk_idx].load(Ordering::Relaxed) {
                return Err(io::Error::other("Network fetch failed after retries"));
            }
            self.cache.data_arrived.wait(&mut guard);
        }

        Ok(())
    }
}

impl Read for CloudMediaSource {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.position >= self.cache.total_size || buf.is_empty() {
            return Ok(0); // EOF
        }

        let chunk_idx = (self.position / CHUNK_SIZE) as usize;
        let chunk_offset = (self.position % CHUNK_SIZE) as u32;
        let chunk_total_len = ((self.cache.total_size - (chunk_idx as u64 * CHUNK_SIZE)).min(CHUNK_SIZE)) as u32;

        let max_readable_in_chunk = (chunk_total_len - chunk_offset) as usize;
        let to_read = buf.len().min(max_readable_in_chunk);
        let needed_end = chunk_offset + (to_read as u32);

        self.ensure_bytes_available(chunk_idx, needed_end)?;

        // Positional zero-seek read directly from unified kernel page cache
        let bytes_read = self.cache.file.read_at(&mut buf[..to_read], self.position)?;
        self.position += bytes_read as u64;

        // Proactive N+1 chunk prefetch when decode cursor crosses 50% of the active chunk
        if chunk_offset > (CHUNK_SIZE as u32 / 2)
            && chunk_idx + 1 < self.cache.chunk_written_bytes.len()
            && self.cache.chunk_written_bytes[chunk_idx + 1].load(Ordering::Relaxed) == 0
        {
            self.trigger_chunk_fetch(chunk_idx + 1);
        }

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

        self.position = cmp::min(new_pos as u64, self.cache.total_size);
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
        self.cache.active_generation.fetch_add(1, Ordering::SeqCst);
        self.cache.data_arrived.notify_all();
    }
}

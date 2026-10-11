use crate::cloud::range_fetcher::RangeFetcher;
use std::cmp;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use std::fs::{self, File};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::PathBuf;
use symphonia::core::io::MediaSource;

const CHUNK_SIZE: u64 = 2 * 1024 * 1024; // 2 MB chunks

/// How many byte-range fetches are in flight right now.
///
/// `Read` blocks while a chunk is downloading, which starves the decoder and
/// then the audio callback. The engine watches this so the UI can say
/// "buffering" instead of just going quiet.
pub static FETCHES_IN_FLIGHT: AtomicUsize = AtomicUsize::new(0);

/// Total bytes pulled from the network this session, for diagnostics.
pub static BYTES_FETCHED: AtomicUsize = AtomicUsize::new(0);

/// Which chunks of the track being played are already on disk.
///
/// The seek bar draws these, and the scrub bubble uses them to say whether a
/// position will play instantly or have to stream. Holds (file_id, total
/// bytes, chunk indices).
pub static CACHED: Mutex<Option<(String, u64, Vec<u64>)>> = Mutex::new(None);

/// Byte ranges of the current track that are cached, merged and in order.
pub fn cached_byte_ranges() -> (u64, Vec<(u64, u64)>) {
    let guard = match CACHED.lock() {
        Ok(g) => g,
        Err(_) => return (0, Vec::new()),
    };
    let Some((_, total, chunks)) = guard.as_ref() else {
        return (0, Vec::new());
    };

    let mut sorted = chunks.clone();
    sorted.sort_unstable();

    let mut out: Vec<(u64, u64)> = Vec::new();
    for idx in sorted {
        let start = idx * CHUNK_SIZE;
        let end = cmp::min(start + CHUNK_SIZE, *total);
        match out.last_mut() {
            // Adjacent chunks read as one range, which is what the user sees.
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

pub struct CloudMediaSource {
    file_id: String,
    url: String,
    auth_token: Option<String>,
    total_size: u64,
    position: u64,
    cache_dir: PathBuf,
    fetcher: RangeFetcher,
    rt: tokio::runtime::Runtime,
}

impl CloudMediaSource {
    pub fn new(
        file_id: String,
        url: String,
        auth_token: Option<String>,
        total_size: u64,
        cache_dir: PathBuf,
    ) -> anyhow::Result<Self> {
        fs::create_dir_all(&cache_dir)?;
        let fetcher = RangeFetcher::new()?;
        // We use a dedicated single-threaded runtime to block on async tasks within the sync Read/Seek traits
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;

        // Re-opening a track the user played before should show its cache
        // immediately, not look empty until something is fetched again.
        {
            let mut existing = Vec::new();
            let chunk_count = total_size.div_ceil(CHUNK_SIZE);
            for i in 0..chunk_count {
                if cache_dir.join(format!("{}_chunk_{}.dat", file_id, i)).exists() {
                    existing.push(i);
                }
            }
            if let Ok(mut guard) = CACHED.lock() {
                *guard = Some((file_id.clone(), total_size, existing));
            }
        }

        Ok(Self {
            file_id,
            url,
            auth_token,
            total_size,
            position: 0,
            cache_dir,
            fetcher,
            rt,
        })
    }

    fn get_chunk_path(&self, chunk_index: u64) -> PathBuf {
        self.cache_dir
            .join(format!("{}_chunk_{}.dat", self.file_id, chunk_index))
    }

    fn ensure_chunk(&self, chunk_index: u64) -> io::Result<()> {
        let chunk_path = self.get_chunk_path(chunk_index);
        if chunk_path.exists() {
            return Ok(()); // Already cached
        }

        let start_byte = chunk_index * CHUNK_SIZE;
        let end_byte = cmp::min(start_byte + CHUNK_SIZE - 1, self.total_size - 1);

        if start_byte >= self.total_size {
            return Ok(());
        }

        // Bridge sync Read trait to async RangeFetcher
        let url = self.url.clone();
        let token = self.auth_token.clone();
        FETCHES_IN_FLIGHT.fetch_add(1, Ordering::Relaxed);
        let fetch_result = self.rt.block_on(async {
            self.fetcher
                .fetch_range(&url, start_byte, end_byte, token.as_deref())
                .await
        });
        FETCHES_IN_FLIGHT.fetch_sub(1, Ordering::Relaxed);
        if let Ok((ref data, _)) = fetch_result {
            BYTES_FETCHED.fetch_add(data.len(), Ordering::Relaxed);
        }

        match fetch_result {
            Ok((data, _measurement)) => {
                let mut temp_path = chunk_path.clone();
                temp_path.set_extension("tmp");
                let mut file = File::create(&temp_path)?;
                file.write_all(&data)?;
                fs::rename(temp_path, chunk_path)?;
                if let Ok(mut guard) = CACHED.lock() {
                    if let Some((id, _, chunks)) = guard.as_mut() {
                        if *id == self.file_id && !chunks.contains(&chunk_index) {
                            chunks.push(chunk_index);
                        }
                    }
                }
                Ok(())
            }
            Err(e) => Err(io::Error::new(io::ErrorKind::Other, e.to_string())),
        }
    }
}

impl Read for CloudMediaSource {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.position >= self.total_size {
            return Ok(0); // EOF
        }

        let chunk_index = self.position / CHUNK_SIZE;
        let chunk_offset = self.position % CHUNK_SIZE;

        self.ensure_chunk(chunk_index)?;

        let chunk_path = self.get_chunk_path(chunk_index);
        let mut file = File::open(&chunk_path)?;
        file.seek(SeekFrom::Start(chunk_offset))?;

        // Limit read to the end of the current chunk
        let bytes_left_in_chunk = CHUNK_SIZE - chunk_offset;
        let max_read = cmp::min(buf.len() as u64, bytes_left_in_chunk) as usize;

        let bytes_read = file.read(&mut buf[..max_read])?;
        self.position += bytes_read as u64;

        Ok(bytes_read)
    }
}

impl Seek for CloudMediaSource {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        let new_pos = match pos {
            SeekFrom::Start(p) => p as i64,
            SeekFrom::End(p) => self.total_size as i64 + p,
            SeekFrom::Current(p) => self.position as i64 + p,
        };

        if new_pos < 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Seek before start of file",
            ));
        }

        self.position = cmp::min(new_pos as u64, self.total_size);
        Ok(self.position)
    }
}

impl MediaSource for CloudMediaSource {
    fn is_seekable(&self) -> bool {
        true
    }

    fn byte_len(&self) -> Option<u64> {
        Some(self.total_size)
    }
}

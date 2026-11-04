use super::*;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::AtomicBool;
use std::thread;
use std::time::{Duration, Instant};

static NEXT_DIR: AtomicU64 = AtomicU64::new(0);
struct TestDir(PathBuf);
impl TestDir {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "bitdrop-network-{}-{}",
            std::process::id(),
            NEXT_DIR.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}
impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

struct Server {
    url: String,
    stop: Arc<AtomicBool>,
    requests: Arc<Mutex<Vec<String>>>,
    worker: Option<thread::JoinHandle<()>>,
}
impl Server {
    fn new(reply: impl Fn(usize, &str, &mut TcpStream) + Send + 'static) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/track", listener.local_addr().unwrap());
        listener.set_nonblocking(true).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let requests = Arc::new(Mutex::new(Vec::new()));
        let stopping = stop.clone();
        let received = requests.clone();
        let worker = thread::spawn(move || {
            while !stopping.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((mut socket, _)) => {
                        socket
                            .set_read_timeout(Some(Duration::from_secs(2)))
                            .unwrap();
                        let mut request = Vec::new();
                        let mut byte = [0];
                        while !request.ends_with(b"\r\n\r\n") {
                            if socket.read(&mut byte).unwrap_or(0) == 0 {
                                break;
                            }
                            request.push(byte[0]);
                        }
                        let request = String::from_utf8(request).unwrap();
                        let index = {
                            let mut requests = received.lock();
                            requests.push(request.clone());
                            requests.len() - 1
                        };
                        reply(index, &request, &mut socket);
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(2))
                    }
                    Err(e) => panic!("{e}"),
                }
            }
        });
        Self {
            url,
            stop,
            requests,
            worker: Some(worker),
        }
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        self.worker.take().unwrap().join().unwrap();
    }
}

fn cache(dir: &TestDir, server: &Server, size: u64) -> Arc<SparseTrackCache> {
    let db = Arc::new(Mutex::new(
        crate::cloud::db::MetadataDb::new_in_memory().unwrap(),
    ));
    let cache = SparseTrackCache::new_with_db(
        "track",
        &dir.0.join("track.sparse"),
        &dir.0.join("track.idx"),
        size,
        Some(db),
    )
    .unwrap();
    cache.set_fetch_context(FetchContext {
        url: server.url.clone(),
        auth_token: None,
        index_path: dir.0.join("track.idx"),
    });
    cache
}
fn wait_until(mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(6);
    while !condition() {
        assert!(
            Instant::now() < deadline,
            "Timed out waiting for cache state"
        );
        thread::sleep(Duration::from_millis(2));
    }
}

#[test]
fn range_retries_resume_after_published_bytes() {
    let dir = TestDir::new();
    let server = Server::new(|index, request, socket| {
        if index == 0 {
            assert!(request.to_lowercase().contains("range: bytes=0-7"));
            socket.write_all(b"HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-7/8\r\nContent-Length: 8\r\nConnection: close\r\n\r\nabcd").unwrap();
        } else {
            assert!(request.to_lowercase().contains("range: bytes=4-7"));
            socket.write_all(b"HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 4-7/8\r\nContent-Length: 4\r\nConnection: close\r\n\r\nefgh").unwrap();
        }
    });
    let cache = cache(&dir, &server, 8);
    cache.trigger_chunk_fetch(0);
    wait_until(|| cache.chunk_states[0].load(Ordering::Acquire) == ChunkState::Ready as u8);
    let mut bytes = [0; 8];
    read_exact_at(&cache.file, &mut bytes, 0).unwrap();
    assert_eq!(&bytes, b"abcdefgh");
    assert_eq!(server.requests.lock().len(), 2);
    assert_eq!(
        cache.get_chunks_for_file("track")[0].crc32,
        crc32fast::hash(&bytes)
    );
}

#[test]
fn full_file_responses_are_rejected_and_failures_stop_retrying() {
    let dir = TestDir::new();
    let server = Server::new(|_, _, socket| {
        socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 16\r\nConnection: close\r\n\r\nabcdefghijklmnop").unwrap();
    });
    let cache = cache(&dir, &server, 8);
    cache.trigger_chunk_fetch(0);
    wait_until(|| cache.chunk_states[0].load(Ordering::Acquire) == ChunkState::Failed as u8);
    assert_eq!(cache.chunk_written_bytes[0].load(Ordering::Acquire), 0);
    assert_eq!(cache.file.metadata().unwrap().len(), 8);
    for _ in 0..20 {
        cache.schedule_read_ahead();
        cache.trigger_chunk_fetch(0);
    }
    thread::sleep(Duration::from_millis(250));
    assert_eq!(server.requests.lock().len(), 4);
    assert!(cache.get_chunks_for_file("track").is_empty());
}

#[test]
fn wrong_range_never_publishes_bytes() {
    let dir = TestDir::new();
    let server = Server::new(|_, _, socket| {
        socket.write_all(b"HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 1-8/9\r\nContent-Length: 8\r\nConnection: close\r\n\r\nabcdefgh").unwrap();
    });
    let cache = cache(&dir, &server, 8);
    cache.trigger_chunk_fetch(0);
    wait_until(|| cache.chunk_states[0].load(Ordering::Acquire) == ChunkState::Failed as u8);
    assert_eq!(cache.chunk_written_bytes[0].load(Ordering::Acquire), 0);
}

#[test]
fn cancellation_interrupts_an_http_request_before_its_body_arrives() {
    let dir = TestDir::new();
    let release = Arc::new(AtomicBool::new(false));
    let released = release.clone();
    let server = Server::new(move |_, _, socket| {
        socket.write_all(b"HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-7/8\r\nContent-Length: 8\r\n\r\n").unwrap();
        while !released.load(Ordering::Acquire) {
            thread::sleep(Duration::from_millis(2));
        }
    });
    let cache = cache(&dir, &server, 8);
    cache.trigger_chunk_fetch(0);
    wait_until(|| !server.requests.lock().is_empty());
    let start = Instant::now();
    cache.cancel_fetches();
    wait_until(|| cache.chunk_states[0].load(Ordering::Acquire) == ChunkState::Idle as u8);
    release.store(true, Ordering::Release);
    assert!(start.elapsed() < Duration::from_secs(1));
    assert_eq!(cache.chunk_written_bytes[0].load(Ordering::Acquire), 0);
}

#[test]
fn positional_io_handles_short_writes_and_interruptions() {
    struct ShortWriter(Mutex<Vec<u8>>, AtomicBool);
    impl PositionalIo for ShortWriter {
        fn read_at(&self, _: &mut [u8], _: u64) -> io::Result<usize> {
            unreachable!()
        }
        fn write_at(&self, bytes: &[u8], offset: u64) -> io::Result<usize> {
            if !self.1.swap(true, Ordering::Relaxed) {
                return Err(io::ErrorKind::Interrupted.into());
            }
            let count = bytes.len().min(2);
            self.0.lock()[offset as usize..offset as usize + count]
                .copy_from_slice(&bytes[..count]);
            Ok(count)
        }
    }
    let file = ShortWriter(Mutex::new(vec![0; 8]), AtomicBool::new(false));
    write_all_at(&file, b"abcdefgh", 0).unwrap();
    assert_eq!(&*file.0.lock(), b"abcdefgh");
}

#[test]
fn publication_and_cancellation_wake_blocked_readers() {
    let dir = TestDir::new();
    let cache = SparseTrackCache::new_with_db(
        "wait",
        &dir.0.join("wait.sparse"),
        &dir.0.join("wait.idx"),
        8,
        Some(Arc::new(Mutex::new(
            crate::cloud::db::MetadataDb::new_in_memory().unwrap(),
        ))),
    )
    .unwrap();
    cache.readers.store(1, Ordering::Relaxed);
    let source = CloudMediaSource {
        file_id: "wait".into(),
        position: 0,
        generation: 1,
        cache: cache.clone(),
    };
    let (tx, rx) = std::sync::mpsc::channel();
    let reader = thread::spawn(move || {
        tx.send(source.ensure_bytes_available(0, 8)).unwrap();
    });
    cache.publish_bytes(0, 8);
    assert!(rx.recv_timeout(Duration::from_secs(1)).unwrap().is_ok());
    reader.join().unwrap();

    cache.chunk_written_bytes[0].store(0, Ordering::Release);
    cache.readers.store(1, Ordering::Relaxed);
    let source = CloudMediaSource {
        file_id: "wait".into(),
        position: 0,
        generation: cache.active_generation.load(Ordering::Acquire),
        cache: cache.clone(),
    };
    let (tx, rx) = std::sync::mpsc::channel();
    thread::spawn(move || {
        tx.send(source.ensure_bytes_available(0, 8)).unwrap();
    });
    cache.cancel_fetches();
    assert_eq!(
        rx.recv_timeout(Duration::from_secs(1))
            .unwrap()
            .unwrap_err()
            .kind(),
        io::ErrorKind::Interrupted
    );
}

#[test]
fn preloads_share_a_writer_without_cancelling_current_playback() {
    let dir = TestDir::new();
    let first = CloudMediaSource::new(
        "first".into(),
        "http://127.0.0.1:1/track".into(),
        None,
        8,
        dir.0.clone(),
    )
    .unwrap();
    set_active_cache(Some(first.cache()));
    let second = CloudMediaSource::new(
        "second".into(),
        "http://127.0.0.1:1/track".into(),
        None,
        8,
        dir.0.clone(),
    )
    .unwrap();
    let shared = CloudMediaSource::new(
        "first".into(),
        "http://127.0.0.1:1/track".into(),
        None,
        8,
        dir.0.clone(),
    )
    .unwrap();
    assert!(Arc::ptr_eq(first.cache(), shared.cache()));
    drop(shared);
    drop(second);
    assert_eq!(
        first.cache.active_generation.load(Ordering::Acquire),
        first.generation
    );
}

#[test]
fn automatic_eviction_completes_without_relocking_telemetry() {
    let dir = TestDir::new();
    let server = Server::new(|_, _, socket| {
        socket.write_all(b"HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-7/8\r\nContent-Length: 8\r\nConnection: close\r\n\r\nabcdefgh").unwrap();
    });
    let cache = cache(&dir, &server, 8);
    let old = crate::cloud::db::CachedChunkRecord {
        file_id: "evict-me".into(),
        chunk_idx: 0,
        byte_offset: 0,
        byte_len: 3 * 1024 * 1024 * 1024,
        crc32: 0,
        file_mtime: 0,
        last_accessed_ts: 0,
    };
    cache
        .db
        .as_ref()
        .unwrap()
        .lock()
        .record_cached_chunk(&old)
        .unwrap();
    CACHED
        .lock()
        .insert("evict-me".into(), (old.byte_len as u64, vec![0]));
    cache.trigger_chunk_fetch(0);
    wait_until(|| cache.chunk_states[0].load(Ordering::Acquire) == ChunkState::Ready as u8);
    assert!(cache.get_chunks_for_file("evict-me").is_empty());
    assert!(CACHED.lock().get("evict-me").unwrap().1.is_empty());
}

#[test]
fn a_large_seek_keeps_another_shared_reader_usable() {
    let dir = TestDir::new();
    let cache = SparseTrackCache::new_with_db(
        "shared-seek",
        &dir.0.join("shared.sparse"),
        &dir.0.join("shared.idx"),
        5 * CHUNK_SIZE,
        Some(Arc::new(Mutex::new(
            crate::cloud::db::MetadataDb::new_in_memory().unwrap(),
        ))),
    )
    .unwrap();
    cache.readers.store(2, Ordering::Release);
    write_all_at(&cache.file, b"audio", 0).unwrap();
    cache.publish_bytes(0, 5);
    let mut playing = CloudMediaSource {
        file_id: "shared-seek".into(),
        position: 0,
        generation: 1,
        cache: cache.clone(),
    };
    let mut probe = CloudMediaSource {
        file_id: "shared-seek".into(),
        position: 0,
        generation: 1,
        cache: cache.clone(),
    };
    probe.seek(SeekFrom::Start(4 * CHUNK_SIZE)).unwrap();
    let mut bytes = [0; 5];
    playing.read_exact(&mut bytes).unwrap();
    assert_eq!(&bytes, b"audio");
    assert_eq!(playing.position, 5);

    // An explicit cancellation is reported once, then subsequent reads can recover.
    cache.cancel_fetches();
    playing.position = 0;
    assert_eq!(
        playing.read(&mut bytes).unwrap_err().kind(),
        io::ErrorKind::Interrupted
    );
    playing.read_exact(&mut bytes).unwrap();
    assert_eq!(&bytes, b"audio");
}

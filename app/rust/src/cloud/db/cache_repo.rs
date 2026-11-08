use crate::cloud::db::{CacheStatsRecord, CachedChunkRecord, EvictedChunk};
use rusqlite::{params, Connection, Result};

/// Repository for sparse audio chunk cache, CRC32 verification, and LRU eviction.
pub struct CacheRepository<'a> {
    pub conn: &'a Connection,
}

impl<'a> CacheRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// Records or updates a cached chunk with verified CRC32 checksum.
    pub fn record_cached_chunk(&self, chunk: &CachedChunkRecord) -> Result<()> {
        self.conn.execute(
            "INSERT OR REPLACE INTO cached_chunks (
                file_id, chunk_idx, byte_offset, byte_len, crc32, file_mtime, last_accessed_ts
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                chunk.file_id,
                chunk.chunk_idx,
                chunk.byte_offset as i64,
                chunk.byte_len as i64,
                chunk.crc32 as i64,
                chunk.file_mtime,
                chunk.last_accessed_ts,
            ],
        )?;
        Ok(())
    }

    /// Fetches all cached chunk records for a given file_id.
    pub fn get_cached_chunks(&self, file_id: &str) -> Result<Vec<CachedChunkRecord>> {
        let mut stmt = self.conn.prepare(
            "SELECT file_id, chunk_idx, byte_offset, byte_len, crc32, file_mtime, last_accessed_ts
             FROM cached_chunks WHERE file_id = ?1 ORDER BY chunk_idx ASC",
        )?;
        let rows = stmt.query_map(params![file_id], |r| {
            Ok(CachedChunkRecord {
                file_id: r.get(0)?,
                chunk_idx: r.get::<_, u32>(1)?,
                byte_offset: r.get::<_, i64>(2)? as u64,
                byte_len: r.get::<_, i64>(3)? as u32,
                crc32: r.get::<_, i64>(4)? as u32,
                file_mtime: r.get(5)?,
                last_accessed_ts: r.get(6)?,
            })
        })?;
        let mut list = Vec::new();
        for r in rows {
            list.push(r?);
        }
        Ok(list)
    }

    /// Fetches a specific cached chunk record.
    pub fn get_cached_chunk(
        &self,
        file_id: &str,
        chunk_idx: u32,
    ) -> Result<Option<CachedChunkRecord>> {
        let mut stmt = self.conn.prepare(
            "SELECT file_id, chunk_idx, byte_offset, byte_len, crc32, file_mtime, last_accessed_ts
             FROM cached_chunks WHERE file_id = ?1 AND chunk_idx = ?2",
        )?;
        let mut rows = stmt.query_map(params![file_id, chunk_idx], |r| {
            Ok(CachedChunkRecord {
                file_id: r.get(0)?,
                chunk_idx: r.get::<_, u32>(1)?,
                byte_offset: r.get::<_, i64>(2)? as u64,
                byte_len: r.get::<_, i64>(3)? as u32,
                crc32: r.get::<_, i64>(4)? as u32,
                file_mtime: r.get(5)?,
                last_accessed_ts: r.get(6)?,
            })
        })?;
        if let Some(r) = rows.next() {
            Ok(Some(r?))
        } else {
            Ok(None)
        }
    }

    /// Deletes a specific cached chunk record (e.g. after CRC32 mismatch or truncation).
    pub fn delete_cached_chunk(&self, file_id: &str, chunk_idx: u32) -> Result<()> {
        self.conn.execute(
            "DELETE FROM cached_chunks WHERE file_id = ?1 AND chunk_idx = ?2",
            params![file_id, chunk_idx],
        )?;
        Ok(())
    }

    /// Deletes all cached chunk records for a file.
    pub fn delete_all_cached_chunks(&self, file_id: &str) -> Result<()> {
        self.conn.execute(
            "DELETE FROM cached_chunks WHERE file_id = ?1",
            params![file_id],
        )?;
        Ok(())
    }

    /// Updates last_accessed_ts for a chunk.
    pub fn touch_chunk_access(&self, file_id: &str, chunk_idx: u32, now_ts: i64) -> Result<()> {
        self.conn.execute(
            "UPDATE cached_chunks SET last_accessed_ts = ?1 WHERE file_id = ?2 AND chunk_idx = ?3",
            params![now_ts, file_id, chunk_idx],
        )?;
        Ok(())
    }

    /// Updates last_accessed_ts for all chunks of a file.
    pub fn touch_file_access(&self, file_id: &str, now_ts: i64) -> Result<()> {
        self.conn.execute(
            "UPDATE cached_chunks SET last_accessed_ts = ?1 WHERE file_id = ?2",
            params![now_ts, file_id],
        )?;
        Ok(())
    }

    /// Returns the total bytes across all cached chunks.
    pub fn total_cached_bytes(&self) -> Result<u64> {
        let total: Option<i64> =
            self.conn
                .query_row("SELECT SUM(byte_len) FROM cached_chunks", [], |r| r.get(0))?;
        Ok(total.unwrap_or(0).max(0) as u64)
    }

    /// Syncs pinned track file_ids in SQLite atomically.
    pub fn sync_pinned_tracks(&mut self, pinned_ids: &[String]) -> Result<()> {
        let tx = self.conn.unchecked_transaction()?;
        tx.execute("DELETE FROM pinned_tracks", [])?;
        {
            let mut stmt =
                tx.prepare_cached("INSERT OR IGNORE INTO pinned_tracks (file_id) VALUES (?1)")?;
            for id in pinned_ids {
                stmt.execute(params![id])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// Checks if a file is marked pinned in SQLite.
    pub fn is_track_pinned(&self, file_id: &str) -> Result<bool> {
        let count: u32 = self.conn.query_row(
            "SELECT COUNT(*) FROM pinned_tracks WHERE file_id = ?1",
            params![file_id],
            |r| r.get(0),
        )?;
        Ok(count > 0)
    }

    /// Returns all pinned file_ids.
    pub fn get_pinned_tracks(&self) -> Result<Vec<String>> {
        let mut stmt = self.conn.prepare("SELECT file_id FROM pinned_tracks")?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
        rows.collect()
    }

    /// Returns the number of cached chunks for a given file_id.
    pub fn count_cached_chunks_for_file(&self, file_id: &str) -> Result<u32> {
        let count: u32 = self.conn.query_row(
            "SELECT COUNT(*) FROM cached_chunks WHERE file_id = ?1",
            params![file_id],
            |r| r.get(0),
        )?;
        Ok(count)
    }

    /// Aggregates total, pinned, and unpinned cache bytes.
    pub fn get_cache_stats(&self, extra_pinned_ids: &[String]) -> Result<CacheStatsRecord> {
        let mut pinned_set: std::collections::HashSet<String> =
            self.get_pinned_tracks()?.into_iter().collect();
        for id in extra_pinned_ids {
            pinned_set.insert(id.clone());
        }

        let mut stmt = self.conn.prepare(
            "SELECT file_id, SUM(byte_len), COUNT(*) FROM cached_chunks GROUP BY file_id",
        )?;

        let mut total_bytes = 0u64;
        let mut pinned_bytes = 0u64;
        let mut unpinned_bytes = 0u64;
        let mut chunk_count = 0u32;

        let rows = stmt.query_map([], |r| {
            let file_id: String = r.get(0)?;
            let bytes: i64 = r.get(1)?;
            let count: u32 = r.get(2)?;
            Ok((file_id, bytes.max(0) as u64, count))
        })?;

        for row in rows {
            let (file_id, bytes, count) = row?;
            total_bytes += bytes;
            chunk_count += count;
            if pinned_set.contains(&file_id) {
                pinned_bytes += bytes;
            } else {
                unpinned_bytes += bytes;
            }
        }

        Ok(CacheStatsRecord {
            total_bytes,
            pinned_bytes,
            unpinned_bytes,
            chunk_count,
        })
    }

    /// Prunes least-recently-accessed unpinned chunks until unpinned bytes are at or below `limit_bytes`.
    /// Pinned tracks and the active_file_id are 100% protected and NEVER evicted.
    pub fn prune_lru_chunks(
        &mut self,
        limit_bytes: u64,
        extra_pinned_ids: &[String],
        active_file_id: Option<&str>,
    ) -> Result<Vec<EvictedChunk>> {
        let stats = self.get_cache_stats(extra_pinned_ids)?;
        if stats.unpinned_bytes <= limit_bytes {
            return Ok(Vec::new());
        }

        let mut pinned_set: std::collections::HashSet<String> =
            self.get_pinned_tracks()?.into_iter().collect();
        for id in extra_pinned_ids {
            pinned_set.insert(id.clone());
        }

        let excess = stats.unpinned_bytes - limit_bytes;
        let cushion = (limit_bytes / 10).min(50 * 1024 * 1024);
        let target_to_free = excess.saturating_add(cushion);

        let mut to_evict = Vec::new();
        {
            let mut stmt = self.conn.prepare(
                "SELECT file_id, chunk_idx, byte_offset, byte_len
                 FROM cached_chunks
                 ORDER BY last_accessed_ts ASC",
            )?;

            let mut freed = 0u64;

            let rows = stmt.query_map([], |r| {
                Ok(EvictedChunk {
                    file_id: r.get(0)?,
                    chunk_idx: r.get(1)?,
                    byte_offset: r.get::<_, i64>(2)? as u64,
                    byte_len: r.get::<_, i64>(3)? as u32,
                })
            })?;

            for item in rows {
                let chunk = item?;
                if pinned_set.contains(&chunk.file_id) {
                    continue;
                }
                if let Some(active) = active_file_id {
                    if chunk.file_id == active {
                        continue;
                    }
                }

                freed += chunk.byte_len as u64;
                to_evict.push(chunk);

                if freed >= target_to_free {
                    break;
                }
            }
        }

        if !to_evict.is_empty() {
            let tx = self.conn.unchecked_transaction()?;
            {
                let mut del_stmt = tx.prepare_cached(
                    "DELETE FROM cached_chunks WHERE file_id = ?1 AND chunk_idx = ?2",
                )?;
                for chunk in &to_evict {
                    del_stmt.execute(params![&chunk.file_id, chunk.chunk_idx])?;
                }
            }
            tx.commit()?;
        }

        Ok(to_evict)
    }

    pub fn clear_cache_tables(&self) -> Result<()> {
        self.conn.execute("DELETE FROM cached_chunks", [])?;
        self.conn.execute("DELETE FROM pinned_tracks", [])?;
        Ok(())
    }
}

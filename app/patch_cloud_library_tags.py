import re

with open("rust/src/api/cloud_library.rs", "r") as f:
    content = f.read()

pattern = re.compile(r"pub fn cloud_library_read_tags\(.*?Ok\(false\)\n\}", re.DOTALL)

replacement = """pub fn cloud_library_read_tags(
    file_id: String,
    url: String,
    auth_token: Option<String>,
) -> Result<bool, String> {
    use crate::cloud::media_source::CloudMediaSource;
    use symphonia::core::probe::Hint;
    use symphonia::core::io::MediaSourceStream;
    use symphonia::core::meta::MetadataOptions;
    use symphonia::core::formats::FormatOptions;
    use std::path::PathBuf;

    let size_bytes = with_db(|db| {
        let mut stmt = db.conn.prepare("SELECT size_bytes FROM tracks WHERE file_id = ?")?;
        let size: u64 = stmt.query_row([&file_id], |r| r.get(0)).unwrap_or(0);
        Ok(size)
    }).map_err(|e: anyhow::Error| e.to_string())?;

    if size_bytes == 0 {
        return Ok(false);
    }

    let cache_dir = std::env::temp_dir().join("bitdrop_tag_cache");
    let cloud_source = match CloudMediaSource::new(file_id.clone(), url, auth_token, size_bytes, cache_dir) {
        Ok(cs) => cs,
        Err(_) => return Ok(false),
    };

    let mss = MediaSourceStream::new(Box::new(cloud_source), Default::default());
    let hint = Hint::new();

    let meta_opts: MetadataOptions = Default::default();
    let fmt_opts: FormatOptions = Default::default();

    let probed = match symphonia::default::get_probe().format(&hint, mss, &fmt_opts, &meta_opts) {
        Ok(p) => p,
        Err(_) => {
            let _ = with_db(|db| {
                db.mark_tags_attempted(&file_id)?;
                Ok(())
            });
            return Ok(false);
        }
    };

    let mut format = probed.format;
    
    // Extract metadata
    let mut duration_ms = 0;
    let mut sample_rate = 44100;
    let mut channels = 2;
    let mut bits_per_sample = 16;
    
    if let Some(track) = format.default_track() {
        if let Some(tb) = track.codec_params.time_base {
            if let Some(n_frames) = track.codec_params.n_frames {
                let time = tb.calc_time(n_frames);
                duration_ms = (time.seconds * 1000 + (time.frac * 1000.0) as u64) as u32;
            }
        }
        sample_rate = track.codec_params.sample_rate.unwrap_or(44100);
        channels = track.codec_params.channels.map(|c| c.count() as u8).unwrap_or(2);
        bits_per_sample = track.codec_params.bits_per_sample.unwrap_or(16) as u8;
    }

    let mut title = String::new();
    let mut artist = String::new();
    let mut album = String::new();
    let mut album_artist = String::new();
    let mut genre = String::new();
    let mut year = String::new();
    let mut track_number = String::new();
    let mut disc_number = String::new();

    if let Some(metadata) = format.metadata().current() {
        for tag in metadata.tags() {
            match tag.std_key {
                Some(symphonia::core::meta::StandardTagKey::TrackTitle) => title = tag.value.to_string(),
                Some(symphonia::core::meta::StandardTagKey::Artist) => artist = tag.value.to_string(),
                Some(symphonia::core::meta::StandardTagKey::Album) => album = tag.value.to_string(),
                Some(symphonia::core::meta::StandardTagKey::AlbumArtist) => album_artist = tag.value.to_string(),
                Some(symphonia::core::meta::StandardTagKey::Genre) => genre = tag.value.to_string(),
                Some(symphonia::core::meta::StandardTagKey::Date) => year = tag.value.to_string(),
                Some(symphonia::core::meta::StandardTagKey::TrackNumber) => track_number = tag.value.to_string(),
                Some(symphonia::core::meta::StandardTagKey::DiscNumber) => disc_number = tag.value.to_string(),
                _ => {}
            }
        }
    }

    let _ = with_db(|db| {
        db.conn.execute(
            "UPDATE tracks SET
                title = ?, artist = ?, album = ?, album_artist = ?,
                genre = ?, year = ?, track_number = ?, disc_number = ?,
                duration_ms = ?, sample_rate = ?, channels = ?, bits_per_sample = ?,
                tags_read = 1
             WHERE file_id = ?",
            rusqlite::params![
                title, artist, album, album_artist, genre, year, track_number, disc_number,
                duration_ms, sample_rate, channels, bits_per_sample,
                file_id
            ],
        )?;
        Ok(())
    });

    Ok(true)
}"""

content = pattern.sub(replacement, content)

with open("rust/src/api/cloud_library.rs", "w") as f:
    f.write(content)

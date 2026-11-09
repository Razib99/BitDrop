//! Time-synced lyrics parser and LRCLIB online fallback client.
//!
//! Supports standard LRC timestamp formats (`[mm:ss.xx]`, `[mm:ss.xxx]`, multi-timestamp lines),
//! metadata header stripping (`[ar:]`, `[ti:]`, `[offset:]`), and fallback to unsynced plain text.

use serde::{Deserialize, Serialize};
use std::time::Duration;

/// A single timestamped lyric line.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LyricLine {
    /// Timestamp in milliseconds from the start of the audio file.
    pub timestamp_ms: u64,
    /// The lyric text for this line.
    pub text: String,
}

/// Parsed lyrics for a track, supporting both synchronized and plain formats.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TrackLyrics {
    /// True if lyrics have millisecond-accurate synchronized timestamps.
    pub synced: bool,
    /// Ordered list of lyric lines. If `synced` is false, each line has `timestamp_ms = 0`.
    pub lines: Vec<LyricLine>,
    /// Full plain-text representation (useful for clipboard copy or search).
    pub plain_lyrics: String,
    /// Origin source: "embedded", "lrclib", "manual", "lrc", or "none" (negative cache).
    pub source: String,
}

/// Detailed lyrics payload representing parsed synced lines and/or plain text.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LyricsPayload {
    pub synced_lines: Vec<LyricLine>,
    pub plain_text: Option<String>,
    pub source: String,
}

impl From<LyricsPayload> for TrackLyrics {
    fn from(p: LyricsPayload) -> Self {
        let synced = !p.synced_lines.is_empty();
        let plain = p.plain_text.clone().unwrap_or_else(|| {
            p.synced_lines
                .iter()
                .map(|l| l.text.as_str())
                .collect::<Vec<_>>()
                .join("\n")
        });
        Self {
            synced,
            lines: p.synced_lines,
            plain_lyrics: plain,
            source: p.source,
        }
    }
}

impl From<TrackLyrics> for LyricsPayload {
    fn from(t: TrackLyrics) -> Self {
        Self {
            synced_lines: if t.synced { t.lines } else { Vec::new() },
            plain_text: if t.plain_lyrics.is_empty() {
                None
            } else {
                Some(t.plain_lyrics)
            },
            source: t.source,
        }
    }
}

/// Serializes structured lyric lines into standard LRC text format.
pub fn format_lrc(lyrics: &TrackLyrics) -> String {
    if !lyrics.synced {
        return lyrics.plain_lyrics.clone();
    }
    let mut out = String::new();
    for line in &lyrics.lines {
        let total_ms = line.timestamp_ms;
        let total_sec = total_ms / 1000;
        let mins = total_sec / 60;
        let secs = total_sec % 60;
        let hundredths = (total_ms % 1000) / 10;
        out.push_str(&format!(
            "[{:02}:{:02}.{:02}]{}\n",
            mins, secs, hundredths, line.text
        ));
    }
    out
}

/// Parses raw text into `LyricsPayload` with an explicit source tag.
pub fn parse_lrc_payload(raw: &str, source: &str) -> LyricsPayload {
    let mut lyrics = parse_lrc(raw);
    lyrics.source = source.to_string();
    lyrics.into()
}

/// Parses an LRC formatted string (or raw unsynced lyrics) into structured `TrackLyrics`.
pub fn parse_lrc(raw: &str) -> TrackLyrics {
    let mut parsed_lines = Vec::new();
    let mut offset_ms: i64 = 0;

    for line in raw.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        // Check for [offset:+/-ms] tag
        if let Some(rest) = trimmed.strip_prefix("[offset:") {
            if let Some(end) = rest.find(']') {
                if let Ok(val) = rest[..end].trim().parse::<i64>() {
                    offset_ms = val;
                }
            }
            continue;
        }

        // Check and ignore other standard metadata tags like [ar:Artist], [ti:Title], [al:Album]
        if trimmed.starts_with('[') {
            if let Some(colon_pos) = trimmed.find(':') {
                let tag_name = &trimmed[1..colon_pos].to_ascii_lowercase();
                if matches!(
                    tag_name.as_str(),
                    "ar" | "ti" | "al" | "by" | "length" | "re" | "ve" | "au"
                ) {
                    continue;
                }
            }
        }

        // Scan for timestamps at the start of the line: e.g. [01:23.45][01:25.00]Line text
        let mut cur = trimmed;
        let mut line_timestamps = Vec::new();

        while cur.starts_with('[') {
            if let Some(close_bracket) = cur.find(']') {
                let tag_content = &cur[1..close_bracket];
                if let Some(ts_ms) = parse_timestamp_ms(tag_content) {
                    line_timestamps.push(ts_ms);
                    cur = cur[close_bracket + 1..].trim_start();
                } else {
                    // Not a timestamp tag, treat as part of lyric line or metadata
                    break;
                }
            } else {
                break;
            }
        }

        let lyric_text = cur.trim();
        if !line_timestamps.is_empty() {
            for ts in line_timestamps {
                // Apply [offset:ms] if present, clamping at 0
                let adjusted = if offset_ms < 0 {
                    ts.saturating_sub((-offset_ms) as u64)
                } else {
                    ts.saturating_add(offset_ms as u64)
                };
                parsed_lines.push(LyricLine {
                    timestamp_ms: adjusted,
                    text: lyric_text.to_string(),
                });
            }
        }
    }

    if !parsed_lines.is_empty() {
        // Sort stably by timestamp
        parsed_lines.sort_by_key(|l| l.timestamp_ms);

        let mut plain = String::new();
        for (i, l) in parsed_lines.iter().enumerate() {
            if !l.text.is_empty() {
                if !plain.is_empty() {
                    plain.push('\n');
                }
                plain.push_str(&l.text);
            } else if i > 0 && i < parsed_lines.len() - 1 {
                // Keep empty lines between paragraphs
                plain.push('\n');
            }
        }

        TrackLyrics {
            synced: true,
            lines: parsed_lines,
            plain_lyrics: plain,
            source: "lrc".to_string(),
        }
    } else {
        // Unsynced plain-text fallback: split by line
        let lines: Vec<LyricLine> = raw
            .lines()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty())
            .map(|text| LyricLine {
                timestamp_ms: 0,
                text,
            })
            .collect();

        TrackLyrics {
            synced: false,
            lines,
            plain_lyrics: raw.trim().to_string(),
            source: "lrc".to_string(),
        }
    }
}

/// Helper parsing `mm:ss.xx` or `mm:ss.xxx` or `mm:ss` into milliseconds.
fn parse_timestamp_ms(content: &str) -> Option<u64> {
    let mut parts = content.split(':');
    let min_str = parts.next()?.trim();
    let sec_str = parts.next()?.trim();
    if parts.next().is_some() {
        return None;
    }

    let minutes: u64 = min_str.parse().ok()?;

    if let Some(dot_pos) = sec_str.find('.') {
        let sec: u64 = sec_str[..dot_pos].trim().parse().ok()?;
        let frac_str = sec_str[dot_pos + 1..].trim();
        let frac_ms: u64 = match frac_str.len() {
            0 => 0,
            1 => frac_str.parse::<u64>().ok()? * 100,
            2 => frac_str.parse::<u64>().ok()? * 10,
            3 => frac_str.parse::<u64>().ok()?,
            _ => frac_str[..3].parse::<u64>().ok()?, // Truncate microsecond digits
        };
        Some(minutes * 60_000 + sec * 1000 + frac_ms)
    } else {
        let sec: u64 = sec_str.parse().ok()?;
        Some(minutes * 60_000 + sec * 1000)
    }
}

#[derive(Deserialize)]
struct LrclibResponse {
    #[serde(rename = "syncedLyrics")]
    synced_lyrics: Option<String>,
    #[serde(rename = "plainLyrics")]
    plain_lyrics: Option<String>,
}

/// Fetches lyrics from LRCLIB (`https://lrclib.net/api/get`) with a 5-second timeout.
pub async fn fetch_lrclib(
    client: &reqwest::Client,
    artist: &str,
    title: &str,
    album: &str,
    duration_secs: u32,
) -> Result<Option<TrackLyrics>, anyhow::Error> {
    if artist.trim().is_empty() || title.trim().is_empty() {
        return Ok(None);
    }

    let mut req = client
        .get("https://lrclib.net/api/get")
        .query(&[("artist_name", artist), ("track_name", title)])
        .timeout(Duration::from_secs(5));

    if !album.trim().is_empty() {
        req = req.query(&[("album_name", album)]);
    }
    if duration_secs > 0 {
        req = req.query(&[("duration", &duration_secs.to_string())]);
    }

    let res = req.send().await?;
    if res.status() == reqwest::StatusCode::NOT_FOUND {
        return Ok(None);
    }
    if !res.status().is_success() {
        return Ok(None);
    }

    let data: LrclibResponse = res.json().await?;

    if let Some(synced) = data.synced_lyrics {
        if !synced.trim().is_empty() {
            let mut parsed = parse_lrc(&synced);
            parsed.source = "lrclib".to_string();
            if !parsed.lines.is_empty() {
                return Ok(Some(parsed));
            }
        }
    }

    if let Some(plain) = data.plain_lyrics {
        if !plain.trim().is_empty() {
            let mut parsed = parse_lrc(&plain);
            parsed.source = "lrclib".to_string();
            return Ok(Some(parsed));
        }
    }

    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_lrc_synced_hundredths() {
        let lrc = "\
[ar:Radiohead]
[ti:Karma Police]
[00:15.30]Karma police, arrest this man
[00:22.50]He talks in maths
[00:27.10]He buzzes like a fridge
";
        let parsed = parse_lrc(lrc);
        assert!(parsed.synced);
        assert_eq!(parsed.lines.len(), 3);
        assert_eq!(parsed.lines[0].timestamp_ms, 15_300);
        assert_eq!(parsed.lines[0].text, "Karma police, arrest this man");
        assert_eq!(parsed.lines[1].timestamp_ms, 22_500);
        assert_eq!(parsed.lines[1].text, "He talks in maths");
        assert_eq!(parsed.lines[2].timestamp_ms, 27_100);
        assert_eq!(parsed.lines[2].text, "He buzzes like a fridge");
    }

    #[test]
    fn test_parse_lrc_synced_thousandths() {
        let lrc = "\
[01:05.123]Line with millisecond resolution
[01:08.456]Next fast line
";
        let parsed = parse_lrc(lrc);
        assert!(parsed.synced);
        assert_eq!(parsed.lines.len(), 2);
        assert_eq!(parsed.lines[0].timestamp_ms, 65_123);
        assert_eq!(parsed.lines[0].text, "Line with millisecond resolution");
        assert_eq!(parsed.lines[1].timestamp_ms, 68_456);
        assert_eq!(parsed.lines[1].text, "Next fast line");
    }

    #[test]
    fn test_parse_lrc_multiple_timestamps_per_line() {
        let lrc = "[00:10.00][00:20.00]Chorus repeats here";
        let parsed = parse_lrc(lrc);
        assert!(parsed.synced);
        assert_eq!(parsed.lines.len(), 2);
        assert_eq!(parsed.lines[0].timestamp_ms, 10_000);
        assert_eq!(parsed.lines[0].text, "Chorus repeats here");
        assert_eq!(parsed.lines[1].timestamp_ms, 20_000);
        assert_eq!(parsed.lines[1].text, "Chorus repeats here");
    }

    #[test]
    fn test_parse_lrc_offset_tag() {
        let lrc = "\
[offset:500]
[00:10.00]Pushed forward by 500ms
";
        let parsed = parse_lrc(lrc);
        assert!(parsed.synced);
        assert_eq!(parsed.lines[0].timestamp_ms, 10_500);
    }

    #[test]
    fn test_parse_lrc_plain_fallback() {
        let raw = "\
First verse of a song without any time markers.
Second line continues the story.
Third line ends it.
";
        let parsed = parse_lrc(raw);
        assert!(!parsed.synced);
        assert_eq!(parsed.lines.len(), 3);
        assert_eq!(parsed.lines[0].timestamp_ms, 0);
        assert_eq!(
            parsed.lines[0].text,
            "First verse of a song without any time markers."
        );
        assert_eq!(parsed.plain_lyrics, raw.trim());
    }

    #[test]
    fn test_parse_lrc_payload_and_source() {
        let raw = "[00:05.50]Opening intro line\n[00:12.00]Second verse";
        let payload = parse_lrc_payload(raw, "embedded");
        assert_eq!(payload.source, "embedded");
        assert_eq!(payload.synced_lines.len(), 2);
        assert_eq!(payload.synced_lines[0].timestamp_ms, 5_500);

        let lyrics: TrackLyrics = payload.into();
        assert!(lyrics.synced);
        assert_eq!(lyrics.source, "embedded");

        let back: LyricsPayload = lyrics.into();
        assert_eq!(back.source, "embedded");
        assert_eq!(back.synced_lines.len(), 2);
    }

    #[test]
    fn test_format_lrc_roundtrip() {
        let lrc = "\
[00:15.30]Karma police, arrest this man
[00:22.50]He talks in maths
[00:27.10]He buzzes like a fridge
";
        let parsed = parse_lrc(lrc);
        let formatted = format_lrc(&parsed);
        let reparsed = parse_lrc(&formatted);
        assert_eq!(reparsed.lines, parsed.lines);
        assert!(reparsed.synced);
    }
}

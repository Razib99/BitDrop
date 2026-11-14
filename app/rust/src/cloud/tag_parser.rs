//! Multi-value genre and artist tag parser and casing normalizer.
//!
//! Complies with Phase 2 Directive Candidate E & Phase 2.5 Surgical Hardening:
//! - Separates `parse_genres()` from `parse_artists()`.
//! - In `parse_genres()`: Splits ONLY on explicit multi-value delimiters (`;`, `/`, `|`, `\0`).
//!   Never splits on `,` or `&` so compound genres like "Drum & Bass", "Rock & Roll",
//!   and "Rhythm & Blues" remain intact.
//! - In `parse_artists()`: Splits on explicit delimiters (`;`, `/`, `|`, `\0`), collaboration
//!   tokens (`feat.`, `ft.`, `featuring`, `with`, `vs.`), and un-protected commas and ampersands.
//!   Protects canonical compound artists ("Earth, Wind & Fire", "Simon & Garfunkel", "Hall & Oates",
//!   "Crosby, Stills, Nash & Young") and ", The " suffixes ("Tyler, The Creator").

/// List of canonical compound artist names containing commas or ampersands that must not be split.
pub const CANONICAL_COMPOUND_ARTISTS: &[&str] = &[
    "Earth, Wind & Fire",
    "Simon & Garfunkel",
    "Hall & Oates",
    "Daryl Hall & John Oates",
    "Crosby, Stills, Nash & Young",
    "Crosby, Stills & Nash",
    "Emerson, Lake & Palmer",
    "Blood, Sweat & Tears",
    "KC & The Sunshine Band",
    "KC and The Sunshine Band",
    "Kool & The Gang",
    "Huey Lewis & The News",
    "Bob Marley & The Wailers",
    "Joan Jett & The Blackhearts",
    "Tom Petty & The Heartbreakers",
    "Tom Petty and The Heartbreakers",
    "Florence + The Machine",
    "Gladys Knight & The Pips",
    "Sly & The Family Stone",
];

/// Normalizes whitespace and casing for a single tag string.
/// Preserves common uppercase musical abbreviations and acronyms.
pub fn normalize_tag_casing(tag: &str) -> String {
    let trimmed = tag.trim();
    if trimmed.is_empty() {
        return String::new();
    }

    const PRESERVED_ACRONYMS: &[&str] = &[
        "EDM", "IDM", "OST", "R&B", "BGM", "EP", "LP", "DJ", "MC", "VBR", "CBR", "DSD", "PCM",
        "UK", "US", "USA", "II", "III", "IV", "VI", "VII", "VIII", "IX", "X", "VIP",
    ];

    let mut words: Vec<String> = Vec::new();
    for word in trimmed.split_whitespace() {
        let upper = word.to_uppercase();
        if PRESERVED_ACRONYMS.contains(&upper.as_str()) {
            words.push(upper);
        } else {
            let mut chars = word.chars();
            if let Some(first) = chars.next() {
                let mut cap = first.to_uppercase().collect::<String>();
                cap.push_str(&chars.as_str().to_lowercase());
                words.push(cap);
            }
        }
    }
    words.join(" ")
}

/// Parses multi-value genre tags by splitting ONLY on explicit delimiters (`;`, `/`, `|`, `\0`).
///
/// Never splits on `&` or `,`, protecting compound genres like "Drum & Bass", "Rock & Roll",
/// and "Rhythm & Blues".
pub fn parse_genres(raw: &str) -> Vec<String> {
    let mut results: Vec<String> = Vec::new();
    for part in raw.split([';', '/', '|', '\0']) {
        let trimmed = part.trim();
        if !trimmed.is_empty() {
            let normalized = normalize_tag_casing(trimmed);
            if !normalized.is_empty()
                && !results.iter().any(|r| r.eq_ignore_ascii_case(&normalized))
            {
                results.push(normalized);
            }
        }
    }
    results
}

/// Backwards-compatible alias for genre tag parsing.
pub fn parse_multi_value_tag(raw: &str) -> Vec<String> {
    parse_genres(raw)
}

/// Parses multi-artist and collaboration tags across standard delimiters (`;`, `/`, `|`, `\0`),
/// collaboration tokens (`feat.`, `ft.`, `featuring`, `with`, `vs.`), and `,` / `&`.
///
/// Protects:
/// - Canonical compound artist names (e.g. "Earth, Wind & Fire", "Simon & Garfunkel", "Crosby, Stills, Nash & Young").
/// - ", The " / ", the " suffixes (e.g. "Tyler, The Creator", "Portugal. The Man").
pub fn parse_artists(raw: &str) -> Vec<String> {
    let mut s = raw.to_string();

    // 1. Protect canonical compound artists
    let mut protected_artists: Vec<(String, String)> = Vec::new();
    for (i, &canonical) in CANONICAL_COMPOUND_ARTISTS.iter().enumerate() {
        let canonical_lower = canonical.to_lowercase();
        if let Some(pos) = s.to_lowercase().find(&canonical_lower) {
            let placeholder = format!("__CANONICAL_ARTIST_{i}__");
            let matched_exact = s[pos..pos + canonical.len()].to_string();
            s = format!("{}{placeholder}{}", &s[..pos], &s[pos + canonical.len()..]);
            protected_artists.push((placeholder, matched_exact));
        }
    }

    // 2. Protect ", The " / ", the " suffix pattern (e.g. Tyler, The Creator)
    s = s
        .replace(", The ", "__COMMA_THE__The ")
        .replace(", the ", "__COMMA_THE__the ");

    // 3. Replace collaboration tokens with standard semicolon delimiter
    const COLLAB_TOKENS: &[&str] = &[
        " feat. ",
        " feat ",
        " ft. ",
        " ft ",
        " featuring ",
        " Featuring ",
        " Feat. ",
        " Ft. ",
        " with ",
        " With ",
        " vs. ",
        " vs ",
        " Vs. ",
        " Vs ",
    ];

    for &token in COLLAB_TOKENS {
        s = s.replace(token, ";");
    }

    // 4. Replace ampersands and commas (surrounded by spaces or standard delimiters)
    s = s.replace(" & ", ";").replace(", ", ";");

    // 5. Split across explicit and collaboration delimiters
    let mut results: Vec<String> = Vec::new();
    for part in s.split([';', '/', '|', '\0', ',']) {
        let mut unmasked = part.trim().to_string();
        if unmasked.is_empty() {
            continue;
        }

        // Restore ", The "
        unmasked = unmasked.replace("__COMMA_THE__", ", ");

        // Restore canonical compound artists
        for (placeholder, original) in &protected_artists {
            unmasked = unmasked.replace(placeholder, original);
        }

        let normalized = normalize_tag_casing(&unmasked);
        if !normalized.is_empty() && !results.iter().any(|r| r.eq_ignore_ascii_case(&normalized)) {
            results.push(normalized);
        }
    }

    results
}

/// Backwards-compatible alias for artist tag parsing.
pub fn parse_multi_artist_tag(raw: &str) -> Vec<String> {
    parse_artists(raw)
}

/// Parsed ReplayGain metadata fields for a track (`REPLAYGAIN_*` and `R128_*`).
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct ReplayGainTags {
    pub track_gain_db: Option<f64>,
    pub album_gain_db: Option<f64>,
    pub track_peak: Option<f64>,
    pub album_peak: Option<f64>,
}

/// Parses a ReplayGain dB string such as `"-6.45 dB"` or `"+1.20 DB"`.
pub fn parse_replay_gain_db(raw: &str) -> Option<f64> {
    let mut trimmed = raw.trim();
    if trimmed.len() >= 2 && trimmed[trimmed.len() - 2..].eq_ignore_ascii_case("db") {
        trimmed = trimmed[..trimmed.len() - 2].trim_end();
    }
    let val = trimmed.parse::<f64>().ok()?;
    if val.is_finite() && (-60.0..=60.0).contains(&val) {
        Some(val)
    } else {
        None
    }
}

/// Parses a positive linear ReplayGain peak value such as `"0.988525"`.
pub fn parse_replay_gain_peak(raw: &str) -> Option<f64> {
    let val = raw.trim().parse::<f64>().ok()?;
    if val.is_finite() && val > 0.0 && val <= 10.0 {
        Some(val)
    } else {
        None
    }
}

/// Parses an RFC 7845 / EBU R128 Q7.8 integer gain tag and shifts from `-23 LUFS`
/// reference level to standard ReplayGain `-18 LUFS` (`+5.0 dB`).
pub fn parse_r128_gain_db(raw: &str) -> Option<f64> {
    let q78 = raw.trim().parse::<i32>().ok()?;
    let db = (q78 as f64 / 256.0) + 5.0;
    if db.is_finite() && (-60.0..=60.0).contains(&db) {
        Some(db)
    } else {
        None
    }
}

impl ReplayGainTags {
    /// Ingests one metadata key/value pair if it represents a ReplayGain or R128 tag.
    pub fn ingest_tag(&mut self, key: &str, value: &str) {
        let trimmed = key.trim();
        let norm_key = if trimmed.len() > 5 && trimmed[..5].eq_ignore_ascii_case("txxx:") {
            trimmed[5..].trim()
        } else {
            trimmed
        };
        if norm_key.eq_ignore_ascii_case("REPLAYGAIN_TRACK_GAIN") {
            if let Some(v) = parse_replay_gain_db(value) {
                self.track_gain_db = Some(v);
            }
        } else if norm_key.eq_ignore_ascii_case("REPLAYGAIN_ALBUM_GAIN") {
            if let Some(v) = parse_replay_gain_db(value) {
                self.album_gain_db = Some(v);
            }
        } else if norm_key.eq_ignore_ascii_case("REPLAYGAIN_TRACK_PEAK") {
            if let Some(v) = parse_replay_gain_peak(value) {
                self.track_peak = Some(v);
            }
        } else if norm_key.eq_ignore_ascii_case("REPLAYGAIN_ALBUM_PEAK") {
            if let Some(v) = parse_replay_gain_peak(value) {
                self.album_peak = Some(v);
            }
        } else if norm_key.eq_ignore_ascii_case("R128_TRACK_GAIN") && self.track_gain_db.is_none() {
            if let Some(v) = parse_r128_gain_db(value) {
                self.track_gain_db = Some(v);
            }
        } else if norm_key.eq_ignore_ascii_case("R128_ALBUM_GAIN") && self.album_gain_db.is_none() {
            if let Some(v) = parse_r128_gain_db(value) {
                self.album_gain_db = Some(v);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_genres_preserves_compound_genres() {
        let input = "Drum & Bass; Rock & Roll / Rhythm & Blues\0Ambient, Drone|Electronic";
        let parsed = parse_genres(input);
        assert_eq!(
            parsed,
            vec![
                "Drum & Bass",
                "Rock & Roll",
                "Rhythm & Blues",
                "Ambient, Drone",
                "Electronic"
            ]
        );
    }

    #[test]
    fn test_parse_multi_value_tag_normalization_and_deduplication() {
        let input = "progressive rock ; PROGRESSIVE ROCK / Progressive Rock";
        let parsed = parse_genres(input);
        assert_eq!(parsed, vec!["Progressive Rock"]);
    }

    #[test]
    fn test_preserved_acronyms() {
        let input = "edm / r&b / ost / lo-fi hip hop";
        let parsed = parse_genres(input);
        assert_eq!(parsed, vec!["EDM", "R&B", "OST", "Lo-fi Hip Hop"]);
    }

    #[test]
    fn test_parse_artists_protects_canonical_bands() {
        assert_eq!(
            parse_artists("Earth, Wind & Fire"),
            vec!["Earth, Wind & Fire"]
        );
        assert_eq!(
            parse_artists("Simon & Garfunkel"),
            vec!["Simon & Garfunkel"]
        );
        assert_eq!(
            parse_artists("Crosby, Stills, Nash & Young"),
            vec!["Crosby, Stills, Nash & Young"]
        );
        assert_eq!(
            parse_artists("Tyler, The Creator"),
            vec!["Tyler, The Creator"]
        );
    }

    #[test]
    fn test_parse_artists_collaborations_and_compounds() {
        let input1 = "Earth, Wind & Fire feat. Tyler, The Creator";
        assert_eq!(
            parse_artists(input1),
            vec!["Earth, Wind & Fire", "Tyler, The Creator"]
        );

        let input2 = "Simon & Garfunkel with Crosby, Stills, Nash & Young";
        assert_eq!(
            parse_artists(input2),
            vec!["Simon & Garfunkel", "Crosby, Stills, Nash & Young"]
        );

        let input3 = "Daft Punk feat. Pharrell Williams & Nile Rodgers";
        assert_eq!(
            parse_artists(input3),
            vec!["Daft Punk", "Pharrell Williams", "Nile Rodgers"]
        );

        let input4 = "Miles Davis, John Coltrane & Bill Evans";
        assert_eq!(
            parse_artists(input4),
            vec!["Miles Davis", "John Coltrane", "Bill Evans"]
        );

        let input5 = "Hall & Oates vs. Kool & The Gang";
        assert_eq!(
            parse_artists(input5),
            vec!["Hall & Oates", "Kool & The Gang"]
        );
    }

    #[test]
    fn test_replay_gain_tag_ingestion_and_edge_cases() {
        let mut rg = ReplayGainTags::default();
        rg.ingest_tag("TXXX:REPLAYGAIN_TRACK_GAIN", " -7.35 dB ");
        rg.ingest_tag("replaygain_album_gain", "+1.25 DB");
        rg.ingest_tag("REPLAYGAIN_TRACK_PEAK", "0.972107");
        rg.ingest_tag("REPLAYGAIN_ALBUM_PEAK", "1.023");

        assert!((rg.track_gain_db.unwrap() - (-7.35)).abs() < 1e-6);
        assert!((rg.album_gain_db.unwrap() - 1.25).abs() < 1e-6);
        assert!((rg.track_peak.unwrap() - 0.972107).abs() < 1e-6);
        assert!((rg.album_peak.unwrap() - 1.023).abs() < 1e-6);

        // Zero/negative peaks and invalid numbers are ignored cleanly.
        rg.ingest_tag("REPLAYGAIN_TRACK_PEAK", "0.0");
        rg.ingest_tag("REPLAYGAIN_ALBUM_PEAK", "-0.5");
        assert!((rg.track_peak.unwrap() - 0.972107).abs() < 1e-6);
        assert!((rg.album_peak.unwrap() - 1.023).abs() < 1e-6);

        // R128 fallback (-256 Q7.8 = -1.0 dB relative to -23 LUFS => +4.0 dB RG).
        let mut opus_rg = ReplayGainTags::default();
        opus_rg.ingest_tag("R128_TRACK_GAIN", "-256");
        opus_rg.ingest_tag("R128_ALBUM_GAIN", "-512");
        assert!((opus_rg.track_gain_db.unwrap() - 4.0).abs() < 1e-6);
        assert!((opus_rg.album_gain_db.unwrap() - 3.0).abs() < 1e-6);
    }
}

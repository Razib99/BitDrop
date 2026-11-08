//! Multi-value genre and artist tag parser and casing normalizer.
//!
//! Complies with Phase 2 Directive Candidate E:
//! Splits embedded GENRE and ARTIST tags across standard delimiters (`;`, `/`, `,`,
//! null-byte `\0`, `|`, and `feat.` / `ft.` / `&`) and normalizes casing while
//! preserving musical acronyms (e.g. "OST", "EDM", "R&B").

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

/// Splits a genre or generic tag across standard delimiters (`;`, `/`, `,`, `\0`, `|`)
/// and normalizes whitespace and title casing.
pub fn parse_multi_value_tag(raw: &str) -> Vec<String> {
    let mut results: Vec<String> = Vec::new();
    for part in raw.split([';', '/', ',', '\0', '|']) {
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

/// Splits an artist tag across standard delimiters as well as collaboration markers
/// (`feat.`, `ft.`, `featuring`, and `&`).
pub fn parse_multi_artist_tag(raw: &str) -> Vec<String> {
    let with_markers = raw
        .replace(" feat. ", ";")
        .replace(" feat ", ";")
        .replace(" ft. ", ";")
        .replace(" ft ", ";")
        .replace(" featuring ", ";")
        .replace(" Featuring ", ";")
        .replace(" Feat. ", ";")
        .replace(" Ft. ", ";")
        .replace(" & ", ";");

    parse_multi_value_tag(&with_markers)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_multi_value_tag_delimiters() {
        let input = "Electronic; Progressive Rock / Ambient, Synthwave\0Chillout|Downtempo";
        let parsed = parse_multi_value_tag(input);
        assert_eq!(
            parsed,
            vec![
                "Electronic",
                "Progressive Rock",
                "Ambient",
                "Synthwave",
                "Chillout",
                "Downtempo"
            ]
        );
    }

    #[test]
    fn test_parse_multi_value_tag_normalization_and_deduplication() {
        let input = "progressive rock ; PROGRESSIVE ROCK / Progressive Rock";
        let parsed = parse_multi_value_tag(input);
        assert_eq!(parsed, vec!["Progressive Rock"]);
    }

    #[test]
    fn test_preserved_acronyms() {
        let input = "edm / r&b / ost / lo-fi hip hop";
        let parsed = parse_multi_value_tag(input);
        assert_eq!(parsed, vec!["EDM", "R&B", "OST", "Lo-fi Hip Hop"]);
    }

    #[test]
    fn test_parse_multi_artist_collaborations() {
        let input = "Daft Punk feat. Pharrell Williams & Nile Rodgers";
        let artists = parse_multi_artist_tag(input);
        assert_eq!(
            artists,
            vec!["Daft Punk", "Pharrell Williams", "Nile Rodgers"]
        );
    }
}

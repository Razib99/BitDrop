//! Modular cloud storage provider architecture for BitDrop.
//!
//! Complies with Phase 2 Directive Candidate D:
//! Defines the universal `CloudStorageProvider` trait and concrete implementations for:
//! - `GoogleDriveProvider` (Google Drive v3 API)
//! - `WebDavProvider` (Nextcloud, ownCloud, Synology NAS, QNAP via HTTP PROPFIND & byte ranges)
//! - `OneDriveProvider` (Microsoft Graph v1.0 delta sync & byte ranges)
//! - `DropboxProvider` (Dropbox API v2 list_folder & byte ranges)
//! - `ProviderRegistry` (Thread-safe provider lookup and registration)

use parking_lot::RwLock;
use std::collections::HashMap;
use std::fmt;
use std::sync::Arc;
use std::time::Duration;

/// Supported high-resolution audio formats decoded by BitDrop's audio engine.
pub const SUPPORTED_AUDIO_EXTENSIONS: &[&str] = &[
    "flac", "wav", "wave", "alac", "aif", "aiff", "mp3", "m4a", "aac", "ogg", "dsf", "dff",
];

/// Returns true if the file name has a supported audio extension.
pub fn is_audio_file(name: &str) -> bool {
    let ext = name.rsplit('.').next().unwrap_or("").to_lowercase();
    SUPPORTED_AUDIO_EXTENSIONS.contains(&ext.as_str())
}

/// Builds an HTTP `Range: bytes={start}-{end_inclusive}` header value.
pub fn build_range_header(start: u64, end_inclusive: u64) -> Result<String, CloudError> {
    if start > end_inclusive {
        return Err(CloudError::unsupported(format!(
            "Invalid byte range: start ({start}) > end_inclusive ({end_inclusive})"
        )));
    }
    Ok(format!("bytes={start}-{end_inclusive}"))
}

/// Base64 encodes an input slice (used for WebDAV HTTP Basic Auth without external dependencies).
pub fn base64_encode(input: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let b0 = chunk[0];
        let b1 = if chunk.len() > 1 { chunk[1] } else { 0 };
        let b2 = if chunk.len() > 2 { chunk[2] } else { 0 };

        let n = ((b0 as u32) << 16) | ((b1 as u32) << 8) | (b2 as u32);

        out.push(TABLE[((n >> 18) & 0x3F) as usize] as char);
        out.push(TABLE[((n >> 12) & 0x3F) as usize] as char);
        if chunk.len() > 1 {
            out.push(TABLE[((n >> 6) & 0x3F) as usize] as char);
        } else {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(TABLE[(n & 0x3F) as usize] as char);
        } else {
            out.push('=');
        }
    }
    out
}

/// Percent-decodes a URL path component (e.g. `%20` -> space).
pub fn percent_decode(input: &str) -> String {
    let mut bytes = Vec::new();
    let mut chars = input.bytes();
    while let Some(b) = chars.next() {
        if b == b'%' {
            let h1 = chars.next();
            let h2 = chars.next();
            if let (Some(h1), Some(h2)) = (h1, h2) {
                let d1 = match h1 {
                    b'0'..=b'9' => Some(h1 - b'0'),
                    b'a'..=b'f' => Some(h1 - b'a' + 10),
                    b'A'..=b'F' => Some(h1 - b'A' + 10),
                    _ => None,
                };
                let d2 = match h2 {
                    b'0'..=b'9' => Some(h2 - b'0'),
                    b'a'..=b'f' => Some(h2 - b'a' + 10),
                    b'A'..=b'F' => Some(h2 - b'A' + 10),
                    _ => None,
                };
                if let (Some(d1), Some(d2)) = (d1, d2) {
                    bytes.push((d1 << 4) | d2);
                    continue;
                }
            }
        }
        bytes.push(b);
    }
    String::from_utf8_lossy(&bytes).to_string()
}

/// Unescapes standard XML entities.
pub fn xml_unescape(input: &str) -> String {
    input
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&#39;", "'")
}

// ---------------------------------------------------------------------------
// Domain Errors & Models
// ---------------------------------------------------------------------------

/// Categorized error kinds for cloud storage interactions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CloudErrorKind {
    Unauthorized,
    RateLimited,
    NotFound,
    Network(String),
    MalformedResponse(String),
    StorageQuotaExceeded,
    UnsupportedOperation(String),
    Other(String),
}

/// A structured error returned by cloud storage operations.
#[derive(Debug, Clone)]
pub struct CloudError {
    pub kind: CloudErrorKind,
    pub message: String,
    pub retry_after_secs: Option<u64>,
}

impl CloudError {
    pub fn unauthorized(msg: impl Into<String>) -> Self {
        Self {
            kind: CloudErrorKind::Unauthorized,
            message: msg.into(),
            retry_after_secs: None,
        }
    }

    pub fn rate_limited(msg: impl Into<String>, retry_after: Option<u64>) -> Self {
        Self {
            kind: CloudErrorKind::RateLimited,
            message: msg.into(),
            retry_after_secs: retry_after,
        }
    }

    pub fn not_found(msg: impl Into<String>) -> Self {
        Self {
            kind: CloudErrorKind::NotFound,
            message: msg.into(),
            retry_after_secs: None,
        }
    }

    pub fn network(msg: impl Into<String>) -> Self {
        let m = msg.into();
        Self {
            kind: CloudErrorKind::Network(m.clone()),
            message: m,
            retry_after_secs: None,
        }
    }

    pub fn malformed(msg: impl Into<String>) -> Self {
        let m = msg.into();
        Self {
            kind: CloudErrorKind::MalformedResponse(m.clone()),
            message: m,
            retry_after_secs: None,
        }
    }

    pub fn unsupported(msg: impl Into<String>) -> Self {
        let m = msg.into();
        Self {
            kind: CloudErrorKind::UnsupportedOperation(m.clone()),
            message: m,
            retry_after_secs: None,
        }
    }

    pub fn other(msg: impl Into<String>) -> Self {
        let m = msg.into();
        Self {
            kind: CloudErrorKind::Other(m.clone()),
            message: m,
            retry_after_secs: None,
        }
    }
}

impl fmt::Display for CloudError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:?}: {}", self.kind, self.message)
    }
}

impl std::error::Error for CloudError {}

/// A single file, folder, or tombstone item returned by a cloud provider.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CloudItem {
    /// Unique provider-specific file/object identifier or path.
    pub id: String,
    /// Human-readable file or directory name (e.g. "01 - So What.flac").
    pub name: String,
    /// Total file size in bytes (0 for directories).
    pub size_bytes: u64,
    /// True if the item is a directory / collection.
    pub is_directory: bool,
    /// Hierarchical folder trail (e.g. "Music / Miles Davis").
    pub folder_path: String,
    /// MIME type if provided by the storage provider.
    pub mime_type: Option<String>,
    /// Last modified Unix epoch timestamp in milliseconds, if available.
    pub modified_time: Option<i64>,
    /// ETag, MD5, QuickXorHash, or content hash.
    pub checksum_or_etag: Option<String>,
    /// Direct download URL if provided by provider (e.g. Graph @microsoft.graph.downloadUrl).
    pub download_url: Option<String>,
    /// True if this item was deleted/removed (tombstone for delta sync).
    pub is_deleted: bool,
}

/// A page of delta changes or initial catalog listing from a cloud provider.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CloudDeltaPage {
    /// Items discovered or modified in this page.
    pub items: Vec<CloudItem>,
    /// Pagination cursor to retrieve the next page of this query, if incomplete.
    pub next_cursor: Option<String>,
    /// New delta cursor to persist for subsequent delta synchronization cycles.
    pub new_delta_cursor: Option<String>,
    /// True if additional pages exist for the current listing.
    pub has_more: bool,
}

// ---------------------------------------------------------------------------
// Trait Definition
// ---------------------------------------------------------------------------

/// Universal zero-server cloud and NAS audio storage provider trait.
pub trait CloudStorageProvider: Send + Sync {
    /// Unique static provider identifier (e.g. "google_drive", "webdav", "onedrive", "dropbox").
    fn provider_id(&self) -> &'static str;

    /// Fetches a page of file/folder changes or initial catalog items.
    ///
    /// If `cursor` is `None`, begins an initial crawl or requests a new delta baseline.
    /// If `cursor` is `Some`, retrieves incremental changes since that checkpoint.
    fn list_changes(&self, cursor: Option<&str>) -> Result<CloudDeltaPage, CloudError>;

    /// Fetches a specific byte range (`[start, end_inclusive]`) from the target file.
    ///
    /// Data is streamed directly into BitDrop's sparse CRC32-verified chunk cache.
    fn fetch_byte_range(
        &self,
        file_id: &str,
        start: u64,
        end_inclusive: u64,
    ) -> Result<Vec<u8>, CloudError>;

    /// Refreshes expired credentials if necessary.
    fn refresh_credentials_if_needed(&self) -> Result<(), CloudError>;
}

// ---------------------------------------------------------------------------
// Internal Async Helper
// ---------------------------------------------------------------------------

/// Executes an async future synchronously without deadlocking or panicking inside Tokio runtimes.
fn run_async<F, T>(future: F) -> T
where
    F: std::future::Future<Output = T>,
{
    if let Ok(handle) = tokio::runtime::Handle::try_current() {
        tokio::task::block_in_place(|| handle.block_on(future))
    } else {
        lazy_static::lazy_static! {
            static ref PROVIDER_RT: tokio::runtime::Runtime = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .expect("Failed to initialize cloud provider runtime");
        }
        PROVIDER_RT.block_on(future)
    }
}

fn build_reqwest_client() -> reqwest::Client {
    reqwest::Client::builder()
        .pool_max_idle_per_host(16)
        .timeout(Duration::from_secs(30))
        .build()
        .unwrap_or_default()
}

// ---------------------------------------------------------------------------
// 1. Google Drive Provider
// ---------------------------------------------------------------------------

/// Google Drive v3 storage provider.
pub struct GoogleDriveProvider {
    access_token: RwLock<Option<String>>,
    base_url: String,
    client: reqwest::Client,
}

impl GoogleDriveProvider {
    pub const DEFAULT_BASE_URL: &'static str = "https://www.googleapis.com/drive/v3";

    pub fn new(access_token: Option<String>) -> Self {
        Self {
            access_token: RwLock::new(access_token),
            base_url: Self::DEFAULT_BASE_URL.to_string(),
            client: build_reqwest_client(),
        }
    }

    pub fn with_base_url(mut self, url: impl Into<String>) -> Self {
        self.base_url = url.into().trim_end_matches('/').to_string();
        self
    }

    pub fn set_access_token(&self, token: Option<String>) {
        *self.access_token.write() = token;
    }

    pub fn access_token(&self) -> Option<String> {
        self.access_token.read().clone()
    }
}

/// Parses Google Drive v3 `/changes` JSON payload into `CloudDeltaPage`.
pub fn parse_google_drive_changes(
    json_val: &serde_json::Value,
) -> Result<CloudDeltaPage, CloudError> {
    let next_page_token = json_val
        .get("nextPageToken")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let new_start_token = json_val
        .get("newStartPageToken")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    let mut items = Vec::new();
    if let Some(changes) = json_val.get("changes").and_then(|v| v.as_array()) {
        for change in changes {
            let file_id = change
                .get("fileId")
                .and_then(|v| v.as_str())
                .unwrap_or_default();
            let is_removed = change
                .get("removed")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);

            if is_removed {
                items.push(CloudItem {
                    id: file_id.to_string(),
                    name: String::new(),
                    size_bytes: 0,
                    is_directory: false,
                    folder_path: String::new(),
                    mime_type: None,
                    modified_time: None,
                    checksum_or_etag: None,
                    download_url: None,
                    is_deleted: true,
                });
                continue;
            }

            if let Some(file) = change.get("file") {
                let id = file.get("id").and_then(|v| v.as_str()).unwrap_or(file_id);
                let name = file
                    .get("name")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default();
                let mime_type = file
                    .get("mimeType")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string());
                let is_dir = mime_type.as_deref() == Some("application/vnd.google-apps.folder");
                let is_trashed = file
                    .get("trashed")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);
                let size_bytes = file
                    .get("size")
                    .and_then(|v| v.as_str())
                    .and_then(|s| s.parse::<u64>().ok())
                    .unwrap_or(0);
                let md5 = file
                    .get("md5Checksum")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string());

                if is_dir || is_audio_file(name) || is_trashed {
                    items.push(CloudItem {
                        id: id.to_string(),
                        name: name.to_string(),
                        size_bytes,
                        is_directory: is_dir,
                        folder_path: String::new(),
                        mime_type,
                        modified_time: None,
                        checksum_or_etag: md5,
                        download_url: Some(format!(
                            "https://www.googleapis.com/drive/v3/files/{id}?alt=media"
                        )),
                        is_deleted: is_trashed,
                    });
                }
            }
        }
    }

    let has_more = next_page_token.is_some();
    Ok(CloudDeltaPage {
        items,
        next_cursor: next_page_token,
        new_delta_cursor: new_start_token,
        has_more,
    })
}

/// Parses Google Drive v3 `/files` list JSON payload into `CloudDeltaPage`.
pub fn parse_google_drive_files(
    json_val: &serde_json::Value,
) -> Result<CloudDeltaPage, CloudError> {
    let next_page_token = json_val
        .get("nextPageToken")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    let mut items = Vec::new();
    if let Some(files) = json_val.get("files").and_then(|v| v.as_array()) {
        for file in files {
            let id = file.get("id").and_then(|v| v.as_str()).unwrap_or_default();
            let name = file
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or_default();
            let mime_type = file
                .get("mimeType")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());
            let is_dir = mime_type.as_deref() == Some("application/vnd.google-apps.folder");
            let is_trashed = file
                .get("trashed")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            let size_bytes = file
                .get("size")
                .and_then(|v| v.as_str())
                .and_then(|s| s.parse::<u64>().ok())
                .unwrap_or(0);
            let md5 = file
                .get("md5Checksum")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());

            if is_dir || is_audio_file(name) || is_trashed {
                items.push(CloudItem {
                    id: id.to_string(),
                    name: name.to_string(),
                    size_bytes,
                    is_directory: is_dir,
                    folder_path: String::new(),
                    mime_type,
                    modified_time: None,
                    checksum_or_etag: md5,
                    download_url: Some(format!(
                        "https://www.googleapis.com/drive/v3/files/{id}?alt=media"
                    )),
                    is_deleted: is_trashed,
                });
            }
        }
    }

    let has_more = next_page_token.is_some();
    Ok(CloudDeltaPage {
        items,
        next_cursor: next_page_token,
        new_delta_cursor: None,
        has_more,
    })
}

impl CloudStorageProvider for GoogleDriveProvider {
    fn provider_id(&self) -> &'static str {
        "google_drive"
    }

    fn list_changes(&self, cursor: Option<&str>) -> Result<CloudDeltaPage, CloudError> {
        let token = self.access_token.read().clone().ok_or_else(|| {
            CloudError::unauthorized("No active Google Drive access token configured")
        })?;

        let url = if let Some(c) = cursor {
            format!(
                "{}/changes?pageToken={}&pageSize=1000&fields=nextPageToken,newStartPageToken,changes(fileId,removed,file(id,name,mimeType,size,modifiedTime,md5Checksum,parents,trashed))",
                self.base_url, c
            )
        } else {
            format!(
                "{}/files?pageSize=1000&fields=nextPageToken,files(id,name,mimeType,size,modifiedTime,md5Checksum,parents,trashed)&q=trashed%3Dfalse",
                self.base_url
            )
        };

        let client = self.client.clone();
        run_async(async move {
            let res = client
                .get(&url)
                .bearer_auth(token)
                .send()
                .await
                .map_err(|e| CloudError::network(e.to_string()))?;

            let status = res.status();
            if status == reqwest::StatusCode::UNAUTHORIZED
                || status == reqwest::StatusCode::FORBIDDEN
            {
                return Err(CloudError::unauthorized(format!("HTTP {status}")));
            }
            if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
                return Err(CloudError::rate_limited("Google Drive rate limit", Some(5)));
            }
            if !status.is_success() {
                return Err(CloudError::other(format!(
                    "Google Drive returned HTTP {status}"
                )));
            }

            let json: serde_json::Value = res
                .json()
                .await
                .map_err(|e| CloudError::malformed(e.to_string()))?;

            if cursor.is_some() {
                parse_google_drive_changes(&json)
            } else {
                parse_google_drive_files(&json)
            }
        })
    }

    fn fetch_byte_range(
        &self,
        file_id: &str,
        start: u64,
        end_inclusive: u64,
    ) -> Result<Vec<u8>, CloudError> {
        let range_val = build_range_header(start, end_inclusive)?;
        let token = self.access_token.read().clone();
        let url = format!("{}/files/{}?alt=media", self.base_url, file_id);
        let client = self.client.clone();

        run_async(async move {
            let mut req = client.get(&url).header(reqwest::header::RANGE, range_val);
            if let Some(tok) = token {
                req = req.bearer_auth(tok);
            }

            let res = req
                .send()
                .await
                .map_err(|e| CloudError::network(e.to_string()))?;

            let status = res.status();
            if status == reqwest::StatusCode::UNAUTHORIZED
                || status == reqwest::StatusCode::FORBIDDEN
            {
                return Err(CloudError::unauthorized(format!("HTTP {status}")));
            }
            if status == reqwest::StatusCode::NOT_FOUND {
                return Err(CloudError::not_found(format!("File {file_id} not found")));
            }
            if !status.is_success() && status != reqwest::StatusCode::PARTIAL_CONTENT {
                return Err(CloudError::other(format!(
                    "Range request failed with HTTP {status}"
                )));
            }

            let bytes = res
                .bytes()
                .await
                .map_err(|e| CloudError::network(e.to_string()))?;
            Ok(bytes.to_vec())
        })
    }

    fn refresh_credentials_if_needed(&self) -> Result<(), CloudError> {
        let current = self.access_token.read().clone();
        if let Some(cur) = current {
            let refreshed = run_async(async move { crate::cloud::auth::refresh_token(&cur).await });
            if let Some(new_tok) = refreshed {
                *self.access_token.write() = Some(new_tok);
                return Ok(());
            }
        }
        Err(CloudError::unauthorized(
            "Failed to refresh Google Drive token",
        ))
    }
}

// ---------------------------------------------------------------------------
// 2. WebDAV Provider (Nextcloud, ownCloud, Synology NAS, QNAP)
// ---------------------------------------------------------------------------

/// WebDAV storage provider for self-hosted and NAS audio libraries.
pub struct WebDavProvider {
    endpoint_url: String,
    auth_header: RwLock<Option<String>>,
    client: reqwest::Client,
}

impl WebDavProvider {
    pub fn new(endpoint_url: impl Into<String>, auth_header: Option<String>) -> Self {
        Self {
            endpoint_url: endpoint_url.into().trim_end_matches('/').to_string(),
            auth_header: RwLock::new(auth_header),
            client: build_reqwest_client(),
        }
    }

    pub fn with_basic_auth(endpoint_url: impl Into<String>, user: &str, pass: &str) -> Self {
        let cred = format!("{user}:{pass}");
        let encoded = base64_encode(cred.as_bytes());
        Self::new(endpoint_url, Some(format!("Basic {encoded}")))
    }

    pub fn with_bearer_token(endpoint_url: impl Into<String>, token: &str) -> Self {
        Self::new(endpoint_url, Some(format!("Bearer {token}")))
    }

    pub fn endpoint_url(&self) -> &str {
        &self.endpoint_url
    }
}

/// Extracts the raw inner content between `<tag>` (or `<prefix:tag>`) and `</tag>`.
fn extract_xml_tag(xml: &str, tag_name: &str) -> Option<String> {
    let lower_xml = xml.to_ascii_lowercase();
    let lower_tag = tag_name.to_ascii_lowercase();

    let mut search_idx = 0;
    while let Some(open_bracket) = lower_xml[search_idx..].find('<') {
        let start = search_idx + open_bracket;
        let close_bracket = start + lower_xml[start..].find('>')?;

        let tag_header = lower_xml[start + 1..close_bracket].trim();
        let is_match = if tag_header.contains(':') {
            let local = tag_header.split(':').nth(1).unwrap_or("").trim();
            local.starts_with(&lower_tag)
        } else {
            tag_header.starts_with(&lower_tag)
        };

        if is_match && !tag_header.starts_with('/') {
            // Found opening tag, find corresponding closing tag
            let content_start = close_bracket + 1;
            let end_pattern = format!("</{}", lower_tag);
            let mut close_idx = content_start;
            while let Some(pos) = lower_xml[close_idx..].find(&end_pattern) {
                let found = close_idx + pos;
                let after = &lower_xml[found + end_pattern.len()..];
                if after.starts_with('>') || after.starts_with(' ') {
                    return Some(xml[content_start..found].trim().to_string());
                }
                close_idx = found + end_pattern.len();
            }

            // Also check for prefixed closing tag like `</d:tag>`
            let mut p_close_idx = content_start;
            while let Some(pos) = lower_xml[p_close_idx..].find("</") {
                let found = p_close_idx + pos;
                if let Some(gt) = lower_xml[found..].find('>') {
                    let close_header = lower_xml[found + 2..found + gt].trim();
                    let local_close = if close_header.contains(':') {
                        close_header.split(':').nth(1).unwrap_or("").trim()
                    } else {
                        close_header
                    };
                    if local_close == lower_tag {
                        return Some(xml[content_start..found].trim().to_string());
                    }
                }
                p_close_idx = found + 2;
            }
        }
        search_idx = close_bracket + 1;
    }
    None
}

/// Parses a WebDAV `PROPFIND` XML response into a list of `CloudItem` records.
pub fn parse_webdav_multistatus(xml: &str, base_path: &str) -> Result<Vec<CloudItem>, CloudError> {
    let mut items = Vec::new();
    let lower_xml = xml.to_ascii_lowercase();
    let mut cursor = 0;

    while let Some(start_pos) = lower_xml[cursor..]
        .find("<d:response>")
        .or_else(|| lower_xml[cursor..].find("<response>"))
    {
        let abs_start = cursor + start_pos;
        let close_pos = match lower_xml[abs_start..]
            .find("</d:response>")
            .or_else(|| lower_xml[abs_start..].find("</response>"))
        {
            Some(p) => abs_start + p,
            None => break,
        };

        let block = &xml[abs_start..close_pos];
        cursor = close_pos + 10;

        let href_raw = extract_xml_tag(block, "href").unwrap_or_default();
        let href = xml_unescape(&percent_decode(&href_raw));
        if href.is_empty() {
            continue;
        }

        let clean_href = href.trim_end_matches('/');
        let clean_base = base_path.trim_end_matches('/');

        // Skip root collection self-reference
        if clean_href == clean_base || clean_href.is_empty() {
            continue;
        }

        let is_dir = if let Some(resourcetype) = extract_xml_tag(block, "resourcetype") {
            let lower = resourcetype.to_ascii_lowercase();
            lower.contains("collection")
        } else {
            false
        };

        let display_name = extract_xml_tag(block, "displayname")
            .map(|s| xml_unescape(&s))
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| {
                clean_href
                    .rsplit('/')
                    .next()
                    .unwrap_or_default()
                    .to_string()
            });

        if !is_dir && !is_audio_file(&display_name) {
            continue;
        }

        let size_bytes = extract_xml_tag(block, "getcontentlength")
            .and_then(|s| s.parse::<u64>().ok())
            .unwrap_or(0);

        let etag = extract_xml_tag(block, "getetag").map(|s| s.trim_matches('"').to_string());

        let folder_trail = clean_href
            .rsplit_once('/')
            .map(|(parent, _)| parent.trim_start_matches('/'))
            .unwrap_or_default()
            .replace('/', " / ");

        items.push(CloudItem {
            id: clean_href.to_string(),
            name: display_name,
            size_bytes: if is_dir { 0 } else { size_bytes },
            is_directory: is_dir,
            folder_path: folder_trail,
            mime_type: extract_xml_tag(block, "getcontenttype"),
            modified_time: None,
            checksum_or_etag: etag,
            download_url: Some(clean_href.to_string()),
            is_deleted: false,
        });
    }

    Ok(items)
}

impl CloudStorageProvider for WebDavProvider {
    fn provider_id(&self) -> &'static str {
        "webdav"
    }

    fn list_changes(&self, cursor: Option<&str>) -> Result<CloudDeltaPage, CloudError> {
        let auth = self.auth_header.read().clone();
        let target_url = cursor.unwrap_or(&self.endpoint_url).to_string();
        let base_path = self.endpoint_url.clone();
        let client = self.client.clone();

        const PROPFIND_XML: &str = r#"<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:displayname/>
    <d:getcontentlength/>
    <d:getlastmodified/>
    <d:resourcetype/>
    <d:getetag/>
    <d:getcontenttype/>
  </d:prop>
</d:propfind>"#;

        run_async(async move {
            let mut req = client
                .request(
                    reqwest::Method::from_bytes(b"PROPFIND").unwrap_or(reqwest::Method::GET),
                    &target_url,
                )
                .header("Depth", "1")
                .header(
                    reqwest::header::CONTENT_TYPE,
                    "application/xml; charset=utf-8",
                )
                .body(PROPFIND_XML);

            if let Some(auth_val) = auth {
                req = req.header(reqwest::header::AUTHORIZATION, auth_val);
            }

            let res = req
                .send()
                .await
                .map_err(|e| CloudError::network(e.to_string()))?;

            let status = res.status();
            if status == reqwest::StatusCode::UNAUTHORIZED
                || status == reqwest::StatusCode::FORBIDDEN
            {
                return Err(CloudError::unauthorized(format!(
                    "WebDAV auth failed: {status}"
                )));
            }
            if !status.is_success() && status.as_u16() != 207 {
                return Err(CloudError::other(format!(
                    "WebDAV PROPFIND returned {status}"
                )));
            }

            let xml_body = res
                .text()
                .await
                .map_err(|e| CloudError::network(e.to_string()))?;

            let items = parse_webdav_multistatus(&xml_body, &base_path)?;
            Ok(CloudDeltaPage {
                items,
                next_cursor: None,
                new_delta_cursor: Some(format!(
                    "webdav-sync-{}",
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.as_secs())
                        .unwrap_or(0)
                )),
                has_more: false,
            })
        })
    }

    fn fetch_byte_range(
        &self,
        file_id: &str,
        start: u64,
        end_inclusive: u64,
    ) -> Result<Vec<u8>, CloudError> {
        let range_val = build_range_header(start, end_inclusive)?;
        let auth = self.auth_header.read().clone();
        let url = if file_id.starts_with("http://") || file_id.starts_with("https://") {
            file_id.to_string()
        } else {
            format!("{}/{}", self.endpoint_url, file_id.trim_start_matches('/'))
        };

        let client = self.client.clone();
        run_async(async move {
            let mut req = client.get(&url).header(reqwest::header::RANGE, range_val);
            if let Some(auth_val) = auth {
                req = req.header(reqwest::header::AUTHORIZATION, auth_val);
            }

            let res = req
                .send()
                .await
                .map_err(|e| CloudError::network(e.to_string()))?;

            let status = res.status();
            if status == reqwest::StatusCode::UNAUTHORIZED
                || status == reqwest::StatusCode::FORBIDDEN
            {
                return Err(CloudError::unauthorized(format!("HTTP {status}")));
            }
            if status == reqwest::StatusCode::NOT_FOUND {
                return Err(CloudError::not_found(format!("File {file_id} not found")));
            }
            if !status.is_success() && status != reqwest::StatusCode::PARTIAL_CONTENT {
                return Err(CloudError::other(format!("WebDAV GET returned {status}")));
            }

            let bytes = res
                .bytes()
                .await
                .map_err(|e| CloudError::network(e.to_string()))?;
            Ok(bytes.to_vec())
        })
    }

    fn refresh_credentials_if_needed(&self) -> Result<(), CloudError> {
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// 3. OneDrive Provider (Microsoft Graph)
// ---------------------------------------------------------------------------

/// Microsoft OneDrive storage provider via Microsoft Graph API v1.0.
pub struct OneDriveProvider {
    client_id: String,
    access_token: RwLock<Option<String>>,
    refresh_token: RwLock<Option<String>>,
    base_url: String,
    client: reqwest::Client,
}

impl OneDriveProvider {
    pub const DEFAULT_BASE_URL: &'static str = "https://graph.microsoft.com/v1.0";

    pub fn new(
        client_id: impl Into<String>,
        access_token: Option<String>,
        refresh_token: Option<String>,
    ) -> Self {
        Self {
            client_id: client_id.into(),
            access_token: RwLock::new(access_token),
            refresh_token: RwLock::new(refresh_token),
            base_url: Self::DEFAULT_BASE_URL.to_string(),
            client: build_reqwest_client(),
        }
    }

    pub fn with_base_url(mut self, url: impl Into<String>) -> Self {
        self.base_url = url.into().trim_end_matches('/').to_string();
        self
    }

    pub fn client_id(&self) -> &str {
        &self.client_id
    }

    pub fn access_token(&self) -> Option<String> {
        self.access_token.read().clone()
    }
}

/// Parses Microsoft Graph delta JSON payload into `CloudDeltaPage`.
pub fn parse_onedrive_delta(json_val: &serde_json::Value) -> Result<CloudDeltaPage, CloudError> {
    let next_link = json_val
        .get("@odata.nextLink")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let delta_link = json_val
        .get("@odata.deltaLink")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    let mut items = Vec::new();
    if let Some(values) = json_val.get("value").and_then(|v| v.as_array()) {
        for val in values {
            let id = val.get("id").and_then(|v| v.as_str()).unwrap_or_default();
            let name = val.get("name").and_then(|v| v.as_str()).unwrap_or_default();
            let is_deleted = val.get("deleted").is_some();
            let is_dir = val.get("folder").is_some();
            let size_bytes = val.get("size").and_then(|v| v.as_u64()).unwrap_or(0);

            let folder_path = val
                .get("parentReference")
                .and_then(|p| p.get("path"))
                .and_then(|p| p.as_str())
                .unwrap_or_default()
                .trim_start_matches("/drive/root:")
                .trim_start_matches('/')
                .replace('/', " / ");

            let mime_type = val
                .get("file")
                .and_then(|f| f.get("mimeType"))
                .and_then(|m| m.as_str())
                .map(|s| s.to_string());

            let etag = val
                .get("eTag")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());
            let download_url = val
                .get("@microsoft.graph.downloadUrl")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());

            if is_dir || is_audio_file(name) || is_deleted {
                items.push(CloudItem {
                    id: id.to_string(),
                    name: name.to_string(),
                    size_bytes: if is_dir { 0 } else { size_bytes },
                    is_directory: is_dir,
                    folder_path,
                    mime_type,
                    modified_time: None,
                    checksum_or_etag: etag,
                    download_url,
                    is_deleted,
                });
            }
        }
    }

    let has_more = next_link.is_some();
    Ok(CloudDeltaPage {
        items,
        next_cursor: next_link,
        new_delta_cursor: delta_link,
        has_more,
    })
}

impl CloudStorageProvider for OneDriveProvider {
    fn provider_id(&self) -> &'static str {
        "onedrive"
    }

    fn list_changes(&self, cursor: Option<&str>) -> Result<CloudDeltaPage, CloudError> {
        let token = self.access_token.read().clone().ok_or_else(|| {
            CloudError::unauthorized("No active OneDrive access token configured")
        })?;

        let url = match cursor {
            Some(c) if c.starts_with("http://") || c.starts_with("https://") => c.to_string(),
            Some(c) => format!("{}/me/drive/root/delta?token={}", self.base_url, c),
            None => format!("{}/me/drive/root/delta", self.base_url),
        };

        let client = self.client.clone();
        run_async(async move {
            let res = client
                .get(&url)
                .bearer_auth(token)
                .send()
                .await
                .map_err(|e| CloudError::network(e.to_string()))?;

            let status = res.status();
            if status == reqwest::StatusCode::UNAUTHORIZED
                || status == reqwest::StatusCode::FORBIDDEN
            {
                return Err(CloudError::unauthorized(format!("HTTP {status}")));
            }
            if !status.is_success() {
                return Err(CloudError::other(format!("Graph delta returned {status}")));
            }

            let json: serde_json::Value = res
                .json()
                .await
                .map_err(|e| CloudError::malformed(e.to_string()))?;

            parse_onedrive_delta(&json)
        })
    }

    fn fetch_byte_range(
        &self,
        file_id: &str,
        start: u64,
        end_inclusive: u64,
    ) -> Result<Vec<u8>, CloudError> {
        let range_val = build_range_header(start, end_inclusive)?;
        let token = self.access_token.read().clone();
        let url = format!("{}/me/drive/items/{}/content", self.base_url, file_id);
        let client = self.client.clone();

        run_async(async move {
            let mut req = client.get(&url).header(reqwest::header::RANGE, range_val);
            if let Some(tok) = token {
                req = req.bearer_auth(tok);
            }

            let res = req
                .send()
                .await
                .map_err(|e| CloudError::network(e.to_string()))?;

            let status = res.status();
            if status == reqwest::StatusCode::UNAUTHORIZED
                || status == reqwest::StatusCode::FORBIDDEN
            {
                return Err(CloudError::unauthorized(format!("HTTP {status}")));
            }
            if status == reqwest::StatusCode::NOT_FOUND {
                return Err(CloudError::not_found(format!("File {file_id} not found")));
            }
            if !status.is_success() && status != reqwest::StatusCode::PARTIAL_CONTENT {
                return Err(CloudError::other(format!("OneDrive GET returned {status}")));
            }

            let bytes = res
                .bytes()
                .await
                .map_err(|e| CloudError::network(e.to_string()))?;
            Ok(bytes.to_vec())
        })
    }

    fn refresh_credentials_if_needed(&self) -> Result<(), CloudError> {
        let rt =
            self.refresh_token.read().clone().ok_or_else(|| {
                CloudError::unauthorized("No refresh token available for OneDrive")
            })?;

        let client_id = self.client_id.clone();
        let client = self.client.clone();

        run_async(async move {
            let params = [
                ("client_id", client_id.as_str()),
                ("grant_type", "refresh_token"),
                ("refresh_token", rt.as_str()),
            ];

            let res = client
                .post("https://login.microsoftonline.com/common/oauth2/v2.0/token")
                .form(&params)
                .send()
                .await
                .map_err(|e| CloudError::network(e.to_string()))?;

            if !res.status().is_success() {
                return Err(CloudError::unauthorized("OneDrive token refresh rejected"));
            }

            let json: serde_json::Value = res
                .json()
                .await
                .map_err(|e| CloudError::malformed(e.to_string()))?;

            let new_tok = json
                .get("access_token")
                .and_then(|v| v.as_str())
                .ok_or_else(|| CloudError::malformed("Missing access_token in refresh response"))?;

            *self.access_token.write() = Some(new_tok.to_string());
            if let Some(new_rt) = json.get("refresh_token").and_then(|v| v.as_str()) {
                *self.refresh_token.write() = Some(new_rt.to_string());
            }
            Ok(())
        })
    }
}

// ---------------------------------------------------------------------------
// 4. Dropbox Provider
// ---------------------------------------------------------------------------

/// Dropbox storage provider via Dropbox API v2.
pub struct DropboxProvider {
    client_id: String,
    access_token: RwLock<Option<String>>,
    refresh_token: RwLock<Option<String>>,
    root_path: String,
    api_base_url: String,
    content_base_url: String,
    client: reqwest::Client,
}

impl DropboxProvider {
    pub const DEFAULT_API_URL: &'static str = "https://api.dropboxapi.com/2";
    pub const DEFAULT_CONTENT_URL: &'static str = "https://content.dropboxapi.com/2";

    pub fn new(
        client_id: impl Into<String>,
        access_token: Option<String>,
        refresh_token: Option<String>,
        root_path: impl Into<String>,
    ) -> Self {
        Self {
            client_id: client_id.into(),
            access_token: RwLock::new(access_token),
            refresh_token: RwLock::new(refresh_token),
            root_path: root_path.into(),
            api_base_url: Self::DEFAULT_API_URL.to_string(),
            content_base_url: Self::DEFAULT_CONTENT_URL.to_string(),
            client: build_reqwest_client(),
        }
    }

    pub fn with_base_urls(
        mut self,
        api_url: impl Into<String>,
        content_url: impl Into<String>,
    ) -> Self {
        self.api_base_url = api_url.into().trim_end_matches('/').to_string();
        self.content_base_url = content_url.into().trim_end_matches('/').to_string();
        self
    }

    pub fn access_token(&self) -> Option<String> {
        self.access_token.read().clone()
    }
}

/// Parses Dropbox `/2/files/list_folder` JSON payload into `CloudDeltaPage`.
pub fn parse_dropbox_list_folder(
    json_val: &serde_json::Value,
) -> Result<CloudDeltaPage, CloudError> {
    let cursor = json_val
        .get("cursor")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let has_more = json_val
        .get("has_more")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    let mut items = Vec::new();
    if let Some(entries) = json_val.get("entries").and_then(|v| v.as_array()) {
        for entry in entries {
            let tag = entry
                .get(".tag")
                .and_then(|v| v.as_str())
                .unwrap_or_default();
            let is_deleted = tag == "deleted";
            let is_dir = tag == "folder";
            let name = entry
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or_default();
            let id = entry
                .get("id")
                .and_then(|v| v.as_str())
                .or_else(|| entry.get("path_lower").and_then(|v| v.as_str()))
                .unwrap_or_default();

            let path_display = entry
                .get("path_display")
                .and_then(|v| v.as_str())
                .unwrap_or_default();

            let folder_path = path_display
                .rsplit_once('/')
                .map(|(parent, _)| parent.trim_start_matches('/'))
                .unwrap_or_default()
                .replace('/', " / ");

            let size_bytes = entry.get("size").and_then(|v| v.as_u64()).unwrap_or(0);
            let content_hash = entry
                .get("content_hash")
                .or_else(|| entry.get("rev"))
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());

            if is_dir || is_audio_file(name) || is_deleted {
                items.push(CloudItem {
                    id: id.to_string(),
                    name: name.to_string(),
                    size_bytes: if is_dir { 0 } else { size_bytes },
                    is_directory: is_dir,
                    folder_path,
                    mime_type: None,
                    modified_time: None,
                    checksum_or_etag: content_hash,
                    download_url: None,
                    is_deleted,
                });
            }
        }
    }

    Ok(CloudDeltaPage {
        items,
        next_cursor: if has_more { cursor.clone() } else { None },
        new_delta_cursor: if !has_more { cursor } else { None },
        has_more,
    })
}

impl CloudStorageProvider for DropboxProvider {
    fn provider_id(&self) -> &'static str {
        "dropbox"
    }

    fn list_changes(&self, cursor: Option<&str>) -> Result<CloudDeltaPage, CloudError> {
        let token =
            self.access_token.read().clone().ok_or_else(|| {
                CloudError::unauthorized("No active Dropbox access token configured")
            })?;

        let (url, body) = match cursor {
            Some(c) => (
                format!("{}/files/list_folder/continue", self.api_base_url),
                serde_json::json!({ "cursor": c }),
            ),
            None => (
                format!("{}/files/list_folder", self.api_base_url),
                serde_json::json!({
                    "path": self.root_path,
                    "recursive": true,
                    "include_deleted": true
                }),
            ),
        };

        let client = self.client.clone();
        run_async(async move {
            let res = client
                .post(&url)
                .bearer_auth(token)
                .json(&body)
                .send()
                .await
                .map_err(|e| CloudError::network(e.to_string()))?;

            let status = res.status();
            if status == reqwest::StatusCode::UNAUTHORIZED
                || status == reqwest::StatusCode::FORBIDDEN
            {
                return Err(CloudError::unauthorized(format!("HTTP {status}")));
            }
            if !status.is_success() {
                return Err(CloudError::other(format!(
                    "Dropbox list_folder returned {status}"
                )));
            }

            let json: serde_json::Value = res
                .json()
                .await
                .map_err(|e| CloudError::malformed(e.to_string()))?;

            parse_dropbox_list_folder(&json)
        })
    }

    fn fetch_byte_range(
        &self,
        file_id: &str,
        start: u64,
        end_inclusive: u64,
    ) -> Result<Vec<u8>, CloudError> {
        let range_val = build_range_header(start, end_inclusive)?;
        let token = self.access_token.read().clone();
        let url = format!("{}/files/download", self.content_base_url);
        let arg = serde_json::json!({ "path": file_id }).to_string();
        let client = self.client.clone();

        run_async(async move {
            let mut req = client
                .post(&url)
                .header("Dropbox-API-Arg", arg)
                .header(reqwest::header::RANGE, range_val);

            if let Some(tok) = token {
                req = req.bearer_auth(tok);
            }

            let res = req
                .send()
                .await
                .map_err(|e| CloudError::network(e.to_string()))?;

            let status = res.status();
            if status == reqwest::StatusCode::UNAUTHORIZED
                || status == reqwest::StatusCode::FORBIDDEN
            {
                return Err(CloudError::unauthorized(format!("HTTP {status}")));
            }
            if status == reqwest::StatusCode::NOT_FOUND {
                return Err(CloudError::not_found(format!("File {file_id} not found")));
            }
            if !status.is_success() && status != reqwest::StatusCode::PARTIAL_CONTENT {
                return Err(CloudError::other(format!(
                    "Dropbox download returned {status}"
                )));
            }

            let bytes = res
                .bytes()
                .await
                .map_err(|e| CloudError::network(e.to_string()))?;
            Ok(bytes.to_vec())
        })
    }

    fn refresh_credentials_if_needed(&self) -> Result<(), CloudError> {
        let rt =
            self.refresh_token.read().clone().ok_or_else(|| {
                CloudError::unauthorized("No refresh token available for Dropbox")
            })?;

        let client_id = self.client_id.clone();
        let client = self.client.clone();

        run_async(async move {
            let params = [
                ("client_id", client_id.as_str()),
                ("grant_type", "refresh_token"),
                ("refresh_token", rt.as_str()),
            ];

            let res = client
                .post("https://api.dropbox.com/oauth2/token")
                .form(&params)
                .send()
                .await
                .map_err(|e| CloudError::network(e.to_string()))?;

            if !res.status().is_success() {
                return Err(CloudError::unauthorized("Dropbox token refresh rejected"));
            }

            let json: serde_json::Value = res
                .json()
                .await
                .map_err(|e| CloudError::malformed(e.to_string()))?;

            let new_tok = json
                .get("access_token")
                .and_then(|v| v.as_str())
                .ok_or_else(|| CloudError::malformed("Missing access_token in refresh response"))?;

            *self.access_token.write() = Some(new_tok.to_string());
            Ok(())
        })
    }
}

// ---------------------------------------------------------------------------
// 5. Dynamic Provider Registry
// ---------------------------------------------------------------------------

/// Thread-safe registry for dynamic multi-cloud provider lookup and dispatch.
#[derive(Default)]
pub struct ProviderRegistry {
    providers: RwLock<HashMap<String, Arc<dyn CloudStorageProvider>>>,
}

impl ProviderRegistry {
    pub fn new() -> Self {
        Self {
            providers: RwLock::new(HashMap::new()),
        }
    }

    /// Registers a provider instance. If a provider with the same ID already exists, it is replaced.
    pub fn register(&self, provider: Arc<dyn CloudStorageProvider>) {
        let id = provider.provider_id().to_string();
        self.providers.write().insert(id, provider);
    }

    /// Retrieves a registered provider by its ID.
    pub fn get(&self, provider_id: &str) -> Option<Arc<dyn CloudStorageProvider>> {
        self.providers.read().get(provider_id).cloned()
    }

    /// Removes a registered provider by its ID.
    pub fn remove(&self, provider_id: &str) -> Option<Arc<dyn CloudStorageProvider>> {
        self.providers.write().remove(provider_id)
    }

    /// Returns a list of all currently registered provider IDs.
    pub fn registered_ids(&self) -> Vec<String> {
        let mut ids: Vec<String> = self.providers.read().keys().cloned().collect();
        ids.sort();
        ids
    }

    /// Returns true if a provider with the given ID is registered.
    pub fn has_provider(&self, provider_id: &str) -> bool {
        self.providers.read().contains_key(provider_id)
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_range_header() {
        assert_eq!(build_range_header(0, 1023).unwrap(), "bytes=0-1023");
        assert_eq!(build_range_header(500, 500).unwrap(), "bytes=500-500");
        assert!(build_range_header(1000, 500).is_err());
    }

    #[test]
    fn test_base64_encode() {
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"f"), "Zg==");
        assert_eq!(base64_encode(b"fo"), "Zm8=");
        assert_eq!(base64_encode(b"foo"), "Zm9v");
        assert_eq!(base64_encode(b"user:secret123"), "dXNlcjpzZWNyZXQxMjM=");
    }

    #[test]
    fn test_percent_decode_and_unescape() {
        assert_eq!(percent_decode("Hello%20World.flac"), "Hello World.flac");
        assert_eq!(
            percent_decode("Miles%20Davis%2FKind%20of%20Blue"),
            "Miles Davis/Kind of Blue"
        );
        assert_eq!(xml_unescape("Rock &amp; Roll"), "Rock & Roll");
        assert_eq!(xml_unescape("&lt;Track&gt;"), "<Track>");
    }

    #[test]
    fn test_is_audio_file() {
        assert!(is_audio_file("symphony.flac"));
        assert!(is_audio_file("concert.WAV"));
        assert!(is_audio_file("album.alac"));
        assert!(is_audio_file("sacd.dsf"));
        assert!(is_audio_file("track.mp3"));
        assert!(!is_audio_file("cover.jpg"));
        assert!(!is_audio_file("info.txt"));
        assert!(!is_audio_file("folder"));
    }

    #[test]
    fn test_webdav_xml_parsing() {
        let xml = r#"<?xml version="1.0" encoding="utf-8" ?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/remote.php/webdav/Music/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/webdav/Music/Classical/</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>Classical</d:displayname>
        <d:resourcetype><d:collection/></d:resourcetype>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/webdav/Music/01%20-%20So%20What.flac</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>01 - So What.flac</d:displayname>
        <d:getcontentlength>45289124</d:getcontentlength>
        <d:getetag>"5d-598926f7a6e40"</d:getetag>
        <d:resourcetype/>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>"#;

        let items = parse_webdav_multistatus(xml, "/remote.php/webdav/Music").unwrap();
        assert_eq!(items.len(), 2);

        let folder = &items[0];
        assert_eq!(folder.name, "Classical");
        assert!(folder.is_directory);
        assert_eq!(folder.size_bytes, 0);

        let track = &items[1];
        assert_eq!(track.name, "01 - So What.flac");
        assert!(!track.is_directory);
        assert_eq!(track.size_bytes, 45289124);
        assert_eq!(track.checksum_or_etag.as_deref(), Some("5d-598926f7a6e40"));
    }

    #[test]
    fn test_onedrive_delta_json_parsing() {
        let json: serde_json::Value = serde_json::json!({
            "@odata.nextLink": "https://graph.microsoft.com/v1.0/me/drive/root/delta?token=page2",
            "value": [
                {
                    "id": "item1",
                    "name": "Track.flac",
                    "size": 35000000,
                    "file": { "mimeType": "audio/flac" },
                    "parentReference": { "path": "/drive/root:/Music/Jazz" },
                    "eTag": "etag123"
                },
                {
                    "id": "item2",
                    "name": "Jazz",
                    "size": 0,
                    "folder": { "childCount": 1 },
                    "parentReference": { "path": "/drive/root:/Music" }
                },
                {
                    "id": "item3",
                    "name": "Deleted.flac",
                    "deleted": { "state": "deleted" }
                }
            ]
        });

        let page = parse_onedrive_delta(&json).unwrap();
        assert!(page.has_more);
        assert_eq!(
            page.next_cursor.as_deref(),
            Some("https://graph.microsoft.com/v1.0/me/drive/root/delta?token=page2")
        );
        assert_eq!(page.items.len(), 3);

        assert_eq!(page.items[0].name, "Track.flac");
        assert_eq!(page.items[0].size_bytes, 35000000);
        assert!(!page.items[0].is_directory);
        assert_eq!(page.items[0].folder_path, "Music / Jazz");

        assert_eq!(page.items[1].name, "Jazz");
        assert!(page.items[1].is_directory);

        assert_eq!(page.items[2].id, "item3");
        assert!(page.items[2].is_deleted);
    }

    #[test]
    fn test_dropbox_list_folder_json_parsing() {
        let json: serde_json::Value = serde_json::json!({
            "cursor": "cursor_final",
            "has_more": false,
            "entries": [
                {
                    ".tag": "file",
                    "id": "id:file1",
                    "name": "01.dsf",
                    "size": 105000000,
                    "path_display": "/Music/DSD/01.dsf",
                    "content_hash": "hash_dsd_123"
                },
                {
                    ".tag": "folder",
                    "id": "id:folder1",
                    "name": "DSD",
                    "path_display": "/Music/DSD"
                },
                {
                    ".tag": "deleted",
                    "name": "removed.wav",
                    "path_display": "/Music/DSD/removed.wav"
                }
            ]
        });

        let page = parse_dropbox_list_folder(&json).unwrap();
        assert!(!page.has_more);
        assert_eq!(page.new_delta_cursor.as_deref(), Some("cursor_final"));
        assert_eq!(page.items.len(), 3);

        assert_eq!(page.items[0].name, "01.dsf");
        assert_eq!(page.items[0].size_bytes, 105000000);
        assert_eq!(
            page.items[0].checksum_or_etag.as_deref(),
            Some("hash_dsd_123")
        );

        assert_eq!(page.items[1].name, "DSD");
        assert!(page.items[1].is_directory);

        assert!(page.items[2].is_deleted);
    }

    #[test]
    fn test_google_drive_changes_and_files_parsing() {
        let changes_json = serde_json::json!({
            "newStartPageToken": "start_token_123",
            "changes": [
                {
                    "fileId": "gdrive_f1",
                    "removed": false,
                    "file": {
                        "id": "gdrive_f1",
                        "name": "HiRes.flac",
                        "mimeType": "audio/flac",
                        "size": "45000000",
                        "md5Checksum": "md5_abc",
                        "trashed": false
                    }
                },
                {
                    "fileId": "gdrive_f2",
                    "removed": true
                }
            ]
        });

        let delta_page = parse_google_drive_changes(&changes_json).unwrap();
        assert!(!delta_page.has_more);
        assert_eq!(
            delta_page.new_delta_cursor.as_deref(),
            Some("start_token_123")
        );
        assert_eq!(delta_page.items.len(), 2);
        assert_eq!(delta_page.items[0].name, "HiRes.flac");
        assert_eq!(delta_page.items[0].size_bytes, 45000000);
        assert!(delta_page.items[1].is_deleted);

        let files_json = serde_json::json!({
            "nextPageToken": "page2_token",
            "files": [
                {
                    "id": "gdrive_folder",
                    "name": "FLAC",
                    "mimeType": "application/vnd.google-apps.folder",
                    "trashed": false
                }
            ]
        });

        let files_page = parse_google_drive_files(&files_json).unwrap();
        assert!(files_page.has_more);
        assert_eq!(files_page.next_cursor.as_deref(), Some("page2_token"));
        assert_eq!(files_page.items.len(), 1);
        assert!(files_page.items[0].is_directory);
    }

    #[test]
    fn test_provider_registry_lifecycle() {
        let registry = ProviderRegistry::new();
        assert!(!registry.has_provider("webdav"));
        assert!(!registry.has_provider("onedrive"));

        let webdav = Arc::new(WebDavProvider::with_basic_auth(
            "https://nas.local/Music",
            "user",
            "pass",
        ));
        let onedrive = Arc::new(OneDriveProvider::new(
            "client-123",
            Some("tok".into()),
            None,
        ));
        let gdrive = Arc::new(GoogleDriveProvider::new(Some("g-tok".into())));
        let dropbox = Arc::new(DropboxProvider::new(
            "db-id",
            Some("d-tok".into()),
            None,
            "/Music",
        ));

        registry.register(webdav);
        registry.register(onedrive);
        registry.register(gdrive);
        registry.register(dropbox);

        assert!(registry.has_provider("webdav"));
        assert!(registry.has_provider("onedrive"));
        assert!(registry.has_provider("google_drive"));
        assert!(registry.has_provider("dropbox"));

        let ids = registry.registered_ids();
        assert_eq!(ids, vec!["dropbox", "google_drive", "onedrive", "webdav"]);

        let fetched = registry.get("webdav").unwrap();
        assert_eq!(fetched.provider_id(), "webdav");

        let removed = registry.remove("onedrive");
        assert!(removed.is_some());
        assert!(!registry.has_provider("onedrive"));
        assert_eq!(
            registry.registered_ids(),
            vec!["dropbox", "google_drive", "webdav"]
        );
    }
}

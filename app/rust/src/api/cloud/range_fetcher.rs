use crate::api::cloud::models::RangeMeasurement;
use anyhow::{anyhow, Result};
use reqwest::header::{HeaderMap, HeaderValue, AUTHORIZATION, RANGE};
use std::time::Instant;

pub struct RangeFetcher {
    client: reqwest::Client,
}

impl RangeFetcher {
    pub fn new() -> Result<Self> {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .build()?;
        Ok(Self { client })
    }

    /// Fetches a specific byte range over HTTP and returns the data along with latency measurements.
    pub async fn fetch_range(
        &self,
        url: &str,
        start_byte: u64,
        end_byte: u64,
        auth_token: Option<&str>,
    ) -> Result<(Vec<u8>, RangeMeasurement)> {
        let range_val = format!("bytes={}-{}", start_byte, end_byte);
        let mut headers = HeaderMap::new();
        headers.insert(RANGE, HeaderValue::from_str(&range_val)?);

        if let Some(token) = auth_token {
            headers.insert(
                AUTHORIZATION,
                HeaderValue::from_str(&format!("Bearer {}", token))?,
            );
        }

        let start_time = Instant::now();

        let req = self.client.get(url).headers(headers);
        let response = req.send().await?;
        let ttfb = start_time.elapsed();

        let status = response.status();
        if !status.is_success() && status.as_u16() != 206 {
            return Err(anyhow!(
                "HTTP request failed with status: {} (range: {})",
                status,
                range_val
            ));
        }

        let bytes = response.bytes().await?;
        let total_time = start_time.elapsed();
        let bytes_len = bytes.len();

        let elapsed_secs = total_time.as_secs_f64();
        let speed_mbps = if elapsed_secs > 0.0 {
            (bytes_len as f64 * 8.0) / (elapsed_secs * 1_000_000.0)
        } else {
            0.0
        };

        let measurement = RangeMeasurement {
            url: url.to_string(),
            range_header: range_val,
            status_code: status.as_u16(),
            dns_and_connect_time: ttfb,
            time_to_first_byte: ttfb,
            total_download_time: total_time,
            bytes_downloaded: bytes_len,
            speed_mbps,
        };

        Ok((bytes.to_vec(), measurement))
    }
}

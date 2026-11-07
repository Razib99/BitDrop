//! Direct Stream Digital (DSD) container parsing, decimation, and DoP v1.1 framing.

pub mod decimator;
pub mod dop;
pub mod dsf;

use std::fmt;

/// DSD parsing and streaming errors.
#[derive(Debug)]
pub enum DsdError {
    /// File does not start with valid DSD magic bytes (`DSD ` or `FRM8`).
    InvalidMagic,
    /// Unsupported DSF format version (only version 1 is supported).
    UnsupportedVersion(u32),
    /// Corrupt or malformed header chunk.
    InvalidHeader(&'static str),
    /// Channel count is not supported (only mono, stereo, or 6-channel).
    UnsupportedChannelCount(u32),
    /// Sampling frequency is not recognized as standard DSD rate.
    UnsupportedSampleRate(u32),
    /// Underlying I/O error occurred during stream reading or seeking.
    Io(std::io::Error),
    /// Unexpected end of file encountered before chunk completed.
    UnexpectedEof,
}

impl fmt::Display for DsdError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidMagic => write!(f, "Invalid DSD container magic bytes"),
            Self::UnsupportedVersion(v) => write!(f, "Unsupported DSF version: {v}"),
            Self::InvalidHeader(msg) => write!(f, "Malformed DSD header: {msg}"),
            Self::UnsupportedChannelCount(c) => write!(f, "Unsupported DSD channel count: {c}"),
            Self::UnsupportedSampleRate(sr) => write!(f, "Unsupported DSD sample rate: {sr} Hz"),
            Self::Io(e) => write!(f, "DSD I/O error: {e}"),
            Self::UnexpectedEof => write!(f, "Unexpected end of DSD stream"),
        }
    }
}

impl std::error::Error for DsdError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<std::io::Error> for DsdError {
    fn from(err: std::io::Error) -> Self {
        Self::Io(err)
    }
}

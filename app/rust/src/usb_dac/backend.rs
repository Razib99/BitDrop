//! User-space USB Audio Class (Tier D) Backend and Failover Management.
//!
//! Bridges BitDrop's core audio engine with the user-space `usbfs` driver,
//! managing device attachment, interface claiming, sample rate / format negotiation,
//! real-time isochronous streaming, and failover back to standard system audio.

use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;

use parking_lot::Mutex;

use crate::usb_dac::controls::negotiate_device_sample_rate;
use crate::usb_dac::descriptors::{AudioClassProtocol, ParsedAudioDevice};
use crate::usb_dac::streaming::{
    AudioPacer, AudioSampleSource, PacerMode, PcmFormat, UsbStreamConfig, UsbStreamHandle,
    UsbStreamingEngine,
};
use crate::usb_dac::usbfs::{UsbDeviceHandle, UsbFsError};

/// Active stream output backend.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamBackend {
    /// Standard OS audio backend (Oboe/AAudio on Android, CPAL on Linux).
    Standard,
    /// Direct user-space USB DAC bit-perfect bypass (Tier D).
    DirectUsb,
}

impl StreamBackend {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Standard => "Standard",
            Self::DirectUsb => "DirectUsb",
        }
    }
}

/// Real-time diagnostic telemetry for the active Tier D direct USB stream.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct UsbDacDiagnostics {
    pub is_active: bool,
    pub device_name: String,
    pub sample_rate: u32,
    pub bit_depth: u8,
    pub channels: u8,
    pub format_name: String,
    pub pacer_mode: String,
    pub frames_played: u64,
    pub underruns: u32,
    pub feedback_rate_q16: u32,
}

/// Internal session state for an active Direct USB DAC stream.
pub struct DirectUsbSession {
    pub handle: Arc<UsbDeviceHandle>,
    pub stream_handle: UsbStreamHandle,
    pub streaming_iface: u32,
    pub control_iface: Option<u32>,
    pub diagnostics: UsbDacDiagnostics,
}

/// Dedicated audio renderer bridge feeding the USB isochronous streaming loop.
pub struct UsbAudioSource {
    pub renderer: crate::renderer::OutputRenderer,
}

impl AudioSampleSource for UsbAudioSource {
    fn render_audio_frames(&mut self, out_slice: &mut [f32], channels: usize) -> bool {
        match self.renderer.render_interleaved(out_slice, channels) {
            crate::renderer::RenderAction::Continue => true,
            crate::renderer::RenderAction::Stop => false,
        }
    }
}

impl Drop for UsbAudioSource {
    fn drop(&mut self) {
        crate::api::audio_engine::return_audio_consumers(
            self.renderer.consumer.take(),
            self.renderer.boundary_consumer.take(),
            self.renderer.triggered_producer.take(),
        );
    }
}

lazy_static::lazy_static! {
    static ref ACTIVE_USB_SESSION: Mutex<Option<DirectUsbSession>> = Mutex::new(None);
}

static STREAM_BACKEND: AtomicU32 = AtomicU32::new(0); // 0 = Standard, 1 = DirectUsb
static FAILOVER_IN_PROGRESS: AtomicBool = AtomicBool::new(false);
static HOT_DISCONNECTED: AtomicBool = AtomicBool::new(false);

/// Returns whether a physical hot-disconnect occurred.
pub fn is_hot_disconnected() -> bool {
    HOT_DISCONNECTED.load(Ordering::Acquire)
}

/// Sets the hot-disconnect status.
pub fn set_hot_disconnected(val: bool) {
    HOT_DISCONNECTED.store(val, Ordering::Release);
}

/// Returns the currently active stream backend.
pub fn get_active_stream_backend() -> StreamBackend {
    if STREAM_BACKEND.load(Ordering::Acquire) == 1 {
        StreamBackend::DirectUsb
    } else {
        StreamBackend::Standard
    }
}

/// Sets the currently active stream backend indicator.
pub fn set_active_stream_backend(backend: StreamBackend) {
    let val = match backend {
        StreamBackend::Standard => 0,
        StreamBackend::DirectUsb => 1,
    };
    STREAM_BACKEND.store(val, Ordering::Release);
}

/// Queries real-time diagnostics of the active USB DAC stream.
pub fn get_usb_dac_diagnostics() -> UsbDacDiagnostics {
    let guard = ACTIVE_USB_SESSION.lock();
    if let Some(ref session) = *guard {
        let mut diag = session.diagnostics.clone();
        diag.frames_played = session.stream_handle.frames_played();
        diag.underruns = session.stream_handle.underruns();
        diag.is_active = session.stream_handle.is_running();
        diag
    } else {
        UsbDacDiagnostics::default()
    }
}

/// Checks whether a Direct USB DAC streaming session is currently running.
pub fn is_direct_usb_active() -> bool {
    let guard = ACTIVE_USB_SESSION.lock();
    guard
        .as_ref()
        .map(|s| s.stream_handle.is_running())
        .unwrap_or(false)
}

/// Attaches and activates a direct user-space USB DAC session from a raw Android/Linux file descriptor.
///
/// Steps executed:
/// 1. Wraps raw fd into borrowed `UsbDeviceHandle` (preserved across Kotlin connection lifecycle).
/// 2. Reads and parses the full USB Audio Class configuration descriptor hierarchy.
/// 3. Selects optimal Audio Streaming alternate setting matching requested bit depth.
/// 4. Detaches kernel driver (`snd-usb-audio`) and claims interfaces for user-space access.
/// 5. Negotiates hardware sample rate on UAC2 clock source / UAC1 endpoint.
/// 6. Activates isochronous alternate setting and launches real-time streaming ring.
pub fn attach_direct_usb_device<S: AudioSampleSource + 'static>(
    fd: std::os::unix::io::RawFd,
    preferred_sample_rate: u32,
    preferred_bit_depth: u32,
    source: S,
) -> Result<UsbDacDiagnostics, UsbFsError> {
    // 1. Wrap raw descriptor borrowed from Kotlin
    let handle = Arc::new(UsbDeviceHandle::from_raw_fd_borrowed(fd));

    // 2. Fetch and parse configuration descriptor
    let desc_bytes = handle.get_active_config_descriptor()?;
    let parsed = ParsedAudioDevice::parse(&desc_bytes).map_err(|_| UsbFsError::InvalidArgument)?;

    // 3. Find optimal streaming alternate setting
    let (streaming_iface_info, best_alt) = parsed
        .find_best_streaming_alt(preferred_bit_depth as u8)
        .ok_or(UsbFsError::InvalidArgument)?;

    let format_info = best_alt
        .format
        .as_ref()
        .ok_or(UsbFsError::InvalidArgument)?;
    let pcm_format = PcmFormat::from_format_info(format_info).ok_or(UsbFsError::InvalidArgument)?;
    let data_ep = best_alt
        .data_endpoint
        .clone()
        .ok_or(UsbFsError::InvalidArgument)?;
    let feedback_ep = best_alt.feedback_endpoint.clone();

    let streaming_iface = streaming_iface_info.interface_number as u32;
    let control_iface = parsed
        .control_interface
        .as_ref()
        .map(|c| c.interface_number as u32);

    // 4. Detach kernel driver and claim streaming interface
    handle.disconnect_kernel_driver(streaming_iface)?;
    handle.claim_interface(streaming_iface)?;

    // Claim control interface if separate
    if let Some(ctrl_num) = control_iface {
        if ctrl_num != streaming_iface {
            let _ = handle.disconnect_kernel_driver(ctrl_num);
            let _ = handle.claim_interface(ctrl_num);
        }
    }

    // 5. Negotiate hardware sample rate
    let target_rate = if preferred_sample_rate > 0 {
        preferred_sample_rate
    } else {
        48000
    };
    let negotiated_rate = match negotiate_device_sample_rate(&handle, &parsed, target_rate) {
        Ok(rate) => rate,
        Err(e) => {
            // Cleanup on failure
            let _ = handle.release_interface(streaming_iface);
            if let Some(ctrl_num) = control_iface {
                if ctrl_num != streaming_iface {
                    let _ = handle.release_interface(ctrl_num);
                }
            }
            return Err(e);
        }
    };

    // 6. Set alternate setting to activate isochronous endpoint
    if let Err(e) = handle.set_interface_alt(streaming_iface, best_alt.alt_setting as u32) {
        let _ = handle.release_interface(streaming_iface);
        if let Some(ctrl_num) = control_iface {
            if ctrl_num != streaming_iface {
                let _ = handle.release_interface(ctrl_num);
            }
        }
        return Err(e);
    }

    // 7. Configure isochronous streaming session
    let pacer_mode = AudioPacer::auto_detect_mode(&data_ep, &feedback_ep);
    let is_high_speed = parsed.protocol == AudioClassProtocol::Uac2 || data_ep.interval == 1;

    let stream_config = UsbStreamConfig {
        data_endpoint: data_ep,
        feedback_endpoint: feedback_ep,
        sample_rate: negotiated_rate,
        channels: format_info.channels,
        format: pcm_format,
        pacer_mode,
        is_high_speed,
        num_urbs: 4,
    };

    // 8. Start streaming worker thread
    let stream_handle =
        match UsbStreamingEngine::start_stream(Arc::clone(&handle), stream_config, source) {
            Ok(sh) => sh,
            Err(e) => {
                let _ = handle.set_interface_alt(streaming_iface, 0);
                let _ = handle.release_interface(streaming_iface);
                if let Some(ctrl_num) = control_iface {
                    if ctrl_num != streaming_iface {
                        let _ = handle.release_interface(ctrl_num);
                    }
                }
                return Err(e);
            }
        };

    let proto_str = match parsed.protocol {
        AudioClassProtocol::Uac1 => "UAC1",
        AudioClassProtocol::Uac2 => "UAC2",
    };

    let pacer_mode_str = match pacer_mode {
        PacerMode::AdaptiveNominal => "Implicit/Nominal Pacing".to_string(),
        PacerMode::AsynchronousFeedback => {
            if parsed.protocol == AudioClassProtocol::Uac2 {
                "Explicit Feedback 16.16".to_string()
            } else {
                "Explicit Feedback 10.14".to_string()
            }
        }
    };

    let diagnostics = UsbDacDiagnostics {
        is_active: true,
        device_name: format!("Direct USB DAC ({proto_str})"),
        sample_rate: negotiated_rate,
        bit_depth: format_info.bit_resolution,
        channels: format_info.channels,
        format_name: format!("{:?}", pcm_format),
        pacer_mode: pacer_mode_str,
        frames_played: 0,
        underruns: 0,
        feedback_rate_q16: 0,
    };

    let session = DirectUsbSession {
        handle,
        stream_handle,
        streaming_iface,
        control_iface,
        diagnostics: diagnostics.clone(),
    };

    // Store active session and switch backend flag
    *ACTIVE_USB_SESSION.lock() = Some(session);
    set_active_stream_backend(StreamBackend::DirectUsb);

    Ok(diagnostics)
}

/// Detaches active USB DAC session and cleanly releases hardware interfaces.
pub fn detach_direct_usb_device() -> Result<(), UsbFsError> {
    if let Some(mut session) = ACTIVE_USB_SESSION.lock().take() {
        let _ = session.stream_handle.stop();
        // Drain any remaining in-flight URBs via USBDEVFS_REAPURBNDELAY before releasing interfaces,
        // ensuring the kernel xHCI controller never touches user-space memory after teardown.
        while session.handle.reap_urb_ndelay().is_ok() {}
        let _ = session.handle.set_interface_alt(session.streaming_iface, 0);
        let _ = session.handle.release_interface(session.streaming_iface);
        if let Some(ctrl_num) = session.control_iface {
            if ctrl_num != session.streaming_iface {
                let _ = session.handle.release_interface(ctrl_num);
            }
        }
    }
    set_active_stream_backend(StreamBackend::Standard);
    Ok(())
}

/// Checks whether failover is needed and executes it safely if the USB stream worker failed.
///
/// Returns `true` if failover was triggered.
pub fn check_and_execute_failover<F: FnOnce(bool)>(on_fallback_needed: F) -> bool {
    let (needs_failover, was_hot) = {
        let hot = is_hot_disconnected();
        let guard = ACTIVE_USB_SESSION.lock();
        if let Some(ref session) = *guard {
            (hot || !session.stream_handle.is_running(), hot)
        } else {
            (hot, hot)
        }
    };

    if needs_failover
        && FAILOVER_IN_PROGRESS
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Relaxed)
            .is_ok()
    {
        set_hot_disconnected(false);
        eprintln!(
            "[bitdrop] USB DAC stream terminated (hot_disconnect={was_hot}); executing automatic failover to standard output"
        );
        let _ = detach_direct_usb_device();
        on_fallback_needed(was_hot);
        FAILOVER_IN_PROGRESS.store(false, Ordering::Release);
        return true;
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_stream_backend_toggle_and_strings() {
        set_active_stream_backend(StreamBackend::Standard);
        assert_eq!(get_active_stream_backend(), StreamBackend::Standard);
        assert_eq!(StreamBackend::Standard.as_str(), "Standard");

        set_active_stream_backend(StreamBackend::DirectUsb);
        assert_eq!(get_active_stream_backend(), StreamBackend::DirectUsb);
        assert_eq!(StreamBackend::DirectUsb.as_str(), "DirectUsb");

        // Clean up
        set_active_stream_backend(StreamBackend::Standard);
    }

    #[test]
    fn test_diagnostics_default_when_inactive() {
        let diag = get_usb_dac_diagnostics();
        assert!(!diag.is_active);
        assert_eq!(diag.sample_rate, 0);
        assert_eq!(diag.frames_played, 0);
        assert!(!is_direct_usb_active());
    }

    #[test]
    fn test_detach_when_no_active_session_succeeds() {
        let res = detach_direct_usb_device();
        assert!(res.is_ok());
        assert_eq!(get_active_stream_backend(), StreamBackend::Standard);
    }

    #[test]
    fn test_attach_invalid_fd_fails_gracefully() {
        struct DummySource;
        impl AudioSampleSource for DummySource {
            fn render_audio_frames(&mut self, _out_slice: &mut [f32], _channels: usize) -> bool {
                true
            }
        }

        // Passing an invalid raw fd (-1) must return Err and not panic
        let res = attach_direct_usb_device(-1, 48000, 24, DummySource);
        assert!(res.is_err());
        assert_eq!(get_active_stream_backend(), StreamBackend::Standard);
    }

    #[test]
    fn test_failover_when_inactive_does_nothing() {
        let mut called = false;
        let triggered = check_and_execute_failover(|_| {
            called = true;
        });
        assert!(!triggered);
        assert!(!called);
    }

    #[test]
    fn test_hot_disconnect_triggers_failover() {
        set_hot_disconnected(true);
        assert!(is_hot_disconnected());
        let mut fallback_hot = None;
        let triggered = check_and_execute_failover(|hot| {
            fallback_hot = Some(hot);
        });
        assert!(triggered);
        assert_eq!(fallback_hot, Some(true));
        assert!(!is_hot_disconnected());
    }
}

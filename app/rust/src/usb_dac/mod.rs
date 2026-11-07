//! User-space USB Audio Class (UAC1/UAC2) Driver.
//!
//! Provides direct bit-perfect hardware bypass for USB DACs on Android 12+ and Linux.

pub mod backend;
pub mod controls;
pub mod descriptors;
pub mod streaming;
pub mod usbfs;

pub use backend::{
    attach_direct_usb_device, check_and_execute_failover, detach_direct_usb_device,
    get_active_stream_backend, get_usb_dac_diagnostics, is_direct_usb_active,
    set_active_stream_backend, DirectUsbSession, StreamBackend, UsbAudioSource, UsbDacDiagnostics,
};

pub use controls::{
    negotiate_device_sample_rate, parse_uac2_sample_rate_ranges, parse_uac2_volume_range,
    uac1_get_sample_rate, uac1_set_sample_rate, uac2_get_sample_rate, uac2_get_sample_rate_ranges,
    uac2_get_volume_range, uac2_set_mute, uac2_set_sample_rate, uac2_set_volume,
    HardwareVolumeRange, SampleRateRange,
};
pub use descriptors::{
    AudioClassProtocol, AudioControlInterface, AudioFormatInfo, AudioStreamingInterface,
    DescriptorParseError, EndpointDirection, EndpointInfo, EndpointSyncType, EndpointUsageType,
    ParsedAudioDevice, StreamingAltSetting,
};
pub use streaming::{
    AudioPacer, AudioSampleSource, CallbackAudioSource, IsoRingBuffer, PacerMode, PcmFormat,
    UsbStreamConfig, UsbStreamHandle, UsbStreamingEngine, DEFAULT_IN_FLIGHT_URBS,
    DEFAULT_PACKETS_PER_URB,
};
pub use usbfs::{
    IsoUrb, UsbDeviceHandle, UsbFsError, UsbdevfsCtrlTransfer, UsbdevfsDisconnectClaim,
    UsbdevfsIsoPacketDesc, UsbdevfsSetInterface, UsbdevfsUrb,
};

//! USB Audio Class (UAC1 and UAC2) Descriptor Parser.
//!
//! Parses the raw configuration descriptor hierarchy from any connected USB DAC into
//! structured Audio Control and Audio Streaming topology trees.

use std::fmt;

/// Supported USB Audio Class protocols.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum AudioClassProtocol {
    Uac1,
    Uac2,
}

impl fmt::Display for AudioClassProtocol {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Uac1 => write!(f, "UAC 1.0"),
            Self::Uac2 => write!(f, "UAC 2.0"),
        }
    }
}

/// Direction of USB endpoint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EndpointDirection {
    Out,
    In,
}

/// Isochronous synchronization mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EndpointSyncType {
    NoSync,
    Asynchronous,
    Adaptive,
    Synchronous,
}

/// Isochronous endpoint usage type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EndpointUsageType {
    Data,
    Feedback,
    ImplicitFeedback,
    Reserved,
}

/// Strongly-typed information for a USB endpoint.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EndpointInfo {
    pub address: u8,
    pub direction: EndpointDirection,
    pub sync_type: EndpointSyncType,
    pub usage_type: EndpointUsageType,
    pub max_packet_size: u16,
    pub interval: u8,
    pub refresh: u8,
    pub synch_address: u8,
}

/// Formats supported by an Audio Streaming alternate setting.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AudioFormatInfo {
    pub protocol: AudioClassProtocol,
    pub channels: u8,
    pub bit_resolution: u8,
    pub subslot_size: u8,
    /// Discrete sample rates advertised by UAC1 descriptors.
    /// Note: UAC2 sample rates are queried at runtime via Clock Source Range transfers.
    pub sample_rates: Vec<u32>,
}

/// Single alternate setting within an Audio Streaming interface.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StreamingAltSetting {
    pub alt_setting: u8,
    pub format: Option<AudioFormatInfo>,
    pub data_endpoint: Option<EndpointInfo>,
    pub feedback_endpoint: Option<EndpointInfo>,
}

/// Audio Streaming interface containing one or more alternate settings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AudioStreamingInterface {
    pub interface_number: u8,
    pub protocol: AudioClassProtocol,
    pub alt_settings: Vec<StreamingAltSetting>,
}

/// Audio Control topology entities.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AudioControlInterface {
    pub interface_number: u8,
    pub protocol: AudioClassProtocol,
    pub clock_source_ids: Vec<u8>,
    pub clock_selector_ids: Vec<u8>,
    pub feature_unit_ids: Vec<u8>,
    pub input_terminal_ids: Vec<u8>,
    pub output_terminal_ids: Vec<u8>,
}

/// Top-level parsed USB Audio Device representation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedAudioDevice {
    pub protocol: AudioClassProtocol,
    pub control_interface: Option<AudioControlInterface>,
    pub streaming_interfaces: Vec<AudioStreamingInterface>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DescriptorParseError {
    EmptyDescriptor,
    InvalidHeaderLength { expected: usize, actual: usize },
    InvalidTotalLength { total: usize, buffer_len: usize },
    MalformedDescriptor { offset: usize, reason: String },
    NoAudioInterfacesFound,
}

impl fmt::Display for DescriptorParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptyDescriptor => write!(f, "Descriptor buffer is empty"),
            Self::InvalidHeaderLength { expected, actual } => {
                write!(f, "Invalid header length: expected >= {expected}, got {actual}")
            }
            Self::InvalidTotalLength { total, buffer_len } => {
                write!(f, "wTotalLength {total} exceeds descriptor buffer size {buffer_len}")
            }
            Self::MalformedDescriptor { offset, reason } => {
                write!(f, "Malformed descriptor at byte offset {offset}: {reason}")
            }
            Self::NoAudioInterfacesFound => write!(f, "No USB Audio Class interfaces discovered in configuration"),
        }
    }
}

impl std::error::Error for DescriptorParseError {}

// Standard USB Descriptor Types
const USB_DT_CONFIG: u8 = 2;
const USB_DT_INTERFACE: u8 = 4;
const USB_DT_ENDPOINT: u8 = 5;
const USB_DT_IAD: u8 = 11;

// Audio Class Codes
const USB_CLASS_AUDIO: u8 = 1;
const AUDIO_SUBCLASS_CONTROL: u8 = 1;
const AUDIO_SUBCLASS_STREAMING: u8 = 2;

const _AUDIO_PROTOCOL_UAC1: u8 = 0x00;
const AUDIO_PROTOCOL_UAC2: u8 = 0x20;

// Class-Specific Descriptor Types
const CS_INTERFACE: u8 = 0x24;

// Audio Control Subtypes
const AC_HEADER: u8 = 0x01;
const AC_INPUT_TERMINAL: u8 = 0x02;
const AC_OUTPUT_TERMINAL: u8 = 0x03;
const AC_FEATURE_UNIT: u8 = 0x06;
const AC_CLOCK_SOURCE: u8 = 0x0B;
const AC_CLOCK_SELECTOR: u8 = 0x0C;

// Audio Streaming Subtypes
const AS_GENERAL: u8 = 0x01;
const AS_FORMAT_TYPE: u8 = 0x02;

impl ParsedAudioDevice {
    /// Parses configuration descriptor bytes into a structured `ParsedAudioDevice`.
    pub fn parse(data: &[u8]) -> Result<Self, DescriptorParseError> {
        if data.is_empty() {
            return Err(DescriptorParseError::EmptyDescriptor);
        }
        if data.len() < 9 {
            return Err(DescriptorParseError::InvalidHeaderLength {
                expected: 9,
                actual: data.len(),
            });
        }
        if data[1] != USB_DT_CONFIG {
            return Err(DescriptorParseError::MalformedDescriptor {
                offset: 1,
                reason: format!("Expected USB_DT_CONFIG (2), got {}", data[1]),
            });
        }

        let total_length = u16::from_le_bytes([data[2], data[3]]) as usize;
        let limit = total_length.min(data.len());

        let mut offset = 9;
        let mut overall_protocol = AudioClassProtocol::Uac1;

        let mut current_control: Option<AudioControlInterface> = None;
        let mut streaming_interfaces: Vec<AudioStreamingInterface> = Vec::new();

        let mut current_streaming_iface_idx: Option<usize> = None;
        let mut current_alt_setting: Option<StreamingAltSetting> = None;

        while offset < limit {
            let desc_len = data[offset] as usize;
            if desc_len == 0 || offset + desc_len > limit {
                break;
            }

            let desc_type = data[offset + 1];
            let desc_slice = &data[offset..offset + desc_len];

            match desc_type {
                USB_DT_IAD => {
                    // Check if this IAD declares UAC2 protocol
                    if desc_len >= 8 && desc_slice[4] == USB_CLASS_AUDIO && desc_slice[6] == AUDIO_PROTOCOL_UAC2 {
                        overall_protocol = AudioClassProtocol::Uac2;
                    }
                }

                USB_DT_INTERFACE => {
                    // Flush existing active alt setting if present
                    if let (Some(iface_idx), Some(alt)) = (current_streaming_iface_idx, current_alt_setting.take()) {
                        streaming_interfaces[iface_idx].alt_settings.push(alt);
                    }

                    if desc_len >= 9 {
                        let iface_nr = desc_slice[2];
                        let alt_setting = desc_slice[3];
                        let iface_class = desc_slice[5];
                        let iface_subclass = desc_slice[6];
                        let iface_proto = desc_slice[7];

                        if iface_class == USB_CLASS_AUDIO {
                            let proto = if iface_proto == AUDIO_PROTOCOL_UAC2 || overall_protocol == AudioClassProtocol::Uac2 {
                                overall_protocol = AudioClassProtocol::Uac2;
                                AudioClassProtocol::Uac2
                            } else {
                                AudioClassProtocol::Uac1
                            };

                            match iface_subclass {
                                AUDIO_SUBCLASS_CONTROL => {
                                    current_streaming_iface_idx = None;
                                    if current_control.is_none() {
                                        current_control = Some(AudioControlInterface {
                                            interface_number: iface_nr,
                                            protocol: proto,
                                            clock_source_ids: Vec::new(),
                                            clock_selector_ids: Vec::new(),
                                            feature_unit_ids: Vec::new(),
                                            input_terminal_ids: Vec::new(),
                                            output_terminal_ids: Vec::new(),
                                        });
                                    }
                                }
                                AUDIO_SUBCLASS_STREAMING => {
                                    // Find or create streaming interface entry
                                    let idx = match streaming_interfaces.iter().position(|s| s.interface_number == iface_nr) {
                                        Some(existing) => existing,
                                        None => {
                                            streaming_interfaces.push(AudioStreamingInterface {
                                                interface_number: iface_nr,
                                                protocol: proto,
                                                alt_settings: Vec::new(),
                                            });
                                            streaming_interfaces.len() - 1
                                        }
                                    };
                                    current_streaming_iface_idx = Some(idx);
                                    current_alt_setting = Some(StreamingAltSetting {
                                        alt_setting,
                                        format: None,
                                        data_endpoint: None,
                                        feedback_endpoint: None,
                                    });
                                }
                                _ => {
                                    current_streaming_iface_idx = None;
                                }
                            }
                        } else {
                            current_streaming_iface_idx = None;
                        }
                    }
                }

                CS_INTERFACE if desc_len >= 3 => {
                    let subtype = desc_slice[2];
                    if current_streaming_iface_idx.is_some() {
                        if let Some(ref mut alt) = current_alt_setting {
                            match subtype {
                                AS_GENERAL => {
                                    // UAC2 AS General includes channel count & format tags
                                    if overall_protocol == AudioClassProtocol::Uac2 && desc_len >= 16 {
                                        let channels = desc_slice[10];
                                        let format = alt.format.get_or_insert_with(|| AudioFormatInfo {
                                            protocol: AudioClassProtocol::Uac2,
                                            channels,
                                            bit_resolution: 0,
                                            subslot_size: 0,
                                            sample_rates: Vec::new(),
                                        });
                                        format.channels = channels;
                                    }
                                }
                                AS_FORMAT_TYPE if desc_len >= 6 => {
                                    let format_type = desc_slice[3];
                                    if format_type == 1 {
                                        // Format Type I
                                        if overall_protocol == AudioClassProtocol::Uac2 {
                                            let subslot = desc_slice[4];
                                            let bit_res = desc_slice[5];
                                            let format = alt.format.get_or_insert_with(|| AudioFormatInfo {
                                                protocol: AudioClassProtocol::Uac2,
                                                channels: 2,
                                                bit_resolution: bit_res,
                                                subslot_size: subslot,
                                                sample_rates: Vec::new(),
                                            });
                                            format.subslot_size = subslot;
                                            format.bit_resolution = bit_res;
                                        } else {
                                            // UAC1 Format Type I
                                            let channels = desc_slice[4];
                                            let subslot = desc_slice[5];
                                            let bit_res = desc_slice[6];
                                            let sam_freq_type = if desc_len >= 8 { desc_slice[7] } else { 0 };

                                            let mut rates = Vec::new();
                                            if sam_freq_type > 0 {
                                                let mut f_offset = 8;
                                                for _ in 0..sam_freq_type {
                                                    if f_offset + 3 <= desc_len {
                                                        let r = desc_slice[f_offset] as u32
                                                            | ((desc_slice[f_offset + 1] as u32) << 8)
                                                            | ((desc_slice[f_offset + 2] as u32) << 16);
                                                        rates.push(r);
                                                        f_offset += 3;
                                                    }
                                                }
                                            }

                                            alt.format = Some(AudioFormatInfo {
                                                protocol: AudioClassProtocol::Uac1,
                                                channels,
                                                bit_resolution: bit_res,
                                                subslot_size: subslot,
                                                sample_rates: rates,
                                            });
                                        }
                                    }
                                }
                                _ => {}
                            }
                        }
                    } else if let Some(ref mut ac) = current_control {
                        match subtype {
                            AC_HEADER if desc_len >= 5 => {
                                let bcd_adc = u16::from_le_bytes([desc_slice[3], desc_slice[4]]);
                                if bcd_adc >= 0x0200 {
                                    ac.protocol = AudioClassProtocol::Uac2;
                                    overall_protocol = AudioClassProtocol::Uac2;
                                }
                            }
                            AC_CLOCK_SOURCE if desc_len >= 4 => {
                                ac.clock_source_ids.push(desc_slice[3]);
                            }
                            AC_CLOCK_SELECTOR if desc_len >= 4 => {
                                ac.clock_selector_ids.push(desc_slice[3]);
                            }
                            AC_FEATURE_UNIT if desc_len >= 4 => {
                                ac.feature_unit_ids.push(desc_slice[3]);
                            }
                            AC_INPUT_TERMINAL if desc_len >= 4 => {
                                ac.input_terminal_ids.push(desc_slice[3]);
                            }
                            AC_OUTPUT_TERMINAL if desc_len >= 4 => {
                                ac.output_terminal_ids.push(desc_slice[3]);
                            }
                            _ => {}
                        }
                    }
                }

                USB_DT_ENDPOINT if desc_len >= 7 => {
                    let address = desc_slice[2];
                    let bm_attr = desc_slice[3];
                    let max_packet = u16::from_le_bytes([desc_slice[4], desc_slice[5]]);
                    let interval = desc_slice[6];
                    let refresh = if desc_len >= 8 { desc_slice[7] } else { 0 };
                    let synch_address = if desc_len >= 9 { desc_slice[8] } else { 0 };

                    let direction = if (address & 0x80) != 0 {
                        EndpointDirection::In
                    } else {
                        EndpointDirection::Out
                    };

                    let sync_type = match (bm_attr >> 2) & 0x03 {
                        0 => EndpointSyncType::NoSync,
                        1 => EndpointSyncType::Asynchronous,
                        2 => EndpointSyncType::Adaptive,
                        _ => EndpointSyncType::Synchronous,
                    };

                    let usage_type = match (bm_attr >> 4) & 0x03 {
                        0 => EndpointUsageType::Data,
                        1 => EndpointUsageType::Feedback,
                        2 => EndpointUsageType::ImplicitFeedback,
                        _ => EndpointUsageType::Reserved,
                    };

                    let ep = EndpointInfo {
                        address,
                        direction,
                        sync_type,
                        usage_type,
                        max_packet_size: max_packet & 0x07FF,
                        interval,
                        refresh,
                        synch_address,
                    };

                    if let Some(ref mut alt) = current_alt_setting {
                        if usage_type == EndpointUsageType::Feedback || (direction == EndpointDirection::In && sync_type == EndpointSyncType::NoSync) {
                            alt.feedback_endpoint = Some(ep);
                        } else if direction == EndpointDirection::Out {
                            alt.data_endpoint = Some(ep);
                        }
                    }
                }

                _ => {}
            }

            offset += desc_len;
        }

        // Flush trailing active alt setting if present
        if let (Some(iface_idx), Some(alt)) = (current_streaming_iface_idx, current_alt_setting.take()) {
            streaming_interfaces[iface_idx].alt_settings.push(alt);
        }

        if current_control.is_none() && streaming_interfaces.is_empty() {
            return Err(DescriptorParseError::NoAudioInterfacesFound);
        }

        Ok(Self {
            protocol: overall_protocol,
            control_interface: current_control,
            streaming_interfaces,
        })
    }

    /// Selects the best Audio Streaming interface and alternate setting for playback.
    /// Prefers highest bit depth and matching channel count (stereo).
    pub fn find_best_streaming_alt(&self, preferred_bit_depth: u8) -> Option<(&AudioStreamingInterface, &StreamingAltSetting)> {
        let mut best: Option<(&AudioStreamingInterface, &StreamingAltSetting)> = None;

        for iface in &self.streaming_interfaces {
            for alt in &iface.alt_settings {
                // Must have a valid OUT data endpoint
                if alt.data_endpoint.is_none() {
                    continue;
                }
                let format = match alt.format {
                    Some(ref f) => f,
                    None => continue,
                };

                match best {
                    None => best = Some((iface, alt)),
                    Some((_, current_best)) => {
                        let cur_format = current_best.format.as_ref().unwrap();
                        let cur_diff = (cur_format.bit_resolution as i32 - preferred_bit_depth as i32).abs();
                        let new_diff = (format.bit_resolution as i32 - preferred_bit_depth as i32).abs();

                        // Prefer closest bit resolution, then higher resolution
                        if new_diff < cur_diff || (new_diff == cur_diff && format.bit_resolution > cur_format.bit_resolution) {
                            best = Some((iface, alt));
                        }
                    }
                }
            }
        }

        best
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn build_mock_uac2_descriptor() -> Vec<u8> {
        let mut data = Vec::new();
        // Config descriptor (9 bytes)
        data.extend([9, 2, 0, 0, 2, 1, 0, 0x80, 0xFA]);
        // IAD (8 bytes)
        data.extend([8, 11, 0, 2, 1, 0, 0x20, 0]);
        // Interface 0, Alt 0: AC (9 bytes)
        data.extend([9, 4, 0, 0, 0, 1, 1, 0x20, 0]);
        // AC Header UAC2 (9 bytes)
        data.extend([9, 0x24, 0x01, 0x00, 0x02, 1, 0x3C, 0x00, 0]);
        // Clock Source 0x10 (8 bytes)
        data.extend([8, 0x24, 0x0B, 0x10, 0x03, 0x07, 0, 0]);
        // Feature Unit 0x12 (9 bytes)
        data.extend([9, 0x24, 0x06, 0x12, 0x10, 0x0F, 0x00, 0x00, 0]);
        // Interface 1, Alt 0: AS Inactive (9 bytes)
        data.extend([9, 4, 1, 0, 0, 1, 2, 0x20, 0]);
        // Interface 1, Alt 1: AS Active 24-bit (9 bytes)
        data.extend([9, 4, 1, 1, 2, 1, 2, 0x20, 0]);
        // AS General UAC2 (16 bytes)
        data.extend([16, 0x24, 0x01, 0x12, 0, 1, 1, 0, 0, 0, 2, 3, 0, 0, 0, 0]);
        // Format Type I UAC2 (6 bytes)
        data.extend([6, 0x24, 0x02, 1, 4, 24]);
        // Data OUT Endpoint (7 bytes)
        data.extend([7, 5, 0x01, 0x05, 0x00, 0x04, 1]);
        // Feedback IN Endpoint (7 bytes)
        data.extend([7, 5, 0x81, 0x11, 4, 0, 4]);

        let len = data.len() as u16;
        data[2] = (len & 0xFF) as u8;
        data[3] = ((len >> 8) & 0xFF) as u8;
        data
    }

    fn build_mock_uac1_descriptor() -> Vec<u8> {
        let mut data = Vec::new();
        // Config descriptor (9 bytes)
        data.extend([9, 2, 0, 0, 2, 1, 0, 0x80, 0x64]);
        // Interface 0, Alt 0: AC UAC1 (9 bytes)
        data.extend([9, 4, 0, 0, 0, 1, 1, 0, 0]);
        // AC Header UAC1 (10 bytes)
        data.extend([10, 0x24, 0x01, 0x00, 0x01, 10, 0, 1, 1, 0]);
        // Interface 1, Alt 0: AS Inactive (9 bytes)
        data.extend([9, 4, 1, 0, 0, 1, 2, 0, 0]);
        // Interface 1, Alt 1: AS Active 16-bit (9 bytes)
        data.extend([9, 4, 1, 1, 1, 1, 2, 0, 0]);
        // AS General UAC1 (7 bytes)
        data.extend([7, 0x24, 0x01, 1, 1, 1, 0]);
        // Format Type I UAC1 (14 bytes): 2 channels, 2 bytes/sample, 16 bits, 2 discrete rates (44100, 48000)
        data.extend([
            14, 0x24, 0x02, 1, 2, 2, 16, 2,
            0x44, 0xAC, 0x00, // 44100
            0x80, 0xBB, 0x00, // 48000
        ]);
        // Adaptive OUT Endpoint (7 bytes)
        data.extend([7, 5, 0x02, 0x09, 0xC8, 0x00, 1]);

        let len = data.len() as u16;
        data[2] = (len & 0xFF) as u8;
        data[3] = ((len >> 8) & 0xFF) as u8;
        data
    }

    #[test]
    fn test_parse_uac2_device_descriptor_tree() {
        let raw = build_mock_uac2_descriptor();
        let dev = ParsedAudioDevice::parse(&raw).expect("UAC2 parse should succeed");

        assert_eq!(dev.protocol, AudioClassProtocol::Uac2);
        let ac = dev.control_interface.expect("AC interface must exist");
        assert_eq!(ac.interface_number, 0);
        assert_eq!(ac.clock_source_ids, vec![0x10]);
        assert_eq!(ac.feature_unit_ids, vec![0x12]);

        assert_eq!(dev.streaming_interfaces.len(), 1);
        let as_iface = &dev.streaming_interfaces[0];
        assert_eq!(as_iface.interface_number, 1);
        assert_eq!(as_iface.alt_settings.len(), 2);

        // Alt 0 is inactive
        assert_eq!(as_iface.alt_settings[0].alt_setting, 0);
        assert!(as_iface.alt_settings[0].data_endpoint.is_none());

        // Alt 1 is 24-bit with async out and feedback in
        let alt1 = &as_iface.alt_settings[1];
        assert_eq!(alt1.alt_setting, 1);
        let fmt = alt1.format.as_ref().expect("Format must exist");
        assert_eq!(fmt.channels, 2);
        assert_eq!(fmt.bit_resolution, 24);
        assert_eq!(fmt.subslot_size, 4);

        let ep_out = alt1.data_endpoint.as_ref().expect("Data endpoint must exist");
        assert_eq!(ep_out.address, 0x01);
        assert_eq!(ep_out.direction, EndpointDirection::Out);
        assert_eq!(ep_out.sync_type, EndpointSyncType::Asynchronous);
        assert_eq!(ep_out.max_packet_size, 1024);

        let ep_fb = alt1.feedback_endpoint.as_ref().expect("Feedback endpoint must exist");
        assert_eq!(ep_fb.address, 0x81);
        assert_eq!(ep_fb.direction, EndpointDirection::In);
    }

    #[test]
    fn test_parse_uac1_device_descriptor_tree() {
        let raw = build_mock_uac1_descriptor();
        let dev = ParsedAudioDevice::parse(&raw).expect("UAC1 parse should succeed");

        assert_eq!(dev.protocol, AudioClassProtocol::Uac1);
        let ac = dev.control_interface.expect("AC interface must exist");
        assert_eq!(ac.interface_number, 0);

        let as_iface = &dev.streaming_interfaces[0];
        assert_eq!(as_iface.interface_number, 1);

        let alt1 = &as_iface.alt_settings[1];
        let fmt = alt1.format.as_ref().expect("Format must exist");
        assert_eq!(fmt.channels, 2);
        assert_eq!(fmt.bit_resolution, 16);
        assert_eq!(fmt.subslot_size, 2);
        assert_eq!(fmt.sample_rates, vec![44100, 48000]);

        let ep = alt1.data_endpoint.as_ref().expect("Data endpoint must exist");
        assert_eq!(ep.address, 0x02);
        assert_eq!(ep.direction, EndpointDirection::Out);
        assert_eq!(ep.sync_type, EndpointSyncType::Adaptive);
    }

    #[test]
    fn test_find_best_streaming_alt_selection() {
        let raw = build_mock_uac2_descriptor();
        let dev = ParsedAudioDevice::parse(&raw).unwrap();

        let (iface, alt) = dev.find_best_streaming_alt(24).expect("Should find best alt");
        assert_eq!(iface.interface_number, 1);
        assert_eq!(alt.alt_setting, 1);
        assert_eq!(alt.format.as_ref().unwrap().bit_resolution, 24);
    }

    #[test]
    fn test_parse_error_handling() {
        assert!(matches!(
            ParsedAudioDevice::parse(&[]),
            Err(DescriptorParseError::EmptyDescriptor)
        ));

        assert!(matches!(
            ParsedAudioDevice::parse(&[5, 2, 0, 0]),
            Err(DescriptorParseError::InvalidHeaderLength { .. })
        ));

        assert!(matches!(
            ParsedAudioDevice::parse(&[9, 1, 0, 0, 0, 0, 0, 0, 0]),
            Err(DescriptorParseError::MalformedDescriptor { .. })
        ));
    }
}

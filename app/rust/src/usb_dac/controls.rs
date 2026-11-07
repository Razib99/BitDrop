//! USB Audio Class (UAC1 and UAC2) Control Transfers & Clock Negotiation.
//!
//! Provides hardware-level sample rate negotiation, clock source selection,
//! and hardware volume/mute controls for bit-perfect audio delivery.

use crate::usb_dac::descriptors::{AudioClassProtocol, ParsedAudioDevice};
use crate::usb_dac::usbfs::{UsbDeviceHandle, UsbFsError};

// Standard USB Request Types
const USB_REQ_TYPE_CLASS_INTERFACE_SET: u8 = 0x21;
const USB_REQ_TYPE_CLASS_INTERFACE_GET: u8 = 0xA1;
const USB_REQ_TYPE_CLASS_ENDPOINT_SET: u8 = 0x22;
const USB_REQ_TYPE_CLASS_ENDPOINT_GET: u8 = 0xA2;

// UAC 2.0 Request Codes
pub const UAC2_CS_CUR: u8 = 0x01;
pub const UAC2_CS_RANGE: u8 = 0x02;

// UAC 1.0 Request Codes
pub const UAC1_SET_CUR: u8 = 0x01;
pub const UAC1_GET_CUR: u8 = 0x81;
pub const UAC1_GET_MIN: u8 = 0x82;
pub const UAC1_GET_MAX: u8 = 0x83;
pub const UAC1_GET_RES: u8 = 0x84;

// UAC 2.0 Clock Source Control Selectors
pub const UAC2_CS_CONTROL_SAM_FREQ: u8 = 0x01;
pub const UAC2_CS_CONTROL_CLOCK_VALID: u8 = 0x02;

// UAC Feature Unit Control Selectors
pub const UAC_FU_MUTE: u8 = 0x01;
pub const UAC_FU_VOLUME: u8 = 0x02;

// UAC 1.0 Endpoint Control Selectors
pub const UAC1_EP_CONTROL_SAM_FREQ: u8 = 0x01;

/// Represents a supported sample rate range or discrete frequency.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SampleRateRange {
    pub min: u32,
    pub max: u32,
    pub res: u32,
}

impl SampleRateRange {
    /// Returns true if this represents a single discrete frequency.
    pub fn is_discrete(&self) -> bool {
        self.min == self.max || self.res == 0
    }

    /// Checks if a candidate sample rate is supported by this range.
    pub fn supports(&self, rate: u32) -> bool {
        if self.is_discrete() {
            rate == self.min || rate == self.max
        } else if rate >= self.min && rate <= self.max {
            if self.res <= 1 {
                true
            } else {
                (rate - self.min).is_multiple_of(self.res)
            }
        } else {
            false
        }
    }
}

/// Hardware volume range expressed in 1/256 dB units according to USB Audio specifications.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HardwareVolumeRange {
    pub min_db_256: i16,
    pub max_db_256: i16,
    pub res_db_256: i16,
}

impl HardwareVolumeRange {
    pub fn min_db(&self) -> f32 {
        self.min_db_256 as f32 / 256.0
    }

    pub fn max_db(&self) -> f32 {
        self.max_db_256 as f32 / 256.0
    }

    /// Maps normalized linear volume (0.0 to 1.0) into the DAC's hardware volume range.
    pub fn normalized_to_hw(&self, volume: f32) -> i16 {
        if volume <= 0.0 {
            return self.min_db_256;
        }
        if volume >= 1.0 {
            return self.max_db_256;
        }
        let span = (self.max_db_256 as f32) - (self.min_db_256 as f32);
        (self.min_db_256 as f32 + span * volume).round() as i16
    }
}

/// Parses the payload returned by a UAC2 `CS_SAM_FREQ_CONTROL` RANGE query.
pub fn parse_uac2_sample_rate_ranges(data: &[u8]) -> Result<Vec<SampleRateRange>, UsbFsError> {
    if data.len() < 2 {
        return Err(UsbFsError::InvalidArgument);
    }
    let num_subranges = u16::from_le_bytes([data[0], data[1]]) as usize;
    let mut ranges = Vec::with_capacity(num_subranges);
    let mut offset = 2;

    for _ in 0..num_subranges {
        if offset + 12 > data.len() {
            break;
        }
        let min = u32::from_le_bytes([
            data[offset],
            data[offset + 1],
            data[offset + 2],
            data[offset + 3],
        ]);
        let max = u32::from_le_bytes([
            data[offset + 4],
            data[offset + 5],
            data[offset + 6],
            data[offset + 7],
        ]);
        let res = u32::from_le_bytes([
            data[offset + 8],
            data[offset + 9],
            data[offset + 10],
            data[offset + 11],
        ]);

        ranges.push(SampleRateRange { min, max, res });
        offset += 12;
    }

    if ranges.is_empty() {
        return Err(UsbFsError::InvalidArgument);
    }
    Ok(ranges)
}

/// Parses the payload returned by a UAC2 `FU_VOLUME_CONTROL` RANGE query.
pub fn parse_uac2_volume_range(data: &[u8]) -> Result<HardwareVolumeRange, UsbFsError> {
    if data.len() < 8 {
        return Err(UsbFsError::InvalidArgument);
    }
    let num_subranges = u16::from_le_bytes([data[0], data[1]]);
    if num_subranges == 0 {
        return Err(UsbFsError::InvalidArgument);
    }

    let min_db_256 = i16::from_le_bytes([data[2], data[3]]);
    let max_db_256 = i16::from_le_bytes([data[4], data[5]]);
    let res_db_256 = i16::from_le_bytes([data[6], data[7]]);

    Ok(HardwareVolumeRange {
        min_db_256,
        max_db_256,
        res_db_256,
    })
}

/// Reads the current sampling frequency from a UAC2 Clock Source entity.
pub fn uac2_get_sample_rate(
    handle: &UsbDeviceHandle,
    ac_interface: u8,
    clock_source_id: u8,
) -> Result<u32, UsbFsError> {
    let mut buf = [0u8; 4];
    let w_value = (UAC2_CS_CONTROL_SAM_FREQ as u16) << 8;
    let w_index = ((clock_source_id as u16) << 8) | (ac_interface as u16);

    let read = handle.control_transfer(
        USB_REQ_TYPE_CLASS_INTERFACE_GET,
        UAC2_CS_CUR,
        w_value,
        w_index,
        &mut buf,
        1000,
    )?;

    if read < 4 {
        return Err(UsbFsError::from_errno("uac2_get_sample_rate: short read"));
    }
    Ok(u32::from_le_bytes(buf))
}

/// Sets the current sampling frequency on a UAC2 Clock Source entity.
pub fn uac2_set_sample_rate(
    handle: &UsbDeviceHandle,
    ac_interface: u8,
    clock_source_id: u8,
    sample_rate: u32,
) -> Result<(), UsbFsError> {
    let mut payload = sample_rate.to_le_bytes();
    let w_value = (UAC2_CS_CONTROL_SAM_FREQ as u16) << 8;
    let w_index = ((clock_source_id as u16) << 8) | (ac_interface as u16);

    handle.control_transfer(
        USB_REQ_TYPE_CLASS_INTERFACE_SET,
        UAC2_CS_CUR,
        w_value,
        w_index,
        &mut payload,
        1500,
    )?;

    Ok(())
}

/// Queries all natively supported sample rate ranges from a UAC2 Clock Source entity.
pub fn uac2_get_sample_rate_ranges(
    handle: &UsbDeviceHandle,
    ac_interface: u8,
    clock_source_id: u8,
) -> Result<Vec<SampleRateRange>, UsbFsError> {
    let mut buf = [0u8; 256];
    let w_value = (UAC2_CS_CONTROL_SAM_FREQ as u16) << 8;
    let w_index = ((clock_source_id as u16) << 8) | (ac_interface as u16);

    let read = handle.control_transfer(
        USB_REQ_TYPE_CLASS_INTERFACE_GET,
        UAC2_CS_RANGE,
        w_value,
        w_index,
        &mut buf,
        1500,
    )?;

    parse_uac2_sample_rate_ranges(&buf[..read])
}

/// Sets the sampling frequency on a UAC1 Isochronous endpoint.
pub fn uac1_set_sample_rate(
    handle: &UsbDeviceHandle,
    endpoint_address: u8,
    sample_rate: u32,
) -> Result<(), UsbFsError> {
    let mut payload = [
        (sample_rate & 0xFF) as u8,
        ((sample_rate >> 8) & 0xFF) as u8,
        ((sample_rate >> 16) & 0xFF) as u8,
    ];
    let w_value = (UAC1_EP_CONTROL_SAM_FREQ as u16) << 8;
    let w_index = endpoint_address as u16;

    handle.control_transfer(
        USB_REQ_TYPE_CLASS_ENDPOINT_SET,
        UAC1_SET_CUR,
        w_value,
        w_index,
        &mut payload,
        1500,
    )?;

    Ok(())
}

/// Reads the current sampling frequency from a UAC1 Isochronous endpoint.
pub fn uac1_get_sample_rate(
    handle: &UsbDeviceHandle,
    endpoint_address: u8,
) -> Result<u32, UsbFsError> {
    let mut buf = [0u8; 3];
    let w_value = (UAC1_EP_CONTROL_SAM_FREQ as u16) << 8;
    let w_index = endpoint_address as u16;

    let read = handle.control_transfer(
        USB_REQ_TYPE_CLASS_ENDPOINT_GET,
        UAC1_GET_CUR,
        w_value,
        w_index,
        &mut buf,
        1000,
    )?;

    if read < 3 {
        return Err(UsbFsError::from_errno("uac1_get_sample_rate: short read"));
    }
    Ok((buf[0] as u32) | ((buf[1] as u32) << 8) | ((buf[2] as u32) << 16))
}

/// Queries hardware volume capabilities from a UAC2 Feature Unit.
pub fn uac2_get_volume_range(
    handle: &UsbDeviceHandle,
    ac_interface: u8,
    feature_unit_id: u8,
    channel: u8,
) -> Result<HardwareVolumeRange, UsbFsError> {
    let mut buf = [0u8; 64];
    let w_value = ((UAC_FU_VOLUME as u16) << 8) | (channel as u16);
    let w_index = ((feature_unit_id as u16) << 8) | (ac_interface as u16);

    let read = handle.control_transfer(
        USB_REQ_TYPE_CLASS_INTERFACE_GET,
        UAC2_CS_RANGE,
        w_value,
        w_index,
        &mut buf,
        1000,
    )?;

    parse_uac2_volume_range(&buf[..read])
}

/// Sets hardware volume on a UAC2 Feature Unit in 1/256 dB units.
pub fn uac2_set_volume(
    handle: &UsbDeviceHandle,
    ac_interface: u8,
    feature_unit_id: u8,
    channel: u8,
    volume_db_256: i16,
) -> Result<(), UsbFsError> {
    let mut payload = volume_db_256.to_le_bytes();
    let w_value = ((UAC_FU_VOLUME as u16) << 8) | (channel as u16);
    let w_index = ((feature_unit_id as u16) << 8) | (ac_interface as u16);

    handle.control_transfer(
        USB_REQ_TYPE_CLASS_INTERFACE_SET,
        UAC2_CS_CUR,
        w_value,
        w_index,
        &mut payload,
        1000,
    )?;

    Ok(())
}

/// Sets hardware mute on a UAC2 Feature Unit.
pub fn uac2_set_mute(
    handle: &UsbDeviceHandle,
    ac_interface: u8,
    feature_unit_id: u8,
    channel: u8,
    muted: bool,
) -> Result<(), UsbFsError> {
    let mut payload = [if muted { 1u8 } else { 0u8 }];
    let w_value = ((UAC_FU_MUTE as u16) << 8) | (channel as u16);
    let w_index = ((feature_unit_id as u16) << 8) | (ac_interface as u16);

    handle.control_transfer(
        USB_REQ_TYPE_CLASS_INTERFACE_SET,
        UAC2_CS_CUR,
        w_value,
        w_index,
        &mut payload,
        1000,
    )?;

    Ok(())
}

/// High-level sample rate negotiator for both UAC1 and UAC2 devices.
/// Attempts to lock the hardware clock directly to `desired_rate`.
/// Returns the actual sample rate locked by the DAC.
pub fn negotiate_device_sample_rate(
    handle: &UsbDeviceHandle,
    device: &ParsedAudioDevice,
    desired_rate: u32,
) -> Result<u32, UsbFsError> {
    match device.protocol {
        AudioClassProtocol::Uac2 => {
            let ac = match device.control_interface {
                Some(ref ac) => ac,
                None => return Err(UsbFsError::InvalidArgument),
            };

            let clock_id = match ac.clock_source_ids.first() {
                Some(&id) => id,
                None => return Err(UsbFsError::InvalidArgument),
            };

            // Query supported hardware rates
            let ranges = uac2_get_sample_rate_ranges(handle, ac.interface_number, clock_id)
                .unwrap_or_else(|_| {
                    vec![SampleRateRange {
                        min: desired_rate,
                        max: desired_rate,
                        res: 0,
                    }]
                });

            // Find matching or closest supported rate
            let target_rate = if ranges.iter().any(|r| r.supports(desired_rate)) {
                desired_rate
            } else {
                // Find closest rate among all supported ranges
                let mut best_rate = 48000;
                let mut best_diff = i64::MAX;
                for r in &ranges {
                    let candidate = desired_rate.clamp(r.min, r.max);
                    let diff = (candidate as i64 - desired_rate as i64).abs();
                    if diff < best_diff {
                        best_diff = diff;
                        best_rate = candidate;
                    }
                }
                best_rate
            };

            uac2_set_sample_rate(handle, ac.interface_number, clock_id, target_rate)?;

            // Verify with readback
            match uac2_get_sample_rate(handle, ac.interface_number, clock_id) {
                Ok(actual) => Ok(actual),
                Err(_) => Ok(target_rate),
            }
        }

        AudioClassProtocol::Uac1 => {
            // Find active OUT endpoint from streaming interface
            let mut ep_addr = None;
            let mut discrete_rates = Vec::new();

            for s in &device.streaming_interfaces {
                for alt in &s.alt_settings {
                    if let (Some(ref ep), Some(ref fmt)) = (&alt.data_endpoint, &alt.format) {
                        ep_addr = Some(ep.address);
                        discrete_rates.extend_from_slice(&fmt.sample_rates);
                    }
                }
            }

            let endpoint = match ep_addr {
                Some(addr) => addr,
                None => return Err(UsbFsError::InvalidArgument),
            };

            let target_rate = if discrete_rates.is_empty() || discrete_rates.contains(&desired_rate)
            {
                desired_rate
            } else {
                *discrete_rates
                    .iter()
                    .min_by_key(|&&r| (r as i64 - desired_rate as i64).abs())
                    .unwrap_or(&48000)
            };

            uac1_set_sample_rate(handle, endpoint, target_rate)?;

            match uac1_get_sample_rate(handle, endpoint) {
                Ok(actual) => Ok(actual),
                Err(_) => Ok(target_rate),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sample_rate_range_discrete_and_continuous() {
        let discrete = SampleRateRange {
            min: 96000,
            max: 96000,
            res: 0,
        };
        assert!(discrete.is_discrete());
        assert!(discrete.supports(96000));
        assert!(!discrete.supports(48000));

        let continuous = SampleRateRange {
            min: 44100,
            max: 192000,
            res: 1,
        };
        assert!(!continuous.is_discrete());
        assert!(continuous.supports(44100));
        assert!(continuous.supports(48000));
        assert!(continuous.supports(88200));
        assert!(continuous.supports(96000));
        assert!(continuous.supports(176400));
        assert!(continuous.supports(192000));
        assert!(!continuous.supports(384000));
    }

    #[test]
    fn test_parse_uac2_sample_rate_ranges_payload() {
        let mut data = Vec::new();
        // 3 subranges
        data.extend(3u16.to_le_bytes());
        // 44100 discrete
        data.extend(44100u32.to_le_bytes());
        data.extend(44100u32.to_le_bytes());
        data.extend(0u32.to_le_bytes());
        // 48000 discrete
        data.extend(48000u32.to_le_bytes());
        data.extend(48000u32.to_le_bytes());
        data.extend(0u32.to_le_bytes());
        // 96000 discrete
        data.extend(96000u32.to_le_bytes());
        data.extend(96000u32.to_le_bytes());
        data.extend(0u32.to_le_bytes());

        let ranges = parse_uac2_sample_rate_ranges(&data).expect("Parsing must succeed");
        assert_eq!(ranges.len(), 3);
        assert_eq!(
            ranges[0],
            SampleRateRange {
                min: 44100,
                max: 44100,
                res: 0
            }
        );
        assert_eq!(
            ranges[1],
            SampleRateRange {
                min: 48000,
                max: 48000,
                res: 0
            }
        );
        assert_eq!(
            ranges[2],
            SampleRateRange {
                min: 96000,
                max: 96000,
                res: 0
            }
        );
    }

    #[test]
    fn test_parse_uac2_volume_range_payload() {
        let mut data = Vec::new();
        // 1 subrange
        data.extend(1u16.to_le_bytes());
        // min: -96 dB (-24576), max: 0 dB (0), res: 0.5 dB (128)
        data.extend((-24576i16).to_le_bytes());
        data.extend(0i16.to_le_bytes());
        data.extend(128i16.to_le_bytes());

        let vol_range = parse_uac2_volume_range(&data).expect("Parsing volume range must succeed");
        assert_eq!(vol_range.min_db_256, -24576);
        assert_eq!(vol_range.max_db_256, 0);
        assert_eq!(vol_range.res_db_256, 128);

        assert_eq!(vol_range.min_db(), -96.0);
        assert_eq!(vol_range.max_db(), 0.0);

        // Test normalized volume mapping
        assert_eq!(vol_range.normalized_to_hw(0.0), -24576);
        assert_eq!(vol_range.normalized_to_hw(1.0), 0);
        assert_eq!(vol_range.normalized_to_hw(0.5), -12288); // -48 dB
    }
}

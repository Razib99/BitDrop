//! User-space USB Audio Class (UAC1/UAC2) Driver.
//!
//! Provides direct bit-perfect hardware bypass for USB DACs on Android 12+ and Linux.

pub mod usbfs;

pub use usbfs::{
    IsoUrb, UsbDeviceHandle, UsbFsError, UsbdevfsCtrlTransfer, UsbdevfsDisconnectClaim,
    UsbdevfsIsoPacketDesc, UsbdevfsSetInterface, UsbdevfsUrb,
};

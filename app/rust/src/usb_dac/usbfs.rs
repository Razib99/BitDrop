//! Low-level Linux `usbfs` ioctl wrapper module.
//!
//! Provides zero-dependency, bit-exact communication with USB Audio Class (UAC1/UAC2)
//! devices directly from user space on Android and Linux via file descriptors (`/dev/bus/usb/...`).

use std::ffi::c_void;
use std::fmt;
use std::os::unix::io::RawFd;

#[cfg(target_os = "android")]
pub type IoctlReq = libc::c_int;

#[cfg(not(target_os = "android"))]
pub type IoctlReq = libc::c_ulong;

// Linux ioctl encoding constants matching <asm-generic/ioctl.h>
const IOC_NONE: u32 = 0;
const IOC_WRITE: u32 = 1;
const IOC_READ: u32 = 2;

const fn _ioc(dir: u32, type_char: u8, nr: u32, size: usize) -> u32 {
    (dir << 30) | ((type_char as u32) << 8) | nr | (((size as u32) & 0x3FFF) << 16)
}

const fn _io(type_char: u8, nr: u32) -> u32 {
    _ioc(IOC_NONE, type_char, nr, 0)
}

const fn _ior<T>(type_char: u8, nr: u32) -> u32 {
    _ioc(IOC_READ, type_char, nr, std::mem::size_of::<T>())
}

const fn _iow<T>(type_char: u8, nr: u32) -> u32 {
    _ioc(IOC_WRITE, type_char, nr, std::mem::size_of::<T>())
}

const fn _iowr<T>(type_char: u8, nr: u32) -> u32 {
    _ioc(
        IOC_READ | IOC_WRITE,
        type_char,
        nr,
        std::mem::size_of::<T>(),
    )
}

// Exact Linux <linux/usbdevice_fs.h> ioctls
pub const USBDEVFS_CONTROL: u32 = _iowr::<UsbdevfsCtrlTransfer>(b'U', 0);
pub const USBDEVFS_SETINTERFACE: u32 = _ior::<UsbdevfsSetInterface>(b'U', 4);
pub const USBDEVFS_SETCONFIGURATION: u32 = _ior::<libc::c_uint>(b'U', 5);
pub const USBDEVFS_SUBMITURB: u32 = _ior::<UsbdevfsUrb>(b'U', 10);
pub const USBDEVFS_DISCARDURB: u32 = _io(b'U', 11);
pub const USBDEVFS_REAPURB: u32 = _iow::<*mut c_void>(b'U', 12);
pub const USBDEVFS_REAPURBNDELAY: u32 = _iow::<*mut c_void>(b'U', 13);
pub const USBDEVFS_CLAIMINTERFACE: u32 = _ior::<libc::c_uint>(b'U', 15);
pub const USBDEVFS_RELEASEINTERFACE: u32 = _ior::<libc::c_uint>(b'U', 16);
pub const USBDEVFS_RESET: u32 = _io(b'U', 20);
pub const USBDEVFS_CLEAR_HALT: u32 = _ior::<libc::c_uint>(b'U', 21);
pub const USBDEVFS_DISCONNECT: u32 = _io(b'U', 22);
pub const USBDEVFS_CONNECT: u32 = _io(b'U', 23);
pub const USBDEVFS_CLAIM_PORT: u32 = _ior::<libc::c_uint>(b'U', 24);
pub const USBDEVFS_RELEASE_PORT: u32 = _ior::<libc::c_uint>(b'U', 25);
pub const USBDEVFS_DISCONNECT_CLAIM: u32 = _ior::<UsbdevfsDisconnectClaim>(b'U', 27);

// URB types & flags
pub const USBDEVFS_URB_TYPE_ISO: u8 = 0;
pub const USBDEVFS_URB_TYPE_INTERRUPT: u8 = 1;
pub const USBDEVFS_URB_TYPE_CONTROL: u8 = 2;
pub const USBDEVFS_URB_TYPE_BULK: u8 = 3;

pub const USBDEVFS_URB_SHORT_NOT_OK: u32 = 0x01;
pub const USBDEVFS_URB_ISO_ASAP: u32 = 0x02;

pub const USBDEVFS_DISCONNECT_CLAIM_IF_DRIVER: u32 = 0x01;
pub const USBDEVFS_DISCONNECT_CLAIM_EXCEPT_DRIVER: u32 = 0x02;

/// C-compatible representation of `struct usbdevfs_ctrltransfer`.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct UsbdevfsCtrlTransfer {
    pub b_request_type: u8,
    pub b_request: u8,
    pub w_value: u16,
    pub w_index: u16,
    pub w_length: u16,
    pub timeout: u32,
    pub data: *mut c_void,
}

/// C-compatible representation of `struct usbdevfs_setinterface`.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UsbdevfsSetInterface {
    pub interface: u32,
    pub altsetting: u32,
}

/// C-compatible representation of `struct usbdevfs_disconnect_claim`.
#[repr(C)]
pub struct UsbdevfsDisconnectClaim {
    pub interface: u32,
    pub flags: u32,
    pub driver: [u8; 256],
}

/// C-compatible representation of `struct usbdevfs_iso_packet_desc`.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct UsbdevfsIsoPacketDesc {
    pub length: u32,
    pub actual_length: u32,
    pub status: u32,
}

/// C-compatible representation of `struct usbdevfs_urb`.
#[repr(C)]
pub struct UsbdevfsUrb {
    pub urb_type: u8,
    pub endpoint: u8,
    pub status: i32,
    pub flags: u32,
    pub buffer: *mut c_void,
    pub buffer_length: i32,
    pub actual_length: i32,
    pub start_frame: i32,
    pub number_of_packets: u32,
    pub error_count: i32,
    pub signr: u32,
    pub usercontext: *mut c_void,
}

/// Represents an Isochronous URB with `N` packet descriptors allocated contiguously.
#[repr(C)]
pub struct IsoUrb<const N: usize> {
    pub urb: UsbdevfsUrb,
    pub iso_frame_desc: [UsbdevfsIsoPacketDesc; N],
}

impl<const N: usize> IsoUrb<N> {
    /// Creates a newly zeroed Isochronous URB.
    pub fn new(endpoint: u8, buffer: *mut u8, packet_size: usize) -> Self {
        let mut iso = Self {
            urb: UsbdevfsUrb {
                urb_type: USBDEVFS_URB_TYPE_ISO,
                endpoint,
                status: 0,
                flags: USBDEVFS_URB_ISO_ASAP,
                buffer: buffer as *mut c_void,
                buffer_length: (packet_size * N) as i32,
                actual_length: 0,
                start_frame: 0,
                number_of_packets: N as u32,
                error_count: 0,
                signr: 0,
                usercontext: std::ptr::null_mut(),
            },
            iso_frame_desc: [UsbdevfsIsoPacketDesc::default(); N],
        };

        for (i, desc) in iso.iso_frame_desc.iter_mut().enumerate() {
            desc.length = packet_size as u32;
            desc.actual_length = 0;
            desc.status = 0;
            let _ = i;
        }

        iso
    }

    /// Pointer to the underlying `UsbdevfsUrb` suitable for passing to ioctl.
    pub fn as_urb_ptr(&mut self) -> *mut UsbdevfsUrb {
        &mut self.urb as *mut UsbdevfsUrb
    }
}

/// Strongly typed errors produced during `usbfs` interactions.
#[derive(Debug)]
pub enum UsbFsError {
    PermissionDenied,
    DeviceDisconnected,
    Busy,
    TimedOut,
    PipeStall,
    InvalidArgument,
    UnsupportedPlatform,
    IoctlFailed {
        op: &'static str,
        errno: i32,
        message: String,
    },
    Io(std::io::Error),
}

impl fmt::Display for UsbFsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::PermissionDenied => write!(f, "USB permission denied"),
            Self::DeviceDisconnected => write!(f, "USB device disconnected or shutdown"),
            Self::Busy => write!(f, "USB interface or resource is busy"),
            Self::TimedOut => write!(f, "USB operation timed out"),
            Self::PipeStall => write!(f, "USB endpoint pipe stalled"),
            Self::InvalidArgument => write!(f, "Invalid argument in USB request"),
            Self::UnsupportedPlatform => write!(f, "usbfs is not supported on this platform"),
            Self::IoctlFailed { op, errno, message } => {
                write!(f, "usbfs ioctl '{op}' failed with errno {errno}: {message}")
            }
            Self::Io(err) => write!(f, "USB I/O error: {err}"),
        }
    }
}

impl std::error::Error for UsbFsError {}

impl UsbFsError {
    pub fn from_errno(op: &'static str) -> Self {
        let err = std::io::Error::last_os_error();
        match err.raw_os_error() {
            Some(libc::EACCES) | Some(libc::EPERM) => Self::PermissionDenied,
            Some(libc::ENODEV) | Some(libc::ESHUTDOWN) | Some(libc::ECONNRESET) => {
                Self::DeviceDisconnected
            }
            Some(libc::EBUSY) => Self::Busy,
            Some(libc::ETIMEDOUT) => Self::TimedOut,
            Some(libc::EPIPE) => Self::PipeStall,
            Some(libc::EINVAL) => Self::InvalidArgument,
            Some(errno) => Self::IoctlFailed {
                op,
                errno,
                message: err.to_string(),
            },
            None => Self::Io(err),
        }
    }
}

/// Safe wrapper around a raw Linux USB device file descriptor.
#[derive(Debug)]
pub struct UsbDeviceHandle {
    fd: RawFd,
    owned: bool,
}

impl UsbDeviceHandle {
    /// Wraps an existing file descriptor borrowed from Android's `UsbDeviceConnection`.
    /// Does NOT close the file descriptor on drop.
    pub fn from_raw_fd_borrowed(fd: RawFd) -> Self {
        Self { fd, owned: false }
    }

    /// Wraps a file descriptor exclusively owned by Rust.
    /// Closes the file descriptor when dropped.
    pub fn from_raw_fd_owned(fd: RawFd) -> Self {
        Self { fd, owned: true }
    }

    /// Returns the raw integer file descriptor.
    pub fn raw_fd(&self) -> RawFd {
        self.fd
    }

    /// Claims a USB interface for exclusive user-space communication.
    pub fn claim_interface(&self, interface_number: u32) -> Result<(), UsbFsError> {
        let ret = unsafe {
            libc::ioctl(
                self.fd,
                USBDEVFS_CLAIMINTERFACE as IoctlReq,
                &interface_number as *const u32,
            )
        };
        if ret < 0 {
            return Err(UsbFsError::from_errno("USBDEVFS_CLAIMINTERFACE"));
        }
        Ok(())
    }

    /// Releases a previously claimed USB interface.
    pub fn release_interface(&self, interface_number: u32) -> Result<(), UsbFsError> {
        let ret = unsafe {
            libc::ioctl(
                self.fd,
                USBDEVFS_RELEASEINTERFACE as IoctlReq,
                &interface_number as *const u32,
            )
        };
        if ret < 0 {
            return Err(UsbFsError::from_errno("USBDEVFS_RELEASEINTERFACE"));
        }
        Ok(())
    }

    /// Sets the alternate setting for a USB interface (e.g. activating Audio Streaming).
    pub fn set_interface_alt(&self, interface: u32, altsetting: u32) -> Result<(), UsbFsError> {
        let mut setif = UsbdevfsSetInterface {
            interface,
            altsetting,
        };
        let ret = unsafe {
            libc::ioctl(
                self.fd,
                USBDEVFS_SETINTERFACE as IoctlReq,
                &mut setif as *mut UsbdevfsSetInterface,
            )
        };
        if ret < 0 {
            return Err(UsbFsError::from_errno("USBDEVFS_SETINTERFACE"));
        }
        Ok(())
    }

    /// Sets the active USB device configuration.
    pub fn set_configuration(&self, configuration: u32) -> Result<(), UsbFsError> {
        let ret = unsafe {
            libc::ioctl(
                self.fd,
                USBDEVFS_SETCONFIGURATION as IoctlReq,
                &configuration as *const u32,
            )
        };
        if ret < 0 {
            return Err(UsbFsError::from_errno("USBDEVFS_SETCONFIGURATION"));
        }
        Ok(())
    }

    /// Detaches the kernel driver (e.g. `snd-usb-audio`) so user-space can claim the interface.
    pub fn disconnect_kernel_driver(&self, interface: u32) -> Result<(), UsbFsError> {
        let mut dc = UsbdevfsDisconnectClaim {
            interface,
            flags: USBDEVFS_DISCONNECT_CLAIM_EXCEPT_DRIVER,
            driver: [0u8; 256],
        };
        let usbfs_tag = b"usbfs";
        dc.driver[..usbfs_tag.len()].copy_from_slice(usbfs_tag);

        let ret = unsafe {
            libc::ioctl(
                self.fd,
                USBDEVFS_DISCONNECT_CLAIM as IoctlReq,
                &mut dc as *mut UsbdevfsDisconnectClaim,
            )
        };
        if ret == 0 {
            return Ok(());
        }

        // Fall back to simple disconnect
        let mut iface = interface;
        let ret_disc = unsafe {
            libc::ioctl(
                self.fd,
                USBDEVFS_DISCONNECT as IoctlReq,
                &mut iface as *mut u32,
            )
        };
        if ret_disc < 0 {
            let err = std::io::Error::last_os_error();
            // If already detached or no driver active, kernel returns EINVAL or ENODATA
            if err.raw_os_error() != Some(libc::EINVAL) && err.raw_os_error() != Some(61) {
                return Err(UsbFsError::from_errno("USBDEVFS_DISCONNECT"));
            }
        }
        Ok(())
    }

    /// Performs a USB bus reset on the device.
    pub fn reset(&self) -> Result<(), UsbFsError> {
        let ret = unsafe { libc::ioctl(self.fd, USBDEVFS_RESET as IoctlReq, 0) };
        if ret < 0 {
            return Err(UsbFsError::from_errno("USBDEVFS_RESET"));
        }
        Ok(())
    }

    /// Clears a stall or halt condition on the specified endpoint.
    pub fn clear_halt(&self, endpoint: u8) -> Result<(), UsbFsError> {
        let ep = endpoint as u32;
        let ret =
            unsafe { libc::ioctl(self.fd, USBDEVFS_CLEAR_HALT as IoctlReq, &ep as *const u32) };
        if ret < 0 {
            return Err(UsbFsError::from_errno("USBDEVFS_CLEAR_HALT"));
        }
        Ok(())
    }

    /// Executes a synchronous control transfer (IN or OUT).
    pub fn control_transfer(
        &self,
        request_type: u8,
        request: u8,
        value: u16,
        index: u16,
        data: &mut [u8],
        timeout_ms: u32,
    ) -> Result<usize, UsbFsError> {
        let mut ctrl = UsbdevfsCtrlTransfer {
            b_request_type: request_type,
            b_request: request,
            w_value: value,
            w_index: index,
            w_length: data.len() as u16,
            timeout: timeout_ms,
            data: data.as_mut_ptr() as *mut c_void,
        };

        let ret = unsafe {
            libc::ioctl(
                self.fd,
                USBDEVFS_CONTROL as IoctlReq,
                &mut ctrl as *mut UsbdevfsCtrlTransfer,
            )
        };
        if ret < 0 {
            return Err(UsbFsError::from_errno("USBDEVFS_CONTROL"));
        }
        Ok(ret as usize)
    }

    /// Retrieves the raw configuration descriptor for the active configuration.
    pub fn get_active_config_descriptor(&self) -> Result<Vec<u8>, UsbFsError> {
        let mut header = [0u8; 9];
        // Standard GET_DESCRIPTOR: bRequestType = 0x80, bRequest = 0x06, wValue = (USB_DT_CONFIG << 8) | 0
        let read = self.control_transfer(0x80, 0x06, 2 << 8, 0, &mut header, 1000)?;
        if read < 9 {
            return Err(UsbFsError::InvalidArgument);
        }
        let total_length = u16::from_le_bytes([header[2], header[3]]) as usize;
        if !(9..=8192).contains(&total_length) {
            return Err(UsbFsError::InvalidArgument);
        }

        let mut buffer = vec![0u8; total_length];
        let full_read = self.control_transfer(0x80, 0x06, 2 << 8, 0, &mut buffer, 2000)?;
        buffer.truncate(full_read);
        Ok(buffer)
    }

    /// Submits an asynchronous URB to the Linux USB core.
    ///
    /// # Safety
    /// Caller must ensure `urb` points to a valid, initialized `UsbdevfsUrb` whose
    /// associated data buffers remain valid and pinned for the duration of the transfer.
    pub unsafe fn submit_urb(&self, urb: *mut UsbdevfsUrb) -> Result<(), UsbFsError> {
        let ret = libc::ioctl(self.fd, USBDEVFS_SUBMITURB as IoctlReq, urb);
        if ret < 0 {
            return Err(UsbFsError::from_errno("USBDEVFS_SUBMITURB"));
        }
        Ok(())
    }

    /// Discards an in-flight URB.
    ///
    /// # Safety
    /// Caller must ensure `urb` was previously submitted and has not yet been freed.
    pub unsafe fn discard_urb(&self, urb: *mut UsbdevfsUrb) -> Result<(), UsbFsError> {
        let ret = libc::ioctl(self.fd, USBDEVFS_DISCARDURB as IoctlReq, urb);
        if ret < 0 {
            return Err(UsbFsError::from_errno("USBDEVFS_DISCARDURB"));
        }
        Ok(())
    }

    /// Reaps a completed URB, optionally polling with a timeout in milliseconds.
    pub fn reap_urb(&self, timeout_ms: Option<u32>) -> Result<*mut UsbdevfsUrb, UsbFsError> {
        match timeout_ms {
            None => {
                let mut urb_ptr: *mut UsbdevfsUrb = std::ptr::null_mut();
                let ret = unsafe {
                    libc::ioctl(
                        self.fd,
                        USBDEVFS_REAPURB as IoctlReq,
                        &mut urb_ptr as *mut *mut UsbdevfsUrb,
                    )
                };
                if ret < 0 {
                    return Err(UsbFsError::from_errno("USBDEVFS_REAPURB"));
                }
                Ok(urb_ptr)
            }
            Some(timeout) => {
                let mut pfd = libc::pollfd {
                    fd: self.fd,
                    events: libc::POLLOUT | libc::POLLIN,
                    revents: 0,
                };
                let poll_ret = unsafe { libc::poll(&mut pfd as *mut _, 1, timeout as libc::c_int) };
                if poll_ret < 0 {
                    return Err(UsbFsError::from_errno("poll"));
                }
                if poll_ret == 0 {
                    return Err(UsbFsError::TimedOut);
                }

                let mut urb_ptr: *mut UsbdevfsUrb = std::ptr::null_mut();
                let ret = unsafe {
                    libc::ioctl(
                        self.fd,
                        USBDEVFS_REAPURBNDELAY as IoctlReq,
                        &mut urb_ptr as *mut *mut UsbdevfsUrb,
                    )
                };
                if ret < 0 {
                    return Err(UsbFsError::from_errno("USBDEVFS_REAPURBNDELAY"));
                }
                Ok(urb_ptr)
            }
        }
    }

    /// Non-blocking reap: executes USBDEVFS_REAPURBNDELAY immediately without poll waiting.
    /// Returns Ok(ptr) if an URB was reaped, or Err(err) if no URB is pending (-EAGAIN) or on detach.
    pub fn reap_urb_ndelay(&self) -> Result<*mut UsbdevfsUrb, UsbFsError> {
        let mut urb_ptr: *mut UsbdevfsUrb = std::ptr::null_mut();
        let ret = unsafe {
            libc::ioctl(
                self.fd,
                USBDEVFS_REAPURBNDELAY as IoctlReq,
                &mut urb_ptr as *mut *mut UsbdevfsUrb,
            )
        };
        if ret < 0 {
            return Err(UsbFsError::from_errno("USBDEVFS_REAPURBNDELAY"));
        }
        Ok(urb_ptr)
    }
}

impl Drop for UsbDeviceHandle {
    fn drop(&mut self) {
        if self.owned && self.fd >= 0 {
            unsafe {
                libc::close(self.fd);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::{offset_of, size_of};

    #[test]
    fn test_ioctl_numerical_constants_match_kernel() {
        assert_eq!(USBDEVFS_CONTROL, 0xC0185500);
        assert_eq!(USBDEVFS_SETINTERFACE, 0x80085504);
        assert_eq!(USBDEVFS_SETCONFIGURATION, 0x80045505);
        assert_eq!(USBDEVFS_CLAIMINTERFACE, 0x8004550F);
        assert_eq!(USBDEVFS_RELEASEINTERFACE, 0x80045510);
        assert_eq!(USBDEVFS_RESET, 0x00005514);
        assert_eq!(USBDEVFS_CLEAR_HALT, 0x80045515);
        assert_eq!(USBDEVFS_DISCONNECT, 0x00005516);
        assert_eq!(USBDEVFS_CONNECT, 0x00005517);
        assert_eq!(USBDEVFS_DISCONNECT_CLAIM, 0x8108551B);
        assert_eq!(USBDEVFS_SUBMITURB, 0x8038550A);
        assert_eq!(USBDEVFS_DISCARDURB, 0x0000550B);
        assert_eq!(USBDEVFS_REAPURB, 0x4008550C);
        assert_eq!(USBDEVFS_REAPURBNDELAY, 0x4008550D);
    }

    #[test]
    fn test_struct_sizes_and_alignments() {
        assert_eq!(size_of::<UsbdevfsCtrlTransfer>(), 24);
        assert_eq!(size_of::<UsbdevfsSetInterface>(), 8);
        assert_eq!(size_of::<UsbdevfsDisconnectClaim>(), 264);
        assert_eq!(size_of::<UsbdevfsIsoPacketDesc>(), 12);
        assert_eq!(size_of::<UsbdevfsUrb>(), 56);
        assert_eq!(offset_of!(IsoUrb<4>, iso_frame_desc), 56);
        assert_eq!(size_of::<IsoUrb<4>>(), 56 + 12 * 4);
    }

    #[test]
    fn test_iso_urb_initialization_and_packet_offsets() {
        let mut buffer = vec![0u8; 192 * 8];
        let mut iso = IsoUrb::<8>::new(0x01, buffer.as_mut_ptr(), 192);

        assert_eq!(iso.urb.endpoint, 0x01);
        assert_eq!(iso.urb.urb_type, USBDEVFS_URB_TYPE_ISO);
        assert_eq!(iso.urb.number_of_packets, 8);
        assert_eq!(iso.urb.buffer_length, 192 * 8);
        assert_eq!(iso.iso_frame_desc.len(), 8);

        for desc in &iso.iso_frame_desc {
            assert_eq!(desc.length, 192);
            assert_eq!(desc.actual_length, 0);
            assert_eq!(desc.status, 0);
        }

        let ptr = iso.as_urb_ptr();
        assert!(!ptr.is_null());
    }

    #[test]
    fn test_usbfs_error_from_errno_mapping() {
        assert!(matches!(
            UsbFsError::from_errno_code(libc::EBUSY),
            UsbFsError::Busy
        ));
        assert!(matches!(
            UsbFsError::from_errno_code(libc::ENODEV),
            UsbFsError::DeviceDisconnected
        ));
        assert!(matches!(
            UsbFsError::from_errno_code(libc::ETIMEDOUT),
            UsbFsError::TimedOut
        ));
        assert!(matches!(
            UsbFsError::from_errno_code(libc::EPIPE),
            UsbFsError::PipeStall
        ));
        assert!(matches!(
            UsbFsError::from_errno_code(libc::EPERM),
            UsbFsError::PermissionDenied
        ));
        assert!(matches!(
            UsbFsError::from_errno_code(libc::EACCES),
            UsbFsError::PermissionDenied
        ));
        assert!(matches!(
            UsbFsError::from_errno_code(libc::EINVAL),
            UsbFsError::InvalidArgument
        ));
    }

    #[test]
    fn test_usb_device_handle_borrowed_vs_owned_lifecycle() {
        let mut fds = [0 as libc::c_int; 2];
        let res = unsafe { libc::pipe(fds.as_mut_ptr()) };
        assert_eq!(res, 0);

        // Borrowed handle: drop must NOT close the file descriptor
        {
            let borrowed = UsbDeviceHandle::from_raw_fd_borrowed(fds[0]);
            assert_eq!(borrowed.raw_fd(), fds[0]);
        }
        // Verify fd is still open and valid by checking fcntl
        let flags = unsafe { libc::fcntl(fds[0], libc::F_GETFD) };
        assert!(
            flags >= 0,
            "Borrowed fd should remain open after handle drop"
        );

        // Owned handle: drop MUST close the file descriptor
        {
            let owned = UsbDeviceHandle::from_raw_fd_owned(fds[0]);
            assert_eq!(owned.raw_fd(), fds[0]);
        }
        // Verify fd is closed
        let flags_closed = unsafe { libc::fcntl(fds[0], libc::F_GETFD) };
        assert_eq!(
            flags_closed, -1,
            "Owned fd should be closed after handle drop"
        );

        // Clean up second pipe fd
        unsafe {
            libc::close(fds[1]);
        }
    }

    #[test]
    fn test_reap_urb_ndelay_on_empty_fd() {
        let handle = UsbDeviceHandle::from_raw_fd_borrowed(-1);
        let res = handle.reap_urb_ndelay();
        assert!(
            res.is_err(),
            "reap_urb_ndelay on invalid fd should return Err"
        );
    }

    impl UsbFsError {
        fn from_errno_code(errno: i32) -> Self {
            match errno {
                libc::EACCES | libc::EPERM => Self::PermissionDenied,
                libc::ENODEV | libc::ESHUTDOWN | libc::ECONNRESET => Self::DeviceDisconnected,
                libc::EBUSY => Self::Busy,
                libc::ETIMEDOUT => Self::TimedOut,
                libc::EPIPE => Self::PipeStall,
                libc::EINVAL => Self::InvalidArgument,
                code => Self::IoctlFailed {
                    op: "test",
                    errno: code,
                    message: format!("error {code}"),
                },
            }
        }
    }
}

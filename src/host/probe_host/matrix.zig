//! OS, debug-probe and placement transport matrix for hardware sessions.
//!
//! `ra8_usbip` (`src/interfaces/usbip/`) exports an emulated RA8 USB peripheral
//! and `tools/usbip_attach.zig` speaks raw userspace URBs to test that export.
//! Neither attaches a physical probe to SEGGER's host driver (`JLink.exe` /
//! `JLinkExe` / `libjlinkarm`). Physical probe USB/IP requires kernel `usbipd`
//! on the probe host and `vhci-hcd` on the backend host, which only Linux
//! ships natively and which adds per-URB round-trip latency unsuitable for
//! interactive single-stepping. Wherever USB/IP is unavailable or unsuited,
//! `evaluate` selects native host-side execution (`native_local` or
//! `native_agent`) instead of assuming USB/IP works everywhere.
const std = @import("std");

pub const HostOs = enum { linux, windows, macos };
pub const ProbeKind = enum { jlink_usb, cmsis_dap, stlink, bootloader_serial };
pub const Placement = enum { same_host, server_attached, laptop_attached };
pub const Transport = enum { native_local, native_agent, usbip_vhci, unsupported };

pub const Decision = struct {
    probe_os: HostOs,
    backend_os: HostOs,
    probe: ProbeKind,
    placement: Placement,
    requested: Transport,
    chosen: Transport,
    supported: bool,
    fallback_used: bool,
    driver: []const u8,
    reason: []const u8,
};

const Query = struct {
    probe_os: HostOs,
    backend_os: HostOs,
    probe: ProbeKind,
    placement: Placement,
    requested: Transport,
};

pub fn evaluate(
    probe_os: HostOs,
    backend_os: HostOs,
    probe: ProbeKind,
    placement: Placement,
    prefer_usbip: bool,
) Decision {
    const local_ok = placement != .laptop_attached and probe_os == backend_os;
    const default_mode: Transport = if (local_ok) .native_local else .native_agent;
    const q: Query = .{
        .probe_os = probe_os,
        .backend_os = backend_os,
        .probe = probe,
        .placement = placement,
        .requested = if (prefer_usbip) .usbip_vhci else default_mode,
    };
    if (probe == .bootloader_serial) {
        return finish(q, .unsupported, false, false, "serial-bootloader-only", "bootloader exposes no SWD debug probe");
    }
    if (!prefer_usbip) {
        const why = if (default_mode == .native_local)
            "probe is local to the backend host"
        else
            "native probe-agent executes probe/UART operations on the probe host";
        return finish(q, default_mode, true, false, nativeDriver(probe_os, probe), why);
    }
    if (placement == .same_host) {
        return finish(
            q,
            .native_local,
            true,
            true,
            nativeDriver(probe_os, probe),
            "same-host placement uses local USB directly rather than loopback USB/IP",
        );
    }
    if (probe_os == .linux and backend_os == .linux) {
        return finish(
            q,
            .usbip_vhci,
            true,
            false,
            "linux usbip-host + vhci-hcd",
            "native Linux kernel USB/IP supported for batch flash/serial; high-RTT links add URB latency",
        );
    }
    return finish(
        q,
        default_mode,
        true,
        true,
        nativeDriver(probe_os, probe),
        usbipFallbackReason(probe_os, backend_os),
    );
}

fn finish(
    q: Query,
    chosen: Transport,
    supported: bool,
    fallback_used: bool,
    driver: []const u8,
    reason: []const u8,
) Decision {
    return .{
        .probe_os = q.probe_os,
        .backend_os = q.backend_os,
        .probe = q.probe,
        .placement = q.placement,
        .requested = q.requested,
        .chosen = chosen,
        .supported = supported,
        .fallback_used = fallback_used,
        .driver = driver,
        .reason = reason,
    };
}

fn nativeDriver(os: HostOs, probe: ProbeKind) []const u8 {
    return switch (probe) {
        .jlink_usb => switch (os) {
            .windows => "SEGGER J-Link WinUSB/JLink_x64 + CfgMgr32 CDC",
            .linux => "SEGGER JLinkExe libusb + /dev/serial/by-id",
            .macos => "SEGGER JLinkExe IOKit USB + /dev/cu.usbmodem CDC",
        },
        .cmsis_dap => switch (os) {
            .windows => "WinUSB/HID CMSIS-DAP",
            .linux => "hidraw/libusb CMSIS-DAP",
            .macos => "IOKit HID CMSIS-DAP",
        },
        .stlink => "libusb ST-LINK",
        .bootloader_serial => "OS CDC/UART",
    };
}

fn usbipFallbackReason(probe_os: HostOs, backend_os: HostOs) []const u8 {
    if (probe_os == .macos or backend_os == .macos) {
        return "macOS has no native kernel usbipd or vhci-hcd; falling back to native probe-agent";
    }
    if (backend_os == .windows) {
        return "Windows USB/IP client requires third-party usbip-win2 driver; falling back to native probe-agent";
    }
    return "Windows USB/IP export requires third-party usbipd-win service; falling back to native probe-agent";
}

pub fn writeJson(writer: *std.Io.Writer) !void {
    const entries = [_]Decision{
        evaluate(.windows, .windows, .jlink_usb, .same_host, false),
        evaluate(.windows, .linux, .jlink_usb, .laptop_attached, true),
        evaluate(.macos, .linux, .jlink_usb, .laptop_attached, true),
        evaluate(.linux, .linux, .jlink_usb, .laptop_attached, true),
        evaluate(.linux, .linux, .jlink_usb, .server_attached, false),
        evaluate(.macos, .macos, .jlink_usb, .server_attached, false),
        evaluate(.linux, .windows, .jlink_usb, .laptop_attached, true),
        evaluate(.linux, .linux, .bootloader_serial, .laptop_attached, true),
    };
    try std.json.Stringify.value(.{
        .emulated_usbip_distinct = true,
        .entries = entries,
    }, .{}, writer);
}

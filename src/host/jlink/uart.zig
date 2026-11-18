//! The serial console of an onboard J-Link, found from the probe's USB serial.
//! Port numbers are host-assigned and change across replugs and probe
//! firmware updates, so they are looked up at use time and never stored.
const builtin = @import("builtin");
const std = @import("std");

const linux = @import("uart/linux.zig");
const windows = @import("uart/windows.zig");

/// The port for `serial` (`COM13`, `/dev/serial/by-id/...`), or null when the
/// probe exposes none. `error.Unsupported` where no lookup exists for this host.
pub fn find(io: std.Io, serial: u64, out: []u8) !?[]const u8 {
    return switch (builtin.os.tag) {
        .windows => windows.find(serial, out),
        .linux => linux.find(io, serial, out),
        else => error.Unsupported,
    };
}

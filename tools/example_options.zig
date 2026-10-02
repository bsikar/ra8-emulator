//! Per-image emulator flags for the example table (RA8EMU-84).
//!
//! The LSM6DSO and the MAX17048 sit on a Click module, not on the EK-RA8D2,
//! so the emulator leaves 0x6B and 0x36 silent unless the run passes
//! `--click`, the same as a bench with no module fitted. The examples written
//! for that module (battery_monitor_demo, smbus_demo, imu_lsm6dso_demo) NAK
//! without it, which says nothing about the model, so the table fits the
//! module for them and only for them.
const std = @import("std");

pub const Extra = struct {
    image: []const u8,
    flags: []const []const u8,
};

const click = [_][]const u8{"--click"};

/// Images that need hardware the default board does not fit, and the flags
/// that fit it.
pub const extras = [_]Extra{
    .{ .image = "battery_monitor_demo.elf", .flags = &click },
    .{ .image = "imu_lsm6dso_demo.elf", .flags = &click },
    .{ .image = "smbus_demo.elf", .flags = &click },
};

/// The extra flags to run `image` with; empty for an image not listed.
pub fn flags(image: []const u8) []const []const u8 {
    for (extras) |entry| {
        if (std.mem.eql(u8, entry.image, image)) return entry.flags;
    }
    return &.{};
}

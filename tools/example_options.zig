//! Per-image emulator flags for the example table (RA8EMU-84).
//!
//! The LSM6DSO and the MAX17048 sit on a Click module, not on the EK-RA8D2,
//! so the emulator leaves 0x6B and 0x36 silent unless the run passes
//! `--click`, the same as a bench with no module fitted. The examples written
//! for that module (battery_monitor_demo, smbus_demo, imu_lsm6dso_demo) NAK
//! without it, which says nothing about the model, so the table fits the
//! module for them and only for them.
//!
//! The SD card on the SPI line starts blank, like a card fresh out of its
//! packet, and a firmware that only mounts reports "FAIL mount" on it. The
//! examples that provision their own files onto an existing FAT volume
//! (epub_open, epub_toc, tz_secure_only_sd) get a card formatted FAT16, the
//! filesystem that fits the default 32 MB card (RA8EMU-82).
const std = @import("std");

pub const Extra = struct {
    image: []const u8,
    flags: []const []const u8,
};

const click = [_][]const u8{"--click"};
const formatted = [_][]const u8{ "--sd-new", "fat16" };

/// Images that need hardware the default board does not fit, and the flags
/// that fit it.
pub const extras = [_]Extra{
    .{ .image = "battery_monitor_demo.elf", .flags = &click },
    .{ .image = "epub_open.elf", .flags = &formatted },
    .{ .image = "epub_toc.elf", .flags = &formatted },
    .{ .image = "imu_lsm6dso_demo.elf", .flags = &click },
    .{ .image = "smbus_demo.elf", .flags = &click },
    .{ .image = "tz_secure_only_sd.elf", .flags = &formatted },
};

/// The extra flags to run `image` with; empty for an image not listed.
pub fn flags(image: []const u8) []const []const u8 {
    for (extras) |entry| {
        if (std.mem.eql(u8, entry.image, image)) return entry.flags;
    }
    return &.{};
}

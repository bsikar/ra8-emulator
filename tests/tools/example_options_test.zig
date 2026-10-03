//! Covers tools/example_options.zig: which images run with extra flags.
const std = @import("std");
const table = @import("example_table");

const options = table.options;

test "an image with no entry runs with no extra flags" {
    try std.testing.expectEqual(@as(usize, 0), options.flags("blink_hal.elf").len);
}

test "the Click-module examples run with the module fitted" {
    for ([_][]const u8{ "battery_monitor_demo.elf", "imu_lsm6dso_demo.elf", "smbus_demo.elf" }) |image| {
        const got = options.flags(image);
        try std.testing.expectEqual(@as(usize, 1), got.len);
        try std.testing.expectEqualStrings("--click", got[0]);
    }
}

test "a match is on the whole file name" {
    try std.testing.expectEqual(@as(usize, 0), options.flags("smbus_demo").len);
    try std.testing.expectEqual(@as(usize, 0), options.flags("xsmbus_demo.elf").len);
}

test "the examples that mount an existing volume get a FAT16 card" {
    for ([_][]const u8{ "epub_open.elf", "epub_toc.elf", "tz_secure_only_sd.elf" }) |image| {
        const got = options.flags(image);
        try std.testing.expectEqual(@as(usize, 2), got.len);
        try std.testing.expectEqualStrings("--sd-new", got[0]);
        try std.testing.expectEqualStrings("fat16", got[1]);
    }
}

test "the example that formats its own FAT32 volume gets a 4 GB card" {
    const got = options.flags("ra8_io_sd_demo.elf");
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("--sd-size", got[0]);
    try std.testing.expectEqualStrings("4096", got[1]);
}

test "the TrustZone USB pair runs with the loop cable for two seconds" {
    const got = options.flags("tz_nsc_cgc_usb.elf");
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("--usb-loop", got[0]);
    try std.testing.expectEqualStrings("--ms", got[1]);
    try std.testing.expectEqualStrings("2000", got[2]);
}

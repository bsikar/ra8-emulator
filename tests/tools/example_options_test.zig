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

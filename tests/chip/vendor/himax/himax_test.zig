//! Covers src/chip/vendor/himax/himax.zig: Himax MCU exports.
const ra8 = @import("ra8");
const std = @import("std");

const himax = ra8.chip.vendor.himax;

test "Himax vendor namespace exposes HX6538 peripherals and machine" {
    try std.testing.expectEqual(@as(u16, 224), himax.hx6538.irqs.lines);
    try std.testing.expectEqualStrings("hx6538", himax.hx6538.machine.machine.name);
}

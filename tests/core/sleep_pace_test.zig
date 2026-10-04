//! Covers src/core/sleep_pace.zig.
const std = @import("std");
const ra8 = @import("ra8");
const sleep_pace = ra8.core.sleep_pace;

test "an awake core keeps the width it had" {
    try std.testing.expectEqual(@as(u32, 50_000), sleep_pace.width(50_000, false, &.{1_000_000}));
}

test "a sleeping core with no edge known keeps the width it had" {
    try std.testing.expectEqual(@as(u32, 50_000), sleep_pace.width(50_000, true, &.{}));
    try std.testing.expectEqual(@as(u32, 50_000), sleep_pace.width(50_000, true, &.{ 0, 0 }));
}

test "a sleeping core reaches straight to the nearest edge" {
    try std.testing.expectEqual(@as(u32, 250_000), sleep_pace.width(50_000, true, &.{ 1_000_000, 0, 250_000 }));
}

test "an edge inside the width never narrows it" {
    try std.testing.expectEqual(@as(u32, 50_000), sleep_pace.width(50_000, true, &.{ 2_000, 1_000_000 }));
}

test "an edge past the counter's reach stops at the largest stretch" {
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), sleep_pace.width(50_000, true, &.{1 << 40}));
}

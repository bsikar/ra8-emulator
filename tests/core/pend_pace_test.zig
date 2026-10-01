const std = @import("std");
const ra8 = @import("ra8");
const pend_pace = ra8.core.pend_pace;

test "a boundary with nothing standing keeps its configured width" {
    var pace = pend_pace.Pace{};
    try std.testing.expectEqual(@as(u32, 50_000), pace.widthFor(50_000, 0));
    try std.testing.expect(pace.quiet());
}

test "a standing pend narrows the next boundary" {
    var pace = pend_pace.Pace{};
    try std.testing.expectEqual(pend_pace.limits.while_standing, pace.widthFor(50_000, 1));
    try std.testing.expectEqual(@as(usize, 1), pace.narrowed);
    try std.testing.expect(!pace.quiet());
}

test "a boundary already at or inside the narrow width is left alone and not counted" {
    var pace = pend_pace.Pace{};
    try std.testing.expectEqual(@as(u32, 2_000), pace.widthFor(2_000, 3));
    try std.testing.expectEqual(@as(u32, 500), pace.widthFor(500, 3));
    try std.testing.expectEqual(@as(usize, 0), pace.narrowed);
    try std.testing.expect(pace.quiet());
}

test "the deepest unserved run narrowed for is remembered" {
    var pace = pend_pace.Pace{};
    _ = pace.widthFor(50_000, 2);
    _ = pace.widthFor(50_000, 7);
    _ = pace.widthFor(50_000, 1);
    try std.testing.expectEqual(@as(u64, 7), pace.longest_run);
    try std.testing.expectEqual(@as(usize, 3), pace.narrowed);
}

test "the width goes straight back once the pend is served" {
    var pace = pend_pace.Pace{};
    _ = pace.widthFor(50_000, 1);
    try std.testing.expectEqual(@as(u32, 50_000), pace.widthFor(50_000, 0));
    try std.testing.expectEqual(@as(usize, 1), pace.narrowed);
}

test "narrowing is counted once per boundary, not once per run" {
    var pace = pend_pace.Pace{};
    var i: usize = 0;
    while (i < 5) : (i += 1) _ = pace.widthFor(50_000, 1);
    try std.testing.expectEqual(@as(usize, 5), pace.narrowed);
    try std.testing.expectEqual(@as(u64, 1), pace.longest_run);
}

test "a narrowed boundary is never wider than the one asked for" {
    var pace = pend_pace.Pace{};
    const width = pace.widthFor(50_000, 4);
    try std.testing.expect(width <= 50_000);
    try std.testing.expect(width > 0);
}

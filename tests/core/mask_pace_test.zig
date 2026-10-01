const std = @import("std");
const ra8 = @import("ra8");
const mask_pace = ra8.core.mask_pace;

test "no stuck lift leaves the configured width alone" {
    var pace = mask_pace.Pace{ .on = true };
    try std.testing.expectEqual(@as(u32, 50_000), pace.widthFor(50_000, 0));
    try std.testing.expect(pace.quiet());
}

test "a stuck run narrows the boundary and is counted" {
    var pace = mask_pace.Pace{ .on = true };
    try std.testing.expectEqual(mask_pace.limits.while_masked, pace.widthFor(50_000, 1));
    try std.testing.expectEqual(@as(usize, 1), pace.narrowed);
    try std.testing.expectEqual(@as(u64, 1), pace.longest_run);
    try std.testing.expect(!pace.quiet());
}

test "a width already inside the narrow one is untouched and not counted" {
    var pace = mask_pace.Pace{ .on = true };
    try std.testing.expectEqual(@as(u32, 500), pace.widthFor(500, 9));
    try std.testing.expectEqual(mask_pace.limits.while_masked, pace.widthFor(mask_pace.limits.while_masked, 9));
    try std.testing.expect(pace.quiet());
}

test "the longest run is the worst one seen, not the last" {
    var pace = mask_pace.Pace{ .on = true };
    _ = pace.widthFor(50_000, 7);
    _ = pace.widthFor(50_000, 2);
    try std.testing.expectEqual(@as(u64, 7), pace.longest_run);
    try std.testing.expectEqual(@as(usize, 2), pace.narrowed);
}

test "a lift that clears puts the width straight back" {
    var pace = mask_pace.Pace{ .on = true };
    _ = pace.widthFor(50_000, 3);
    try std.testing.expectEqual(@as(u32, 50_000), pace.widthFor(50_000, 0));
    try std.testing.expectEqual(@as(usize, 1), pace.narrowed);
}

test "off by default, so the configured width always survives" {
    var pace = mask_pace.Pace{};
    try std.testing.expectEqual(@as(u32, 50_000), pace.widthFor(50_000, 9));
    try std.testing.expect(pace.quiet());
}

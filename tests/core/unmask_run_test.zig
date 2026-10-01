const std = @import("std");
const ra8 = @import("ra8");
const unmask = ra8.core.unmask;

test "a fresh seam has no stuck run" {
    const seam = unmask.Release{};
    try std.testing.expectEqual(@as(u64, 0), seam.run);
}

test "a boundary with nothing masked clears the run" {
    var seam = unmask.Release{ .run = 5, .stuck = 5 };
    seam.nothingMasked();
    try std.testing.expectEqual(@as(u64, 0), seam.run);
    try std.testing.expectEqual(@as(u64, 5), seam.stuck);
}

test "a fresh seam has no give-up sites to report" {
    const seam = unmask.Release{};
    try std.testing.expect(seam.gave_up.quiet());
}

test "give-ups at one site collect under that site" {
    var seam = unmask.Release{};
    seam.gave_up.record(0x0200_1654);
    seam.gave_up.record(0x0200_1654);
    seam.gave_up.record(0x0200_165E);
    const ranked = seam.gave_up.ranked();
    try std.testing.expectEqual(@as(usize, 2), ranked.len);
    try std.testing.expectEqual(@as(u32, 0x0200_1654), ranked[0].pc);
    try std.testing.expectEqual(@as(usize, 2), ranked[0].count);
    try std.testing.expectEqual(@as(usize, 1), ranked[1].count);
}

test "the busiest give-up site is reported first however late it arrives" {
    var seam = unmask.Release{};
    seam.gave_up.record(0x0200_3EF8);
    for (0..9) |_| seam.gave_up.record(0x0200_1654);
    try std.testing.expectEqual(@as(u32, 0x0200_1654), seam.gave_up.ranked()[0].pc);
}

test "sites past the table are counted, not dropped" {
    var seam = unmask.Release{};
    for (0..12) |i| seam.gave_up.record(0x0200_0000 + @as(u32, @intCast(i)) * 4);
    try std.testing.expectEqual(@as(usize, 4), seam.gave_up.overflowed);
    try std.testing.expect(!seam.gave_up.quiet());
}

test "a seam that never gave up stays quiet even after lifts cleared" {
    var seam = unmask.Release{ .lifted = 7, .stepped = 40 };
    seam.nothingMasked();
    try std.testing.expect(seam.gave_up.quiet());
}

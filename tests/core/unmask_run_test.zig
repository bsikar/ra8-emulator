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

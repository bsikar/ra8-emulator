//! Tests for the GLCDC frame boundary in src/periph/glcdc/glcdc_vsync.zig.
const std = @import("std");
const ra8 = @import("ra8");
const vsync = ra8.periph.glcdc_out.vsync;

const Seen = struct {
    times: [4]u64 = undefined,
    count: usize = 0,

    fn frame(context: *anyopaque, when_ns: u64) void {
        const self: *Seen = @ptrCast(@alignCast(context));
        self.times[self.count] = when_ns;
        self.count += 1;
    }
};

test "nothing is due before the first period ends" {
    var seen = Seen{};
    var boundary = vsync.Vsync{ .sink = .{ .context = &seen, .frame = Seen.frame } };
    boundary.tick(vsync.default_period_ns - 1);
    try std.testing.expectEqual(@as(usize, 0), seen.count);
    try std.testing.expectEqual(@as(u64, 0), boundary.boundaries);
}

test "each ended period hands the sink the time it ended in" {
    var seen = Seen{};
    var boundary = vsync.Vsync{ .sink = .{ .context = &seen, .frame = Seen.frame } };
    boundary.tick(vsync.default_period_ns);
    boundary.tick(vsync.default_period_ns + 5);
    boundary.tick(2 * vsync.default_period_ns + 7);
    try std.testing.expectEqual(@as(usize, 2), seen.count);
    try std.testing.expectEqual(vsync.default_period_ns, seen.times[0]);
    try std.testing.expectEqual(2 * vsync.default_period_ns + 7, seen.times[1]);
    try std.testing.expectEqual(3 * vsync.default_period_ns, boundary.next_ns);
}

test "a long chunk scans once and counts the periods it swallowed" {
    var seen = Seen{};
    var boundary = vsync.Vsync{ .sink = .{ .context = &seen, .frame = Seen.frame } };
    boundary.tick(4 * vsync.default_period_ns + 1);
    try std.testing.expectEqual(@as(usize, 1), seen.count);
    try std.testing.expectEqual(@as(u64, 4), boundary.boundaries);
    try std.testing.expectEqual(@as(u64, 3), boundary.swallowed);
    try std.testing.expectEqual(5 * vsync.default_period_ns, boundary.next_ns);
}

//! The arrival counter behind --break-sym.
const std = @import("std");
const ra8 = @import("ra8");
const breakpoint = ra8.core.breakpoint;

test "a break with no count stops on the first arrival" {
    var point = breakpoint.Break{ .address = 0x0200_1000 };
    try std.testing.expect(point.count());
    try std.testing.expect(point.reached);
    try std.testing.expectEqual(@as(u32, 1), point.seen);
}

test "a counted break does not stop before its arrival" {
    var point = breakpoint.Break{ .address = 0x0200_1000, .arrival = 3 };
    try std.testing.expect(!point.count());
    try std.testing.expect(!point.count());
    try std.testing.expect(!point.reached);
    try std.testing.expectEqual(@as(u32, 2), point.seen);
}

test "a counted break stops on the arrival it was given" {
    var point = breakpoint.Break{ .address = 0x0200_1000, .arrival = 3 };
    _ = point.count();
    _ = point.count();
    try std.testing.expect(point.count());
    try std.testing.expect(point.reached);
    try std.testing.expectEqual(@as(u32, 3), point.seen);
}

test "arrivals past the wanted one keep counting but stop nothing" {
    var point = breakpoint.Break{ .address = 0x0200_1000 };
    try std.testing.expect(point.count());
    try std.testing.expect(!point.count());
    try std.testing.expect(point.reached);
    try std.testing.expectEqual(@as(u32, 2), point.seen);
}

test "a run that falls short keeps the count it reached" {
    var point = breakpoint.Break{ .address = 0x0200_1000, .arrival = 10 };
    for (0..4) |_| _ = point.count();
    try std.testing.expect(!point.reached);
    try std.testing.expectEqual(@as(u32, 4), point.seen);
}

test "the watched address has the interworking bit cleared" {
    const odd = breakpoint.Break{ .address = 0x0200_1001 };
    const even = breakpoint.Break{ .address = 0x0200_1000 };
    try std.testing.expectEqual(@as(u64, 0x0200_1000), odd.watchedAddress());
    try std.testing.expectEqual(even.watchedAddress(), odd.watchedAddress());
}

test "a break starts unreached and uncounted" {
    const point = breakpoint.Break{ .address = 0x0200_1000 };
    try std.testing.expect(!point.reached);
    try std.testing.expectEqual(@as(u32, 0), point.seen);
    try std.testing.expectEqual(breakpoint.limits.first_arrival, point.arrival);
}

test "an unset break runs until an address no image reaches" {
    try std.testing.expectEqual(@as(u64, 0xFFFF_FFFF), breakpoint.limits.unreachable_address);
}

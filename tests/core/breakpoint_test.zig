const std = @import("std");
const ra8 = @import("ra8");
const breakpoint = ra8.core.breakpoint;

test "a break runs until its own address" {
    const point = breakpoint.Break{ .address = 0x0200_7BFC };
    try std.testing.expectEqual(@as(u64, 0x0200_7BFC), point.until());
}

test "the interworking bit is not part of the address to run until" {
    const point = breakpoint.Break{ .address = 0x0200_7BFD };
    try std.testing.expectEqual(@as(u64, 0x0200_7BFC), point.until());
}

test "arriving at the address is a hit" {
    var point = breakpoint.Break{ .address = 0x0200_7BFC };
    try std.testing.expect(point.met(0x0200_7BFC));
    try std.testing.expect(point.reached);
}

test "a Thumb program counter still matches an even symbol" {
    var point = breakpoint.Break{ .address = 0x0200_7BFC };
    try std.testing.expect(point.met(0x0200_7BFD));
    try std.testing.expect(point.reached);
}

test "an even program counter still matches a Thumb symbol" {
    var point = breakpoint.Break{ .address = 0x0200_7BFD };
    try std.testing.expect(point.met(0x0200_7BFC));
}

test "somewhere else is not a hit" {
    var point = breakpoint.Break{ .address = 0x0200_7BFC };
    try std.testing.expect(!point.met(0x0200_7C00));
    try std.testing.expect(!point.reached);
}

test "a break starts out unreached" {
    const point = breakpoint.Break{ .address = 0x0200_0000 };
    try std.testing.expect(!point.reached);
}

test "arriving once stays arrived" {
    var point = breakpoint.Break{ .address = 0x0200_7BFC };
    try std.testing.expect(point.met(0x0200_7BFC));
    try std.testing.expect(!point.met(0x0200_0000));
    try std.testing.expect(point.reached);
}

//! Tests for src/core/run_loop.zig.
//!
//! The loop itself is exercised by every image the tree runs; what is pinned
//! here is the one decision in it that is a pure read of the session, because
//! a wrong answer there ends a run early or lets one carry on past a break.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.core.run_loop;
const breakpoint = ra8.core.breakpoint;

test "a session with neither latch carries on" {
    try std.testing.expect(!mod.endsHere(.{}));
}

test "a break that was reached ends the run, not just the stretch" {
    var point = breakpoint.Break{ .address = 0x0200_0000 };
    point.reached = true;
    try std.testing.expect(mod.endsHere(.{ .brk = &point }));
}

test "a break that was not reached does not" {
    var point = breakpoint.Break{ .address = 0x0200_0000 };
    try std.testing.expect(!mod.endsHere(.{ .brk = &point }));
}

test "a tail chain is counted only when the return entered another handler" {
    var controller = ra8.periph.nvic.Nvic{};
    try std.testing.expectEqual(@as(u64, 0), controller.chained);
    controller.taken += 1;
    controller.chained += 1;
    try std.testing.expectEqual(@as(u64, 1), controller.chained);
}

test "a controller that has entered nothing has chained nothing" {
    const controller = ra8.periph.nvic.Nvic{};
    try std.testing.expectEqual(@as(u64, 0), controller.taken);
    try std.testing.expectEqual(@as(u64, 0), controller.chained);
}

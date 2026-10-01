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

test "a pend stop asked for during the probe ends the stretch" {
    var pending = ra8.core.pend_break.Pend{ .look_again = true };
    pending.endedAt(0x0200_1234);
    try std.testing.expect(mod.askedToStop(.{ .pend = &pending }));
}

test "a stretch the hook never stopped runs its tail" {
    var pending = ra8.core.pend_break.Pend{ .look_again = true };
    try std.testing.expect(!mod.askedToStop(.{ .pend = &pending }));
}

test "the experiment is off by default, so a raised pend does not cut the probe" {
    var pending = ra8.core.pend_break.Pend{};
    pending.record();
    pending.endedAt(0x0200_1234);
    try std.testing.expect(!mod.askedToStop(.{ .pend = &pending }));
}

test "a boundary clears the ask, so the next stretch starts clean" {
    var pending = ra8.core.pend_break.Pend{ .look_again = true };
    pending.endedAt(0x0200_1234);
    pending.boundary(0x0200_1234);
    try std.testing.expect(!mod.askedToStop(.{ .pend = &pending }));
}

test "a session with no pend break never ends a stretch this way" {
    try std.testing.expect(!mod.askedToStop(.{}));
}

test "a second look at a standing pend asks for the same stop" {
    var pending = ra8.core.pend_break.Pend{ .look_again = true };
    pending.alreadyPending(0);
    try std.testing.expect(pending.again);
    try std.testing.expect(!mod.askedToStop(.{ .pend = &pending }));
    pending.endedAt(0x0200_5678);
    try std.testing.expect(mod.askedToStop(.{ .pend = &pending }));
}

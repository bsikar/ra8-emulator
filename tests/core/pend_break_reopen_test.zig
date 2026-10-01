//! Where the stretch after a pend stop opens, and why.
//!
//! Split from tests/core/pend_break_test.zig the way unmask_run_test.zig
//! sits beside unmask_test.zig: these drive the reopen classification
//! (re-entry, served by a handler, moved by the mask lift, run past) and
//! that file drives the latch and the swallowed count.
const std = @import("std");
const ra8 = @import("ra8");
const pend_break = ra8.core.pend_break;

test "a stretch reopening on the stop address counts as a re-entry" {
    var pending = pend_break.Pend{};
    pending.endedAt(0x02002458);
    pending.boundary(0x02002458);
    try std.testing.expectEqual(@as(usize, 1), pending.reentered);
    try std.testing.expectEqual(@as(u32, 0x02002458), pending.reentered_at);
    try std.testing.expectEqual(@as(usize, 0), pending.reopened);
}

test "a stretch reopening past the stop address is counted apart" {
    var pending = pend_break.Pend{};
    pending.endedAt(0x02002458);
    pending.boundary(0x0200245A);
    try std.testing.expectEqual(@as(usize, 0), pending.reentered);
    try std.testing.expectEqual(@as(usize, 1), pending.reopened);
    try std.testing.expectEqual(@as(u32, 0x0200245A), pending.reopened_at);
    try std.testing.expectEqual(@as(u32, 0x02002458), pending.reopened_from);
}

test "the first mismatched pair is kept, not the latest" {
    var pending = pend_break.Pend{};
    pending.endedAt(0x02002458);
    pending.boundary(0x0200245A);
    pending.endedAt(0x02002CFC);
    pending.boundary(0x02002D00);
    try std.testing.expectEqual(@as(usize, 2), pending.reopened);
    try std.testing.expectEqual(@as(u32, 0x0200245A), pending.reopened_at);
    try std.testing.expectEqual(@as(u32, 0x02002458), pending.reopened_from);
}

test "every pend stop lands in exactly one of the counters" {
    var pending = pend_break.Pend{};
    pending.endedAt(0x02002458);
    pending.boundary(0x02002458);
    pending.endedAt(0x02002458);
    pending.boundary(0x0200245A);
    pending.endedAt(0x02002458);
    pending.boundary(0x02002458);
    try std.testing.expectEqual(@as(usize, 3), pending.reentered + pending.reopened);
}

test "a boundary with no pend stop behind it counts neither way" {
    var pending = pend_break.Pend{};
    pending.boundary(0x02002458);
    pending.boundary(0x0200245A);
    try std.testing.expectEqual(@as(usize, 0), pending.reentered);
    try std.testing.expectEqual(@as(usize, 0), pending.reopened);
    try std.testing.expect(!pending.reopened_placed);
}

test "a stop is consumed by the next boundary only" {
    var pending = pend_break.Pend{};
    pending.endedAt(0x02002458);
    pending.boundary(0x0200245A);
    pending.boundary(0x0200245A);
    pending.boundary(0x02002458);
    try std.testing.expectEqual(@as(usize, 1), pending.reopened);
    try std.testing.expectEqual(@as(usize, 0), pending.reentered);
}

test "a stretch opening in the handler the boundary entered is not past the store" {
    var pending = pend_break.Pend{};
    pending.endedAt(0x0200021E);
    pending.entered(15);
    pending.boundary(0x020015D8);
    try std.testing.expectEqual(@as(usize, 0), pending.reopened);
    try std.testing.expectEqual(@as(usize, 1), pending.handled);
    try std.testing.expectEqual(@as(u16, 15), pending.handled_exception);
    try std.testing.expectEqual(@as(u32, 0x020015D8), pending.handled_at);
    try std.testing.expectEqual(@as(u32, 0x0200021E), pending.handled_from);
}

test "a stretch reopening on the stop is a re-entry even after an entry" {
    var pending = pend_break.Pend{};
    pending.endedAt(0x02002CFC);
    pending.entered(14);
    pending.boundary(0x02002CFC);
    try std.testing.expectEqual(@as(usize, 1), pending.reentered);
    try std.testing.expectEqual(@as(usize, 0), pending.handled);
}

test "an entry describes only the boundary it happened at" {
    var pending = pend_break.Pend{};
    pending.entered(15);
    pending.boundary(0x020015D8);
    pending.endedAt(0x0200021E);
    pending.boundary(0x02000220);
    try std.testing.expectEqual(@as(usize, 0), pending.handled);
    try std.testing.expectEqual(@as(usize, 1), pending.reopened);
}

test "the first handled case is kept, not the latest" {
    var pending = pend_break.Pend{};
    pending.endedAt(0x0200021E);
    pending.entered(15);
    pending.boundary(0x020015D8);
    pending.endedAt(0x02003422);
    pending.entered(14);
    pending.boundary(0x02003430);
    try std.testing.expectEqual(@as(usize, 2), pending.handled);
    try std.testing.expectEqual(@as(u16, 15), pending.handled_exception);
    try std.testing.expectEqual(@as(u32, 0x020015D8), pending.handled_at);
}

test "re-entries, handled stops and runs past all count as consumed" {
    var pending = pend_break.Pend{};
    pending.endedAt(0x02002458);
    pending.boundary(0x02002458);
    pending.endedAt(0x02002458);
    pending.entered(15);
    pending.boundary(0x020015D8);
    pending.endedAt(0x02002458);
    pending.boundary(0x0200245A);
    try std.testing.expectEqual(@as(usize, 3), pending.consumed());
}

test "a stretch opening where the mask lift stepped to is not past the store" {
    var pending = pend_break.Pend{};
    pending.endedAt(0x020054D0);
    pending.lifted();
    pending.boundary(0x020054B2);
    try std.testing.expectEqual(@as(usize, 0), pending.reopened);
    try std.testing.expectEqual(@as(usize, 1), pending.lift_moved);
    try std.testing.expectEqual(@as(u32, 0x020054B2), pending.lift_moved_at);
    try std.testing.expectEqual(@as(u32, 0x020054D0), pending.lift_moved_from);
}

test "a handler entered after a lift counts as handled, not as the lift" {
    var pending = pend_break.Pend{};
    pending.endedAt(0x020054D0);
    pending.lifted();
    pending.entered(15);
    pending.boundary(0x0200474C);
    try std.testing.expectEqual(@as(usize, 1), pending.handled);
    try std.testing.expectEqual(@as(usize, 0), pending.lift_moved);
}

test "a lift describes only the boundary it happened at" {
    var pending = pend_break.Pend{};
    pending.lifted();
    pending.boundary(0x020054B2);
    pending.endedAt(0x020054D0);
    pending.boundary(0x020054D2);
    try std.testing.expectEqual(@as(usize, 0), pending.lift_moved);
    try std.testing.expectEqual(@as(usize, 1), pending.reopened);
}

test "stops the lift moved count as consumed" {
    var pending = pend_break.Pend{};
    pending.endedAt(0x020054D0);
    pending.lifted();
    pending.boundary(0x020054B2);
    try std.testing.expectEqual(@as(usize, 1), pending.consumed());
}

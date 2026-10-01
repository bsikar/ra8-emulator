//! A pend the firmware wrote: latched once, taken once, counted always.
const std = @import("std");
const ra8 = @import("ra8");
const pend_break = ra8.core.pend_break;

test "nothing is latched before a store" {
    var pending = pend_break.Pend{};
    try std.testing.expect(!pending.take());
    try std.testing.expectEqual(@as(usize, 0), pending.cuts);
}

test "a recorded pend is taken exactly once" {
    var pending = pend_break.Pend{};
    pending.record();
    try std.testing.expect(pending.take());
    try std.testing.expect(!pending.take());
    try std.testing.expectEqual(@as(usize, 1), pending.cuts);
}

test "two stores before a boundary end one stretch and count two" {
    var pending = pend_break.Pend{};
    pending.record();
    pending.record();
    try std.testing.expect(pending.take());
    try std.testing.expect(!pending.take());
    try std.testing.expectEqual(@as(usize, 2), pending.cuts);
}

test "the count survives many takes" {
    var pending = pend_break.Pend{};
    for (0..72) |_| {
        pending.record();
        try std.testing.expect(pending.take());
    }
    try std.testing.expectEqual(@as(usize, 72), pending.cuts);
    try std.testing.expect(!pending.take());
}

test "a pend that lands on one already standing is counted, not latched" {
    var pending = pend_break.Pend{};
    pending.alreadyPending(0);
    pending.alreadyPending(0);
    try std.testing.expectEqual(@as(usize, 2), pending.swallowed);
    try std.testing.expectEqual(@as(usize, 0), pending.cuts);
    try std.testing.expect(!pending.take());
}

test "swallowed pends do not disturb the ones that did raise" {
    var pending = pend_break.Pend{};
    pending.record();
    pending.alreadyPending(0);
    try std.testing.expectEqual(@as(usize, 1), pending.cuts);
    try std.testing.expectEqual(@as(usize, 1), pending.swallowed);
    try std.testing.expect(pending.take());
    try std.testing.expect(!pending.take());
}

test "a swallowed store inside a handler is counted apart" {
    var pending = pend_break.Pend{};
    pending.alreadyPending(14);
    pending.alreadyPending(0);
    pending.alreadyPending(15);
    try std.testing.expectEqual(@as(usize, 3), pending.swallowed);
    try std.testing.expectEqual(@as(usize, 2), pending.swallowed_in_handler);
}

test "the first swallowed store keeps where it happened, Thread mode included" {
    var pending = pend_break.Pend{};
    pending.alreadyPending(0);
    pending.alreadyPending(14);
    try std.testing.expectEqual(@as(u16, 0), pending.swallowed_under);
    try std.testing.expectEqual(@as(usize, 1), pending.swallowed_in_handler);
}

test "the worst stretch is the most swallowed stores between two boundaries" {
    var pending = pend_break.Pend{};
    pending.alreadyPending(0);
    pending.alreadyPending(0);
    pending.alreadyPending(0);
    pending.boundary();
    pending.alreadyPending(0);
    pending.boundary();
    try std.testing.expectEqual(@as(usize, 3), pending.longest_stretch);
    try std.testing.expectEqual(@as(usize, 2), pending.stretches);
}

test "a stretch that swallowed nothing is not counted" {
    var pending = pend_break.Pend{};
    pending.boundary();
    pending.boundary();
    pending.alreadyPending(0);
    pending.boundary();
    try std.testing.expectEqual(@as(usize, 1), pending.stretches);
    try std.testing.expectEqual(@as(usize, 1), pending.longest_stretch);
}

test "the stretch still open is not folded in until its boundary" {
    var pending = pend_break.Pend{};
    pending.alreadyPending(0);
    pending.alreadyPending(0);
    try std.testing.expectEqual(@as(usize, 0), pending.longest_stretch);
    try std.testing.expectEqual(@as(usize, 2), pending.in_stretch);
}

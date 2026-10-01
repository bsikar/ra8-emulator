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
    pending.alreadyPending();
    pending.alreadyPending();
    try std.testing.expectEqual(@as(usize, 2), pending.swallowed);
    try std.testing.expectEqual(@as(usize, 0), pending.cuts);
    try std.testing.expect(!pending.take());
}

test "swallowed pends do not disturb the ones that did raise" {
    var pending = pend_break.Pend{};
    pending.record();
    pending.alreadyPending();
    try std.testing.expectEqual(@as(usize, 1), pending.cuts);
    try std.testing.expectEqual(@as(usize, 1), pending.swallowed);
    try std.testing.expect(pending.take());
    try std.testing.expect(!pending.take());
}

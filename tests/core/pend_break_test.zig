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
    pending.boundary(0);
    pending.alreadyPending(0);
    pending.boundary(0);
    try std.testing.expectEqual(@as(usize, 3), pending.longest_stretch);
    try std.testing.expectEqual(@as(usize, 2), pending.stretches);
}

test "a stretch that swallowed nothing is not counted" {
    var pending = pend_break.Pend{};
    pending.boundary(0);
    pending.boundary(0);
    pending.alreadyPending(0);
    pending.boundary(0);
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

test "no look is given unless a policy switched one on" {
    var quiet = pend_break.Pend{};
    quiet.alreadyPending(0);
    quiet.alreadyPending(0);
    try std.testing.expect(!quiet.again);
    try std.testing.expectEqual(@as(usize, 0), quiet.look.given);
    try std.testing.expectEqual(@as(usize, 2), quiet.swallowed);
}

test "a Thread-mode swallowed store asks for another look" {
    var pending = pend_break.Pend{ .look = .{ .policy = .every } };
    pending.alreadyPending(0);
    try std.testing.expect(pending.again);
    try std.testing.expectEqual(@as(usize, 1), pending.look.given);
    try std.testing.expect(pending.lookAgain());
    try std.testing.expect(!pending.lookAgain());
}

test "a swallowed store inside a handler asks for no look" {
    var pending = pend_break.Pend{ .look = .{ .policy = .every } };
    pending.alreadyPending(14);
    pending.alreadyPending(15);
    try std.testing.expect(!pending.again);
    try std.testing.expectEqual(@as(usize, 0), pending.look.given);
    try std.testing.expect(!pending.lookAgain());
}

test "the second look is its own latch and leaves a raised pend alone" {
    var pending = pend_break.Pend{ .look = .{ .policy = .every } };
    pending.record();
    pending.alreadyPending(0);
    try std.testing.expect(pending.lookAgain());
    try std.testing.expect(pending.take());
    try std.testing.expectEqual(@as(usize, 1), pending.cuts);
}

test "under per-rise one re-ask per rise gets a look and the rest do not" {
    var pending = pend_break.Pend{ .look = .{ .policy = .per_rise } };
    pending.alreadyPending(0);
    try std.testing.expect(pending.again);
    pending.alreadyPending(0);
    pending.alreadyPending(0);
    try std.testing.expectEqual(@as(usize, 1), pending.look.given);
    try std.testing.expectEqual(@as(usize, 2), pending.look.refused);
    try std.testing.expectEqual(@as(usize, 3), pending.swallowed);
}

test "a boundary does not hand the allowance back, because the look made it" {
    var pending = pend_break.Pend{ .look = .{ .policy = .per_rise } };
    pending.alreadyPending(0);
    try std.testing.expect(pending.lookAgain());
    pending.boundary(0x0200_1234);
    pending.alreadyPending(0);
    try std.testing.expect(!pending.lookAgain());
    try std.testing.expectEqual(@as(usize, 1), pending.look.given);
}

test "the next rise gets its own look" {
    var pending = pend_break.Pend{ .look = .{ .policy = .per_rise } };
    pending.alreadyPending(0);
    try std.testing.expect(pending.lookAgain());
    pending.record();
    pending.alreadyPending(0);
    try std.testing.expect(pending.lookAgain());
    try std.testing.expectEqual(@as(usize, 2), pending.look.given);
}

test "a stretch that opens where the last one ended is counted" {
    var pending = pend_break.Pend{};
    pending.record();
    pending.endedAt(0x02002458);
    pending.boundary(0x02002458);
    try std.testing.expectEqual(@as(usize, 1), pending.reentered);
    try std.testing.expectEqual(@as(u32, 0x02002458), pending.reentered_at);
}

test "a stretch that opens past the store is not counted" {
    var pending = pend_break.Pend{};
    pending.record();
    pending.endedAt(0x02002458);
    pending.boundary(0x0200245A);
    try std.testing.expectEqual(@as(usize, 0), pending.reentered);
    try std.testing.expectEqual(@as(u32, 0), pending.reentered_at);
}

test "the ended address is spent by the boundary that reads it" {
    var pending = pend_break.Pend{};
    pending.endedAt(0x02002458);
    pending.boundary(0x02002458);
    pending.boundary(0x02002458);
    try std.testing.expectEqual(@as(usize, 1), pending.reentered);
}

test "a boundary with no store behind it counts nothing" {
    var pending = pend_break.Pend{};
    pending.boundary(0);
    pending.boundary(0x02002458);
    try std.testing.expectEqual(@as(usize, 0), pending.reentered);
    try std.testing.expect(!pending.ended);
}

test "the first re-entry address is kept, not the latest" {
    var pending = pend_break.Pend{};
    pending.endedAt(0x02002458);
    pending.boundary(0x02002458);
    pending.endedAt(0x0200213E);
    pending.boundary(0x0200213E);
    try std.testing.expectEqual(@as(usize, 2), pending.reentered);
    try std.testing.expectEqual(@as(u32, 0x02002458), pending.reentered_at);
}

test "closing the swallow books still works alongside the address check" {
    var pending = pend_break.Pend{};
    pending.alreadyPending(0);
    pending.alreadyPending(0);
    pending.endedAt(0x02002458);
    pending.boundary(0x02002458);
    try std.testing.expectEqual(@as(usize, 2), pending.longest_stretch);
    try std.testing.expectEqual(@as(usize, 1), pending.stretches);
    try std.testing.expectEqual(@as(usize, 1), pending.reentered);
}

test "the first swallowed store address is kept" {
    var pending = pend_break.Pend{};
    pending.swallowedAt(0x02002458);
    pending.swallowedAt(0x02002458);
    try std.testing.expect(pending.swallowed_placed);
    try std.testing.expectEqual(@as(u32, 0x02002458), pending.swallowed_at);
    try std.testing.expectEqual(@as(usize, 0), pending.swallowed_elsewhere);
}

test "a swallowed store from another address is counted apart" {
    var pending = pend_break.Pend{};
    pending.swallowedAt(0x02002458);
    pending.swallowedAt(0x02002CFC);
    pending.swallowedAt(0x02002CFC);
    pending.swallowedAt(0x02002458);
    try std.testing.expectEqual(@as(u32, 0x02002458), pending.swallowed_at);
    try std.testing.expectEqual(@as(usize, 2), pending.swallowed_elsewhere);
}

test "no swallowed store leaves the address unplaced" {
    var pending = pend_break.Pend{};
    pending.alreadyPending(0);
    try std.testing.expect(!pending.swallowed_placed);
    try std.testing.expectEqual(@as(u32, 0), pending.swallowed_at);
}

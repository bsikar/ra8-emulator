const std = @import("std");
const ra8 = @import("ra8");
const pend_look = ra8.core.pend_look;

test "the first re-ask of a stretch gets the look" {
    var look = pend_look.Look{ .policy = .per_rise };
    try std.testing.expect(look.ask());
    try std.testing.expectEqual(@as(usize, 1), look.given);
    try std.testing.expectEqual(@as(usize, 0), look.refused);
}

test "later re-asks inside the same stretch are refused and counted" {
    var look = pend_look.Look{ .policy = .per_rise };
    _ = look.ask();
    try std.testing.expect(!look.ask());
    try std.testing.expect(!look.ask());
    try std.testing.expectEqual(@as(usize, 1), look.given);
    try std.testing.expectEqual(@as(usize, 2), look.refused);
}

test "a new rise opens the allowance again" {
    var look = pend_look.Look{ .policy = .per_rise };
    _ = look.ask();
    look.rearm();
    try std.testing.expect(look.ask());
    try std.testing.expectEqual(@as(usize, 2), look.given);
    try std.testing.expectEqual(@as(usize, 0), look.refused);
}

test "every mode gives a look to each re-ask and refuses none" {
    var look = pend_look.Look{ .policy = .every };
    try std.testing.expect(look.ask());
    try std.testing.expect(look.ask());
    try std.testing.expect(look.ask());
    try std.testing.expectEqual(@as(usize, 3), look.given);
    try std.testing.expectEqual(@as(usize, 0), look.refused);
}

test "a look that was never asked for says nothing" {
    var look = pend_look.Look{ .policy = .per_rise };
    try std.testing.expect(look.quiet());
    look.rearm();
    try std.testing.expect(look.quiet());
    _ = look.ask();
    try std.testing.expect(!look.quiet());
}

test "the cost is one look per rise however big the pile is" {
    var look = pend_look.Look{ .policy = .per_rise };
    var rise: usize = 0;
    while (rise < 4) : (rise += 1) {
        var ask: usize = 0;
        while (ask < 50) : (ask += 1) _ = look.ask();
        look.rearm();
    }
    try std.testing.expectEqual(@as(usize, 4), look.given);
    try std.testing.expectEqual(@as(usize, 196), look.refused);
}

test "the default policy gives no look at all" {
    var look = pend_look.Look{};
    try std.testing.expect(!look.ask());
    try std.testing.expect(!look.ask());
    try std.testing.expectEqual(@as(usize, 0), look.given);
    try std.testing.expectEqual(@as(usize, 0), look.refused);
    try std.testing.expect(look.quiet());
    try std.testing.expect(!look.cuts());
}

test "both experiments cut a stopped stretch short" {
    const rise = pend_look.Look{ .policy = .per_rise };
    const every = pend_look.Look{ .policy = .every };
    try std.testing.expect(rise.cuts());
    try std.testing.expect(every.cuts());
}

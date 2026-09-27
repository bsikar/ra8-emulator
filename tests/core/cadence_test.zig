const std = @import("std");
const ra8 = @import("ra8");

const cadence = ra8.core.cadence;

test "the default boundary is narrower than dev's chunk" {
    try std.testing.expect(cadence.instructions < 500_000);
}

test "a whole boundary is taken when the budget allows" {
    const pace = cadence.Cadence{};
    try std.testing.expectEqual(@as(usize, cadence.instructions), pace.chunk(1_000_000));
}

test "the last stretch is what is left of the budget" {
    const pace = cadence.Cadence{ .per_boundary = 1000 };
    try std.testing.expectEqual(@as(usize, 250), pace.chunk(250));
}

test "a stretch exactly one boundary wide is one boundary" {
    const pace = cadence.Cadence{ .per_boundary = 1000 };
    try std.testing.expectEqual(@as(usize, 1000), pace.chunk(1000));
}

test "a spent budget closes no boundary" {
    const pace = cadence.Cadence{};
    try std.testing.expect(!pace.closes(0));
}

test "a budget with anything left closes one" {
    const pace = cadence.Cadence{};
    try std.testing.expect(pace.closes(1));
}

test "a budget of exactly one boundary ticks nothing" {
    const pace = cadence.Cadence{ .per_boundary = 1000 };
    try std.testing.expectEqual(@as(usize, 0), pace.boundaries(1000));
}

test "a budget of two boundaries ticks once" {
    const pace = cadence.Cadence{ .per_boundary = 1000 };
    try std.testing.expectEqual(@as(usize, 1), pace.boundaries(2000));
}

test "a partial last stretch still ticks after the whole ones" {
    const pace = cadence.Cadence{ .per_boundary = 1000 };
    try std.testing.expectEqual(@as(usize, 2), pace.boundaries(2500));
}

test "a budget shorter than one boundary ticks nothing" {
    const pace = cadence.Cadence{ .per_boundary = 1000 };
    try std.testing.expectEqual(@as(usize, 0), pace.boundaries(999));
}

test "an empty budget ticks nothing" {
    const pace = cadence.Cadence{ .per_boundary = 1000 };
    try std.testing.expectEqual(@as(usize, 0), pace.boundaries(0));
}

test "a zero boundary ticks nothing rather than dividing by it" {
    const pace = cadence.Cadence{ .per_boundary = 0 };
    try std.testing.expectEqual(@as(usize, 0), pace.boundaries(10_000));
}

test "the default budget passes through enough boundaries for a bounded poll" {
    const pace = cadence.Cadence{};
    // The timer image polls GTCNT 400000 times; at dev's 500000-wide chunk
    // the whole default budget was three ticks.
    try std.testing.expect(pace.boundaries(2_000_000) >= 20);
}

test "the clocks charge a boundary's worth of instructions per boundary" {
    try std.testing.expectEqual(cadence.instructions, ra8.periph.clocks.chunk_instructions);
}

test "boundaries and chunks agree on how a budget is cut" {
    const pace = cadence.Cadence{ .per_boundary = 64 };
    var remaining: usize = 1000;
    var ticks: usize = 0;
    while (remaining > 0) {
        remaining -= pace.chunk(remaining);
        if (!pace.closes(remaining)) break;
        ticks += 1;
    }
    try std.testing.expectEqual(pace.boundaries(1000), ticks);
}

const std = @import("std");
const ra8 = @import("ra8");
const unmask = ra8.core.unmask;
const fault = ra8.core.fault;

/// A core whose PRIMASK follows a script, one value per step, and whose
/// PC walks two bytes a step. The same shape tests/core/unmask_test.zig
/// uses; kept local because what these tests drive is the running tally
/// rather than one lift's decision.
const Scripted = struct {
    masks: []const u32,
    step: usize = 0,
    pc: u32 = 0x0200_54B2,

    pub fn register(self: *Scripted, which: anytype) !u32 {
        return switch (which) {
            .primask => self.masks[@min(self.step, self.masks.len - 1)],
            .pc => self.pc,
            else => 0,
        };
    }

    pub fn runChunk(self: *Scripted, at: u32, count: usize, watch: ?*fault.Watch) !?fault.Fault {
        _ = at;
        _ = count;
        _ = watch;
        self.step += 1;
        self.pc += 2;
        return null;
    }
};

/// A core that only answers PRIMASK, which is all `nothingMasked` reads.
const Still = struct {
    primask: u32,

    pub fn register(self: *Still, which: anytype) !u32 {
        return switch (which) {
            .primask => self.primask,
            else => 0,
        };
    }
};

test "a fresh seam has no stuck run" {
    const seam = unmask.Release{};
    try std.testing.expectEqual(@as(u64, 0), seam.run);
}

test "a boundary with nothing masked clears the run" {
    var core = Still{ .primask = 0 };
    var seam = unmask.Release{ .run = 5, .stuck = 5 };
    try seam.nothingMasked(&core);
    try std.testing.expectEqual(@as(u64, 0), seam.run);
    try std.testing.expectEqual(@as(u64, 5), seam.stuck);
}

test "a fresh seam has no give-up sites to report" {
    const seam = unmask.Release{};
    try std.testing.expect(seam.gave_up.quiet());
}

test "give-ups at one site collect under that site" {
    var seam = unmask.Release{};
    seam.gave_up.record(0x0200_1654);
    seam.gave_up.record(0x0200_1654);
    seam.gave_up.record(0x0200_165E);
    const ranked = seam.gave_up.ranked();
    try std.testing.expectEqual(@as(usize, 2), ranked.len);
    try std.testing.expectEqual(@as(u32, 0x0200_1654), ranked[0].pc);
    try std.testing.expectEqual(@as(usize, 2), ranked[0].count);
    try std.testing.expectEqual(@as(usize, 1), ranked[1].count);
}

test "the busiest give-up site is reported first however late it arrives" {
    var seam = unmask.Release{};
    seam.gave_up.record(0x0200_3EF8);
    for (0..9) |_| seam.gave_up.record(0x0200_1654);
    try std.testing.expectEqual(@as(u32, 0x0200_1654), seam.gave_up.ranked()[0].pc);
}

test "sites past the table are counted, not dropped" {
    var seam = unmask.Release{};
    for (0..12) |i| seam.gave_up.record(0x0200_0000 + @as(u32, @intCast(i)) * 4);
    try std.testing.expectEqual(@as(usize, 4), seam.gave_up.overflowed);
    try std.testing.expect(!seam.gave_up.quiet());
}

test "a seam that never gave up stays quiet even after lifts cleared" {
    var core = Still{ .primask = 0 };
    var seam = unmask.Release{ .lifted = 7, .stepped = 40 };
    try seam.nothingMasked(&core);
    try std.testing.expect(seam.gave_up.quiet());
}

test "a fresh seam has not seen the firmware run unmasked" {
    const seam = unmask.Release{};
    try std.testing.expect(!seam.enabled_once);
    try std.testing.expectEqual(@as(u64, 0), seam.booting);
}

test "a quiet boundary with PRIMASK clear says the firmware is up" {
    var core = Still{ .primask = 0 };
    var seam = unmask.Release{};
    try seam.nothingMasked(&core);
    try std.testing.expect(seam.enabled_once);
}

test "a quiet boundary with PRIMASK set proves nothing" {
    var core = Still{ .primask = 1 };
    var seam = unmask.Release{};
    try seam.nothingMasked(&core);
    try std.testing.expect(!seam.enabled_once);
}

test "a fresh seam has no stubborn mask on record" {
    const seam = unmask.Release{};
    try std.testing.expectEqual(@as(u64, 0), seam.longest);
    try std.testing.expectEqual(@as(u64, 0), seam.longest_held);
}

test "a mask waited out leaves nothing held" {
    var core = Scripted{ .masks = &.{ 1, 1, 0 } };
    var seam = unmask.Release{};
    _ = try seam.lift(&core, 8);
    try std.testing.expectEqual(@as(u64, 0), seam.held);
    try std.testing.expectEqual(@as(u64, 0), seam.longest);
}

test "consecutive give-ups on one mask raise the stubborn figure" {
    var core = Scripted{ .masks = &.{1} };
    var seam = unmask.Release{};
    _ = try seam.lift(&core, 4);
    _ = try seam.lift(&core, 4);
    _ = try seam.lift(&core, 4);
    try std.testing.expectEqual(@as(u64, 3), seam.longest);
    try std.testing.expectEqual(@as(u64, 12), seam.longest_held);
}

test "a later shorter run does not lower the stubborn figure" {
    var stubborn = Scripted{ .masks = &.{1} };
    var seam = unmask.Release{};
    _ = try seam.lift(&stubborn, 4);
    _ = try seam.lift(&stubborn, 4);
    var clear = Still{ .primask = 0 };
    try seam.nothingMasked(&clear);
    var once = Scripted{ .masks = &.{1} };
    _ = try seam.lift(&once, 4);
    try std.testing.expectEqual(@as(u64, 2), seam.longest);
    try std.testing.expectEqual(@as(u64, 8), seam.longest_held);
}

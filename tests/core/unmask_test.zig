//! Tests for src/core/unmask.zig.
//!
//! The seam is driven by a fake core rather than the real engine for the
//! reason tests/core/idle_test.zig uses one: what matters is the decision,
//! and the decision is a function of what `primask` reads on each step. The
//! fake scripts a sequence of PRIMASK values, one per step, so a test can
//! say "masked for three instructions, then clear" without needing an image
//! that does that.
const std = @import("std");
const unmask = @import("ra8").core.unmask;
const fault = @import("ra8").core.fault;

/// A core whose PRIMASK follows a script and whose PC walks two bytes per
/// step, the width of the Thumb instructions this is about.
const Fake = struct {
    masks: []const u32,
    step: usize = 0,
    pc: u32 = 0x0200_029A,
    /// Steps after which runChunk reports a fault instead of running.
    faults_at: ?usize = null,

    pub fn register(self: *Fake, which: anytype) !u32 {
        return switch (which) {
            .primask => self.masks[@min(self.step, self.masks.len - 1)],
            .pc => self.pc,
            else => 0,
        };
    }

    pub fn runChunk(self: *Fake, at: u32, count: usize, watch: ?*fault.Watch) !?fault.Fault {
        _ = at;
        _ = count;
        _ = watch;
        if (self.faults_at) |when| if (self.step == when) {
            return fault.Fault{ .pc = 0xFFFF_FFFD, .detail = "exception return during a lift" };
        };
        self.step += 1;
        self.pc += 2;
        return null;
    }
};

test "a mask that is already clear costs nothing" {
    var core = Fake{ .masks = &.{0} };
    var seam = unmask.Release{};
    const lifted = try seam.lift(&core, 64);
    // The caller only asks for a lift once the controller says the pend is
    // masked, so this is the degenerate case: one step and it is clear.
    try std.testing.expect(lifted.cleared);
    try std.testing.expectEqual(@as(usize, 1), lifted.ran);
}

test "a mask four instructions wide is stepped out of and no further" {
    // ThreadX from the str the boundary lands on: cbnz, cpsie. The script
    // reads PRIMASK after each step, so masks[4] being clear means the
    // fourth step is the one that ran the cpsie.
    var core = Fake{ .masks = &.{ 1, 1, 1, 1, 0 } };
    var seam = unmask.Release{};
    const lifted = try seam.lift(&core, 64);
    try std.testing.expect(lifted.cleared);
    try std.testing.expectEqual(@as(usize, 4), lifted.ran);
    try std.testing.expectEqual(@as(u64, 1), seam.lifted);
    try std.testing.expectEqual(@as(u64, 4), seam.stepped);
    try std.testing.expectEqual(@as(u64, 0), seam.stuck);
}

test "a mask wider than the bound is left for the next boundary" {
    var core = Fake{ .masks = &.{1} };
    var seam = unmask.Release{};
    const lifted = try seam.lift(&core, 8);
    try std.testing.expect(!lifted.cleared);
    try std.testing.expectEqual(@as(usize, 8), lifted.ran);
    try std.testing.expectEqual(@as(u64, 1), seam.stuck);
    try std.testing.expectEqual(@as(u64, 0), seam.lifted);
}

test "the bound the caller passes is honoured, not the seam's own cap" {
    // The run loop passes the smaller of the budget left and limits.steps,
    // so a run with three instructions to go may not step four.
    var core = Fake{ .masks = &.{1} };
    var seam = unmask.Release{};
    const lifted = try seam.lift(&core, 3);
    try std.testing.expectEqual(@as(usize, 3), lifted.ran);
    try std.testing.expectEqual(@as(u64, 3), seam.stepped);
}

test "a zero bound steps nothing and reports the mask still standing" {
    var core = Fake{ .masks = &.{1} };
    var seam = unmask.Release{};
    const lifted = try seam.lift(&core, 0);
    try std.testing.expectEqual(@as(usize, 0), lifted.ran);
    try std.testing.expect(!lifted.cleared);
    try std.testing.expectEqual(@as(u64, 1), seam.stuck);
}

test "a faulting step abandons the lift rather than swallowing the fault" {
    var core = Fake{ .masks = &.{ 1, 1, 0 }, .faults_at = 1 };
    var seam = unmask.Release{};
    const lifted = try seam.lift(&core, 64);
    try std.testing.expect(!lifted.cleared);
    // One step ran before the fault, and it is still charged: it executed.
    try std.testing.expectEqual(@as(usize, 1), lifted.ran);
    try std.testing.expectEqual(@as(u64, 1), seam.faulted);
    try std.testing.expectEqual(@as(u64, 0), seam.stuck);
    try std.testing.expectEqual(@as(u64, 0), seam.lifted);
}

test "the instructions a lift spends accumulate across boundaries" {
    var core = Fake{ .masks = &.{ 1, 1, 0 } };
    var seam = unmask.Release{};
    _ = try seam.lift(&core, 64);
    core.step = 0;
    _ = try seam.lift(&core, 64);
    try std.testing.expectEqual(@as(u64, 2), seam.lifted);
    try std.testing.expectEqual(@as(u64, 4), seam.stepped);
}

test "a fresh seam is quiet and a lift makes it speak" {
    var seam = unmask.Release{};
    try std.testing.expect(seam.quiet());
    var core = Fake{ .masks = &.{ 1, 0 } };
    _ = try seam.lift(&core, 64);
    try std.testing.expect(!seam.quiet());
}

test "a seam that only ever got stuck is not quiet either" {
    var core = Fake{ .masks = &.{1} };
    var seam = unmask.Release{};
    _ = try seam.lift(&core, 2);
    try std.testing.expect(!seam.quiet());
    try std.testing.expectEqual(@as(u64, 0), seam.lifted);
}

test "the cap is small enough that a bring-up mask is not stepped through" {
    // Documented intent rather than an arbitrary number: a mask held longer
    // than a handful of instructions is bring-up, not an idle loop.
    try std.testing.expectEqual(@as(usize, 64), unmask.limits.steps);
}

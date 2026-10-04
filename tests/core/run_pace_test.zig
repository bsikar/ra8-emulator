const std = @import("std");
const ra8 = @import("ra8");
const run_pace = ra8.core.run_pace;
const cadence = ra8.core.cadence;
const mask_pace = ra8.core.mask_pace;
const unmask = ra8.core.unmask;

/// Nothing here is read off the core unless a time base is attached, but
/// the time base's period read is still compiled against it.
const NoCore = struct {
    pub fn readWord(self: *NoCore, address: u32) !u32 {
        _ = self;
        _ = address;
        return 0;
    }
};

test "a session with nothing attached keeps the configured width" {
    var core = NoCore{};
    const pace = run_pace.forStretch(&core, .{ .per_boundary = 50_000 }, .{});
    try std.testing.expectEqual(@as(u32, 50_000), pace.per_boundary);
}

test "a stuck mask narrows the stretch only when mask pacing is on" {
    var core = NoCore{};
    var seam = unmask.Release{ .run = 3 };
    var tracker = mask_pace.Pace{ .on = true };
    const paced = run_pace.forStretch(&core, .{ .per_boundary = 50_000 }, .{ .unmask = &seam, .mask_pace = &tracker });
    try std.testing.expectEqual(mask_pace.limits.while_masked, paced.per_boundary);
    const unpaced = run_pace.forStretch(&core, .{ .per_boundary = 50_000 }, .{ .unmask = &seam });
    try std.testing.expectEqual(@as(u32, 50_000), unpaced.per_boundary);
}

/// A board stand-in whose queue has something due `cycles` from now.
const Queued = struct {
    cycles: u64,

    fn due(context: *anyopaque) u64 {
        const self: *const Queued = @ptrCast(@alignCast(context));
        return self.cycles;
    }

    fn tick(_: *anyopaque, _: ra8.core.cpu.memory.guest.Guest, _: u32) anyerror!void {}

    fn ticker(self: *Queued) ra8.core.tick.Tick {
        return .{ .context = self, .tickFn = tick, .dueFn = due };
    }
};

test "a queued event closer than the stretch ends the stretch on it" {
    var core = NoCore{};
    var queued = Queued{ .cycles = 12_345 };
    const pace = run_pace.forStretch(&core, .{ .per_boundary = 50_000 }, .{ .board = queued.ticker() });
    try std.testing.expectEqual(@as(u32, 12_345), pace.per_boundary);
}

test "a queued event is floored, ignored when further out or absent" {
    var core = NoCore{};
    var queued = Queued{ .cycles = 10 };
    var pace = run_pace.forStretch(&core, .{ .per_boundary = 50_000 }, .{ .board = queued.ticker() });
    try std.testing.expectEqual(cadence.floor, pace.per_boundary);
    queued.cycles = 80_000;
    pace = run_pace.forStretch(&core, .{ .per_boundary = 50_000 }, .{ .board = queued.ticker() });
    try std.testing.expectEqual(@as(u32, 50_000), pace.per_boundary);
    queued.cycles = 0;
    pace = run_pace.forStretch(&core, .{ .per_boundary = 50_000 }, .{ .board = queued.ticker() });
    try std.testing.expectEqual(@as(u32, 50_000), pace.per_boundary);
}

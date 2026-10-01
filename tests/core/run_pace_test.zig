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

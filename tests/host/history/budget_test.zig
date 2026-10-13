const std = @import("std");
const budget = @import("ra8").host.history.budget;
const mib = budget.bytes.mib;
const gib = budget.bytes.gib;

test "host lifecycle RAM defaults clamp physical eighth and enforce override floor" {
    try std.testing.expectEqual(256 * mib, budget.defaultRam(512 * mib));
    try std.testing.expectEqual(512 * mib, budget.defaultRam(4 * gib));
    try std.testing.expectEqual(gib, budget.defaultRam(64 * gib));
    try std.testing.expectError(error.BudgetTooSmall, budget.ram(64 * gib, 127 * mib));
    try std.testing.expectEqual(128 * mib, try budget.ram(64 * gib, 128 * mib));
}

test "host lifecycle exact four RAM tiers and intermediate degradation stay bounded" {
    const tiers = [_][5]u64{ .{ 1024, 64, 256, 640, 64 }, .{ 512, 32, 128, 320, 32 }, .{ 256, 16, 48, 160, 32 }, .{ 128, 16, 0, 80, 32 } };
    for (tiers) |tier| {
        const shares = try budget.partition(tier[0] * mib);
        try std.testing.expectEqual(tier[1] * mib, shares.window);
        try std.testing.expectEqual(tier[2] * mib, shares.frames);
        try std.testing.expectEqual(tier[3] * mib, shares.checkpoints);
        try std.testing.expectEqual(tier[4] * mib, shares.output);
        try std.testing.expectEqual(tier[0] * mib, shares.total());
    }
    for (128..1025) |cap| {
        const shares = try budget.partition(cap * mib);
        try std.testing.expect(shares.total() <= cap * mib);
        try std.testing.expect(shares.window >= 16 * mib);
    }
    const degraded = try budget.partition(900 * mib);
    try std.testing.expectEqual(256 * mib, degraded.frames);
    try std.testing.expectEqual(516 * mib, degraded.checkpoints);
}

test "host lifecycle disk quotas warning free floor and overflow refusal" {
    const disk = budget.disk(200 * gib, 4);
    try std.testing.expectEqual(10 * gib, disk.ephemeral);
    try std.testing.expectEqual(20 * gib, disk.kept);
    try std.testing.expectEqual(5 * gib / 2, disk.session);
    try std.testing.expectEqual(disk.session / 5, disk.frames);
    try std.testing.expectEqual(10 * gib, disk.free_floor);
    try std.testing.expectEqual(gib, budget.disk(5 * gib, 10).session);
    try std.testing.expectEqual(budget.Pressure.normal, budget.pressure(79, 100));
    try std.testing.expectEqual(budget.Pressure.warning, budget.pressure(80, 100));
    try std.testing.expectEqual(budget.Pressure.history_full, budget.pressure(100, 100));
    try std.testing.expectError(error.HistoryFull, budget.checkCommit(90, 10, 100, 1000, 100));
    try std.testing.expectError(error.HistoryFull, budget.checkCommit(0, 11, 100, 110, 100));
    try std.testing.expectError(error.HistoryFull, budget.checkCommit(std.math.maxInt(u64), 1, std.math.maxInt(u64), std.math.maxInt(u64), 0));
    try std.testing.expectEqual(budget.Pressure.warning, try budget.checkCommit(70, 10, 100, 110, 100));
}

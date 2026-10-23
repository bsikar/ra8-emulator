const std = @import("std");
const testing = std.testing;
const ra8 = @import("ra8");
const budget = ra8.session.history_window_budget;

test "window budget: tier selection across standard budgets" {
    // 1 GiB budget -> 64 MiB window
    const tier_1g = budget.tierFor(1024 * 1024 * 1024);
    try testing.expectEqual(@as(usize, 64 * 1024 * 1024), tier_1g.window_bytes);
    try testing.expectEqual(@as(usize, 256 * 1024 * 1024), tier_1g.hot_frames_bytes);
    try testing.expectEqual(@as(usize, 640 * 1024 * 1024), tier_1g.hot_checkpoints_bytes);
    try testing.expectEqual(@as(usize, 64 * 1024 * 1024), tier_1g.output_bytes);
    try testing.expectEqual(@as(usize, 64 * 1024 * 1024), budget.windowCapacity(1024 * 1024 * 1024));

    // 512 MiB budget -> 32 MiB window
    const tier_512m = budget.tierFor(512 * 1024 * 1024);
    try testing.expectEqual(@as(usize, 32 * 1024 * 1024), tier_512m.window_bytes);
    try testing.expectEqual(@as(usize, 128 * 1024 * 1024), tier_512m.hot_frames_bytes);
    try testing.expectEqual(@as(usize, 320 * 1024 * 1024), tier_512m.hot_checkpoints_bytes);
    try testing.expectEqual(@as(usize, 32 * 1024 * 1024), tier_512m.output_bytes);
    try testing.expectEqual(@as(usize, 32 * 1024 * 1024), budget.windowCapacity(512 * 1024 * 1024));

    // 256 MiB budget -> 16 MiB window
    const tier_256m = budget.tierFor(256 * 1024 * 1024);
    try testing.expectEqual(@as(usize, 16 * 1024 * 1024), tier_256m.window_bytes);
    try testing.expectEqual(@as(usize, 48 * 1024 * 1024), tier_256m.hot_frames_bytes);
    try testing.expectEqual(@as(usize, 160 * 1024 * 1024), tier_256m.hot_checkpoints_bytes);
    try testing.expectEqual(@as(usize, 32 * 1024 * 1024), tier_256m.output_bytes);
    try testing.expectEqual(@as(usize, 16 * 1024 * 1024), budget.windowCapacity(256 * 1024 * 1024));

    // 128 MiB budget (floor) -> 16 MiB window
    const tier_128m = budget.tierFor(128 * 1024 * 1024);
    try testing.expectEqual(@as(usize, 16 * 1024 * 1024), tier_128m.window_bytes);
    try testing.expectEqual(@as(usize, 0), tier_128m.hot_frames_bytes);
    try testing.expectEqual(@as(usize, 80 * 1024 * 1024), tier_128m.hot_checkpoints_bytes);
    try testing.expectEqual(@as(usize, 32 * 1024 * 1024), tier_128m.output_bytes);
    try testing.expectEqual(@as(usize, 16 * 1024 * 1024), budget.windowCapacity(128 * 1024 * 1024));
}

test "window budget: hard floor clamps sub-128 MiB requests" {
    try testing.expectEqual(@as(usize, 128 * 1024 * 1024), budget.clampRamBudget(0));
    try testing.expectEqual(@as(usize, 128 * 1024 * 1024), budget.clampRamBudget(64 * 1024 * 1024));
    try testing.expectEqual(@as(usize, 128 * 1024 * 1024), budget.clampRamBudget(100 * 1024 * 1024));

    const tier_sub = budget.tierFor(50 * 1024 * 1024);
    try testing.expectEqual(@as(usize, 128 * 1024 * 1024), tier_sub.ram_budget);
    try testing.expectEqual(@as(usize, 16 * 1024 * 1024), tier_sub.window_bytes);
    try testing.expectEqual(@as(usize, 16 * 1024 * 1024), budget.windowCapacity(50 * 1024 * 1024));
}

test "window budget: default from physical RAM clamping" {
    // 16 GiB physical RAM -> clamp to 1 GiB
    try testing.expectEqual(@as(usize, 1024 * 1024 * 1024), budget.defaultRamBudget(16 * 1024 * 1024 * 1024));
    // 8 GiB physical RAM -> 1 GiB
    try testing.expectEqual(@as(usize, 1024 * 1024 * 1024), budget.defaultRamBudget(8 * 1024 * 1024 * 1024));
    // 4 GiB physical RAM -> 512 MiB
    try testing.expectEqual(@as(usize, 512 * 1024 * 1024), budget.defaultRamBudget(4 * 1024 * 1024 * 1024));
    // 2 GiB physical RAM -> 256 MiB
    try testing.expectEqual(@as(usize, 256 * 1024 * 1024), budget.defaultRamBudget(2 * 1024 * 1024 * 1024));
    // 1 GiB physical RAM -> 128 MiB, clamped up to 256 MiB default minimum
    try testing.expectEqual(@as(usize, 256 * 1024 * 1024), budget.defaultRamBudget(1024 * 1024 * 1024));
    // 512 MiB physical RAM -> 64 MiB, clamped up to 256 MiB default minimum
    try testing.expectEqual(@as(usize, 256 * 1024 * 1024), budget.defaultRamBudget(512 * 1024 * 1024));
}

//! Covers src/session/history/budget.zig: the pressure bands and the
//! refusal a commit or checkpoint hits when the volume or the share
//! cannot take the bytes.
const std = @import("std");
const ra8 = @import("ra8");
const budget = ra8.session.history_budget;

test "pressure stays normal below 80 percent, warns at 80 and stops at the cap" {
    try std.testing.expectEqual(budget.Pressure.normal, budget.pressure(0, 100));
    try std.testing.expectEqual(budget.Pressure.normal, budget.pressure(79, 100));
    try std.testing.expectEqual(budget.Pressure.warning, budget.pressure(80, 100));
    try std.testing.expectEqual(budget.Pressure.history_full, budget.pressure(100, 100));
    try std.testing.expectEqual(budget.Pressure.history_full, budget.pressure(150, 100));
}

test "checkCommit refuses what the volume or the share cannot take" {
    // The volume does not hold the bytes.
    try std.testing.expectError(error.HistoryFull, budget.checkCommit(0, 10, 100, 5, 0));
    // The volume would fall below its floor after the bytes.
    try std.testing.expectError(error.HistoryFull, budget.checkCommit(0, 10, 1_000, 55, 50));
    // The bytes alone cross the share.
    try std.testing.expectError(error.HistoryFull, budget.checkCommit(0, 200, 100, 1_000, 0));
    // The share is already spent.
    try std.testing.expectError(error.HistoryFull, budget.checkCommit(95, 10, 100, 1_000, 0));
    // What fits answers with the pressure it leaves behind.
    try std.testing.expectEqual(budget.Pressure.normal, try budget.checkCommit(0, 10, 100, 1_000, 0));
    try std.testing.expectEqual(budget.Pressure.warning, try budget.checkCommit(80, 5, 100, 1_000, 0));
}

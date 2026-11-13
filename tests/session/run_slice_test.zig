//! Session continuations preserve the stop machine across instruction budgets.
const std = @import("std");
const fixture = @import("../interfaces/dap/fixture.zig");

test "continuation does not grant a breakpoint another resume grace" {
    var f: fixture.Fixture = .{};
    try f.init();
    defer f.deinit();
    try std.testing.expectError(error.NotRunning, f.session.continueRun(.cpu0));
    _ = try f.session.setBreakpoint(.cpu0, .{ .address = 10 });
    try f.session.setRunBudget(.cpu0, 1);
    const first = try f.session.run(.cpu0, .cont);
    try std.testing.expect(first == .count);
    const second = try f.session.continueRun(.cpu0);
    try std.testing.expect(second == .stop and second.stop == .breakpoint);
    try std.testing.expectEqual(@as(u32, 10), f.cpu.regs.pc);
    try std.testing.expectError(error.NotRunning, f.session.continueRun(.cpu0));
}

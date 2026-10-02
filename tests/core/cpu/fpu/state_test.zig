//! Covers src/core/cpu/fpu/state.zig.
const std = @import("std");
const ra8 = @import("ra8");
const State = ra8.core.fpu.state.State;

test "a fresh state has a zero bank and the reset FPSCR" {
    const s: State = .{};
    for (s.bank.s) |word| try std.testing.expectEqual(@as(u32, 0), word);
    const reset: ra8.core.fpu.fpscr.Fpscr = .{};
    try std.testing.expectEqual(@as(u32, @bitCast(reset)), @as(u32, @bitCast(s.fpscr)));
}

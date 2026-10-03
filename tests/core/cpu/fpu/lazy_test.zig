//! Covers src/core/cpu/fpu/lazy.zig: PreserveFPState() writing the FP
//! context into the space FPCAR names, per the Arm ARM (DDI0553) extended
//! frame (S0 at FPCAR, FPSCR at +0x40, VPR at +0x44).
const std = @import("std");
const ra8 = @import("ra8");
const lazy = ra8.core.fpu.lazy;
const State = ra8.core.fpu.state.State;
const fixture = @import("../exception/ram.zig");

fn sample() State {
    var s: State = .{};
    for (0..16) |i| s.bank.writeS(@intCast(i), 0x3F80_0000 + @as(u32, @intCast(i)));
    s.bank.writeS(16, 0xDEAD_BEEF);
    s.fpscr = @bitCast(@as(u32, 0x8004_0001));
    s.vpr = @bitCast(@as(u32, 0x0021_00FF));
    return s;
}

test "nothing is pending out of reset" {
    const s: State = .{};
    try std.testing.expect(!lazy.pending(&s));
}

test "preserve writes S0-S15, FPSCR and VPR at FPCAR and clears LSPACT" {
    var ram: fixture.Ram = .{};
    var s = sample();
    const at = fixture.msp_top - 0x48;
    s.context.writeFpcar(at);
    s.context.fpccr.lspact = 1;
    try std.testing.expect(lazy.pending(&s));
    try lazy.preserve(ram.view(), &s);
    try std.testing.expect(!lazy.pending(&s));
    try std.testing.expectEqual(@as(u32, 0x3F80_0000), ram.word(at));
    try std.testing.expectEqual(@as(u32, 0x3F80_000F), ram.word(at + 0x3C));
    try std.testing.expectEqual(@as(u32, 0x8004_0001), ram.word(at + 0x40));
    try std.testing.expectEqual(@as(u32, 0x0021_00FF), ram.word(at + 0x44));
}

test "S16 and up stay out of the non-Secure frame" {
    var ram: fixture.Ram = .{};
    var s = sample();
    const at = fixture.msp_top - 0x48;
    s.context.writeFpcar(at - 8);
    ram.putWord(at - 8 + 0x48, 0x1234_5678);
    s.context.fpccr.lspact = 1;
    try lazy.preserve(ram.view(), &s);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), ram.word(at - 8 + 0x48));
}

test "an unmapped FPCAR is a bus error and LSPACT stays set" {
    var ram: fixture.Ram = .{};
    var s = sample();
    s.context.writeFpcar(0x1000_0000);
    s.context.fpccr.lspact = 1;
    try std.testing.expectError(error.Unmapped, lazy.preserve(ram.view(), &s));
    try std.testing.expect(lazy.pending(&s));
}

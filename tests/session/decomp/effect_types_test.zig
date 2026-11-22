//! Covers src/session/decomp/effect_types.zig.
const std = @import("std");
const ra8 = @import("ra8");

const decomp = ra8.session.decomp;
const Instr = ra8.chip.core.cpu.instr.Instr;

test "effect_types.fallbackFromDisasm scans GPR uses/defs conservatively from printer text" {
    // usad8 r0, r1, r2 -> 0xFB71 0xF002
    const usad: Instr = .{ .address = 0x100, .hw1 = 0xFB71, .hw2 = 0xF002, .size = 4 };
    const eff = decomp.effect_types.fallbackFromDisasm(usad);
    try std.testing.expectEqual(@as(u16, decomp.effects_wide.regBit(0)), eff.defs_mask);
    try std.testing.expectEqual(@as(?u4, 0), eff.primary_rd);
    try std.testing.expectEqual(
        @as(u16, decomp.effects_wide.regBit(1) | decomp.effects_wide.regBit(2)),
        eff.uses_mask,
    );

    // hint nop (0xBF00) touches no GPRs
    const nop_eff = decomp.effect_types.fallbackFromDisasm(.{ .address = 0x104, .hw1 = 0xBF00, .size = 2 });
    try std.testing.expectEqual(@as(u16, 0), nop_eff.defs_mask);
    try std.testing.expectEqual(@as(u16, 0), nop_eff.uses_mask);
}

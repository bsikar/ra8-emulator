//! Covers src/session/decomp/aapcs.zig.
const std = @import("std");
const ra8 = @import("ra8");

const decomp = ra8.session.decomp;

test "aapcs clobbers caller-saved registers and infers return conventions" {
    var regs: [16]decomp.value.Value = undefined;
    for (0..16) |i| {
        regs[i] = .{ .constant = @intCast(i + 10) };
    }
    var flags: decomp.value.FlagState = .{ .known = .{
        .setter_insn = 1,
        .setter_addr = 0x100,
        .kind = .cmp,
    } };

    decomp.aapcs.clobberCall(&regs, &flags, 0x200);
    try std.testing.expectEqual(decomp.value.Value{ .call_result = 0x200 }, regs[0]);
    try std.testing.expectEqual(decomp.value.Value.unknown, regs[1]);
    try std.testing.expectEqual(decomp.value.Value.unknown, regs[3]);
    try std.testing.expectEqual(decomp.value.Value.unknown, regs[12]);
    try std.testing.expectEqual(decomp.value.Value.unknown, regs[14]);
    // Callee-saved r4 remains intact across call
    try std.testing.expectEqual(decomp.value.Value{ .constant = 14 }, regs[4]);
    try std.testing.expectEqual(decomp.value.FlagState.unknown, flags);

    const pair: decomp.value.RegPair = .{ .lo_reg = 0, .hi_reg = 1, .def_address = 0x50, .kind = .long_mul };
    try std.testing.expectEqual(decomp.aapcs.ReturnKind.none, decomp.aapcs.inferReturnKind(false, .unknown, .unknown));
    try std.testing.expectEqual(decomp.aapcs.ReturnKind.r0, decomp.aapcs.inferReturnKind(true, regs[0], .unknown));
    try std.testing.expectEqual(
        decomp.aapcs.ReturnKind.r0_r1_pair,
        decomp.aapcs.inferReturnKind(true, .{ .pair_lo = pair }, .{ .pair_hi = pair }),
    );
}

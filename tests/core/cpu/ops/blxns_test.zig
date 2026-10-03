//! Covers src/core/cpu/ops/blxns.zig.
const std = @import("std");
const ra8 = @import("ra8");
const blxns = ra8.core.cpu.ops.blxns;
const fixture = @import("../exception/ram.zig");

fn claims(hw1: u16) bool {
    return blxns.group.decode(.{ .address = 0, .hw1 = hw1, .size = 2 }) != null;
}

test "BLXNS claims every low and high Rm but SP and PC, and leaves BXNS and BLX" {
    try std.testing.expect(claims(0x4784)); // blxns r0
    try std.testing.expect(claims(0x47E4)); // blxns r12
    try std.testing.expect(claims(0x47F4)); // blxns lr
    try std.testing.expect(!claims(0x47EC)); // blxns sp
    try std.testing.expect(!claims(0x47FC)); // blxns pc
    try std.testing.expect(!claims(0x4704)); // bxns r0
    try std.testing.expect(!claims(0x4780)); // blx r0
    try std.testing.expect(blxns.group.decode(.{ .address = 0, .hw1 = 0x4784, .hw2 = 0, .size = 4 }) == null);
}

test "BLXNS r0 branches to the target, stays Secure and leaves the return in LR" {
    var ram: fixture.Ram = .{};
    var cpu = try fixture.boot(&ram);
    const sp = cpu.regs.sp();
    cpu.regs.low[0] = fixture.handler; // bit 0 clear, as the firmware passes it
    const at = fixture.code;
    const instr: ra8.core.cpu.instr.Instr = .{ .address = at, .hw1 = 0x4784, .size = 2 };
    try blxns.group.decode(instr).?(&cpu, instr);
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expectEqual(at + 2 | 1, cpu.regs.lr);
    try std.testing.expectEqual(sp, cpu.regs.sp()); // VTOR_NS unreadable here
    try std.testing.expectEqual(ra8.core.banked.State.secure, cpu.banked.current);
}

test "no Non-secure stack when VTOR_NS cannot be read" {
    var ram: fixture.Ram = .{};
    const cpu = try fixture.boot(&ram);
    try std.testing.expectEqual(@as(?u32, null), blxns.nonSecureStack(&cpu));
}

test "BLXNS is not checked against Unicorn" {
    try std.testing.expect(!blxns.group.oracle);
}

// Ported from tests/core/tz_test.zig (the Unicorn seam's decode), run
// against the core's group (RA8EMU-252). The seam decodes SP and PC too;
// the core leaves those UNPREDICTABLE forms unclaimed.

test "seam port: blxns r2, the one the RA8D2 secure boot issues, is claimed" {
    try std.testing.expect(claims(0x4794));
}

test "seam port: every Rm but SP and PC is claimed" {
    var rm: u16 = 0;
    while (rm < 15) : (rm += 1) {
        const hw1: u16 = 0x4780 | (rm << 3) | 0x04;
        try std.testing.expectEqual(rm != 13, claims(hw1));
    }
}

test "seam port: a plain BLX and unrelated halfwords are not BLXNS" {
    for ([_]u16{ 0x4790, 0xB580, 0x0000, 0xE002 }) |hw1| try std.testing.expect(!claims(hw1));
}

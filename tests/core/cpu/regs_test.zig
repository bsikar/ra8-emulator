//! Covers src/core/cpu/regs.zig.
const std = @import("std");
const ra8 = @import("ra8");
const regs = ra8.core.cpu.regs;

test "R13 is MSP in Thread mode until CONTROL.SPSEL picks PSP" {
    var r: regs.Regs = .{ .msp = 0x2000_1000, .psp = 0x2000_0800 };
    try std.testing.expectEqual(@as(u32, 0x2000_1000), r.get(13));
    r.control = regs.control_bits.spsel;
    try std.testing.expectEqual(@as(u32, 0x2000_0800), r.get(13));
    r.set(13, 0x2000_0700);
    try std.testing.expectEqual(@as(u32, 0x2000_0700), r.psp);
    try std.testing.expectEqual(@as(u32, 0x2000_1000), r.msp);
}

test "Handler mode runs on MSP whatever SPSEL says" {
    var r: regs.Regs = .{ .msp = 0x2000_1000, .psp = 0x2000_0800 };
    r.control = regs.control_bits.spsel;
    r.xpsr = 11; // SVCall
    try std.testing.expect(r.handlerMode());
    try std.testing.expectEqual(@as(u32, 0x2000_1000), r.sp());
}

test "SP ignores its two low bits on both banks" {
    var r: regs.Regs = .{};
    r.set(13, 0x2000_0FFF);
    try std.testing.expectEqual(@as(u32, 0x2000_0FFC), r.msp);
    r.write(.psp, 0x2000_0803);
    try std.testing.expectEqual(@as(u32, 0x2000_0800), r.psp);
}

test "names and numbers reach the same register" {
    var r: regs.Regs = .{};
    for (0..13) |n| r.set(@intCast(n), @as(u32, @intCast(n)) * 3);
    try std.testing.expectEqual(@as(u32, 36), r.read(.r12));
    r.write(.lr, 0x0800_0101);
    try std.testing.expectEqual(@as(u32, 0x0800_0101), r.get(14));
    r.write(.pc, 0x0800_0200);
    try std.testing.expectEqual(@as(u32, 0x0800_0200), r.read(.pc));
}

test "mask registers keep only their implemented bits" {
    var r: regs.Regs = .{};
    r.write(.primask, 0xFFFF_FFFF);
    r.write(.faultmask, 0xFFFF_FFFE);
    r.write(.basepri, 0x1A0);
    try std.testing.expectEqual(@as(u32, 1), r.read(.primask));
    try std.testing.expectEqual(@as(u32, 0), r.read(.faultmask));
    try std.testing.expectEqual(@as(u32, 0xA0), r.read(.basepri));
}

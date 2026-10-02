//! Covers src/core/cpu/ops/long_shift.zig.
const std = @import("std");
const ra8 = @import("ra8");
const Cpu = ra8.core.cpu.cpu.Cpu;
const long_shift = ra8.core.cpu.ops.long_shift;

fn wide(hw1: u16, hw2: u16) ra8.core.cpu.instr.Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

/// Runs the op with r2:r3 = lo:hi and a known xPSR; returns hi:lo.
fn run(hw1: u16, hw2: u16, lo: u32, hi: u32) !u64 {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.low[2] = lo;
    cpu.regs.low[3] = hi;
    cpu.regs.xpsr = 0xF100_0000;
    const exec = long_shift.group.decode(wide(hw1, hw2)) orelse return error.NotClaimed;
    try exec(&cpu, wide(hw1, hw2));
    try std.testing.expectEqual(@as(u32, 0xF100_0000), cpu.regs.xpsr);
    return (@as(u64, cpu.regs.low[3]) << 32) | cpu.regs.low[2];
}

test "lsll r2, r3, #5 from power_profiler (x * 32)" {
    const f = long_shift.fields(wide(0xEA52, 0x134F)).?;
    try std.testing.expectEqual(@as(u4, 2), f.lo);
    try std.testing.expectEqual(@as(u4, 3), f.hi);
    try std.testing.expectEqual(@as(u6, 5), f.amount);
    try std.testing.expectEqual(long_shift.Kind.lsll, f.kind);
    try std.testing.expectEqual(@as(u64, 0x0000_001F_E000_0000), try run(0xEA52, 0x134F, 0xFF00_0000, 0));
}

test "lsrl and asrl r2, r3, #4" {
    // imm3 = 001, imm2 = 00: shift 4; type 01 lsrl, 10 asrl
    try std.testing.expectEqual(@as(u64, 0x0800_0000_0000_0000), try run(0xEA52, 0x131F, 0, 0x8000_0000));
    try std.testing.expectEqual(@as(u64, 0xF800_0000_0000_0000), try run(0xEA52, 0x132F, 0, 0x8000_0000));
}

test "the shift crosses the register boundary" {
    // lsll #31 and lsrl #31
    try std.testing.expectEqual(@as(u64, 0x8000_0000) << 31, try run(0xEA52, 0x73CF, 0x8000_0000, 0));
    try std.testing.expectEqual(@as(u64, 2), try run(0xEA52, 0x73DF, 0, 1));
}

test "the forms this slice leaves alone" {
    const left = [_][2]u16{
        .{ 0xEA52, 0x030F }, // shift of zero
        .{ 0xEA52, 0x1F4F }, // RdaHi 1111: single-register saturating shift
        .{ 0xEA52, 0x137F }, // type 11
        .{ 0xEA53, 0x134F }, // hw1 bit 0 set
        .{ 0xEA52, 0x134E }, // hw2[3:0] not 1111
        .{ 0xEA52, 0x124F }, // hw2 bit 8 clear
        .{ 0xEA42, 0x134F }, // ORR without S
    };
    for (left) |pair| try std.testing.expect(long_shift.group.decode(wide(pair[0], pair[1])) == null);
}

test "the group is not checked against Unicorn" {
    try std.testing.expect(!long_shift.group.oracle);
}

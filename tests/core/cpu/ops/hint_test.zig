//! Covers src/core/cpu/ops/hint.zig.
const std = @import("std");
const ra8 = @import("ra8");
const hint = ra8.core.cpu.ops.hint;

fn narrow(hw1: u16) ?ra8.core.cpu.op.Exec {
    return hint.group.decode(.{ .address = 0, .hw1 = hw1, .size = 2 });
}

fn wide(hw2: u16) ?ra8.core.cpu.op.Exec {
    return hint.group.decode(.{ .address = 0, .hw1 = 0xF3AF, .hw2 = hw2, .size = 4 });
}

test "both NOP widths decode" {
    const e = hint.encodings;
    try std.testing.expect(narrow(e.nop_t1) != null);
    try std.testing.expect(wide(e.nop_t2_hw2) != null);
}

test "yield, wfe, wfi and sev decode in both widths" {
    // bf10 yield, bf20 wfe, bf30 wfi, bf40 sev
    for ([_]u16{ 0xBF10, 0xBF20, 0xBF30, 0xBF40 }) |hw1| try std.testing.expect(narrow(hw1) != null);
    for ([_]u16{ 0x8001, 0x8002, 0x8003, 0x8004 }) |hw2| try std.testing.expect(wide(hw2) != null);
}

test "an IT and the unallocated hints are left alone" {
    // bf08 it eq-shaped, bf50 and bff0 unallocated hint numbers
    for ([_]u16{ 0xBF08, 0xBF50, 0xBFF0, 0xBF18 }) |hw1| try std.testing.expect(narrow(hw1) == null);
    // f3af 8005 unallocated, 80f0 dbg, 8014 csdb-shaped
    for ([_]u16{ 0x8005, 0x80F0, 0x8014 }) |hw2| try std.testing.expect(wide(hw2) == null);
}

test "wfi falls straight through" {
    var cpu: ra8.core.cpu.cpu.Cpu = .{ .bus = undefined };
    cpu.regs.pc = 0x100;
    const exec = narrow(0xBF30).?;
    try exec(&cpu, .{ .address = 0xFE, .hw1 = 0xBF30, .size = 2 });
    try std.testing.expectEqual(@as(u32, 0x100), cpu.regs.pc);
}

//! Covers src/core/cpu/ops/fp_mem.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.core.cpu.bus;
const Cpu = ra8.core.cpu.cpu.Cpu;
const Instr = ra8.core.cpu.instr.Instr;
const fp_mem = ra8.core.cpu.ops.fp_mem;

/// 64 bytes of RAM at 0x2000_0000.
const Ram = struct {
    const base: u32 = 0x2000_0000;
    bytes: [64]u8 = [_]u8{0} ** 64,

    fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn slot(self: *Ram, address: u32, len: usize) bus.Error![]u8 {
        if (address < base or address - base + len > self.bytes.len) return bus.Error.Unmapped;
        return self.bytes[address - base ..][0..len];
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        @memcpy(into, try self.slot(address, into.len));
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        @memcpy(try self.slot(address, from.len), from);
    }

    fn word(self: *Ram, address: u32) u32 {
        return std.mem.readInt(u32, self.bytes[address - base ..][0..4], .little);
    }

    fn put(self: *Ram, address: u32, value: u32) void {
        std.mem.writeInt(u32, self.bytes[address - base ..][0..4], value, .little);
    }
};

fn at(address: u32, hw1: u16, hw2: u16) Instr {
    return .{ .address = address, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn run(cpu: *Cpu, instr: Instr) !void {
    const exec = fp_mem.group.decode(instr) orelse return error.NotClaimed;
    try exec(cpu, instr);
}

fn claimed(hw1: u16, hw2: u16) bool {
    return fp_mem.group.decode(at(0, hw1, hw2)) != null;
}

test "vstr s1, [r0, #4] then vldr s2, [r0, #4]" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(0, Ram.base);
    cpu.fp.bank.writeS(1, 0x3F80_0000);
    try run(&cpu, at(0, 0xEDC0, 0x0A01));
    try std.testing.expectEqual(@as(u32, 0x3F80_0000), ram.word(Ram.base + 4));
    try run(&cpu, at(0, 0xED90, 0x1A01));
    try std.testing.expectEqual(@as(u32, 0x3F80_0000), cpu.fp.bank.readS(2));
}

test "vldr d1, [r1, #-8] reads low word first" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    ram.put(Ram.base + 8, 0x5566_7788);
    ram.put(Ram.base + 12, 0x1122_3344);
    cpu.regs.set(1, Ram.base + 16);
    try run(&cpu, at(0, 0xED11, 0x1B02));
    try std.testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), cpu.fp.bank.readD(1));
}

test "vldr s0, [pc, #8] aligns the PC" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    ram.put(Ram.base + 12, 0xCAFE_F00D);
    try run(&cpu, at(Ram.base + 2, 0xED9F, 0x0A02));
    try std.testing.expectEqual(@as(u32, 0xCAFE_F00D), cpu.fp.bank.readS(0));
}

test "vpush {d0-d1} then vpop {d0-d1} round-trips and moves SP" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(13, Ram.base + 32);
    cpu.fp.bank.writeD(0, 0x0102_0304_0506_0708);
    cpu.fp.bank.writeD(1, 0x1112_1314_1516_1718);
    try run(&cpu, at(0, 0xED2D, 0x0B04));
    try std.testing.expectEqual(Ram.base + 16, cpu.regs.get(13));
    try std.testing.expectEqual(@as(u32, 0x0506_0708), ram.word(Ram.base + 16));
    try std.testing.expectEqual(@as(u32, 0x1112_1314), ram.word(Ram.base + 28));
    cpu.fp.bank.writeD(0, 0);
    cpu.fp.bank.writeD(1, 0);
    try run(&cpu, at(0, 0xECBD, 0x0B04));
    try std.testing.expectEqual(Ram.base + 32, cpu.regs.get(13));
    try std.testing.expectEqual(@as(u64, 0x1112_1314_1516_1718), cpu.fp.bank.readD(1));
}

test "vstmia r2, {s3-s5} without writeback" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(2, Ram.base);
    for (3..6) |n| cpu.fp.bank.writeS(@intCast(n), @intCast(n * 0x10));
    try run(&cpu, at(0, 0xECC2, 0x1A03));
    try std.testing.expectEqual(Ram.base, cpu.regs.get(2));
    try std.testing.expectEqual(@as(u32, 0x50), ram.word(Ram.base + 8));
}

test "a faulting access leaves Rn alone" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(13, Ram.base + 4);
    try std.testing.expectError(bus.Error.Unmapped, run(&cpu, at(0, 0xED2D, 0x0B04)));
    try std.testing.expectEqual(Ram.base + 4, cpu.regs.get(13));
}

test "unclaimed: 64-bit transfers, VLLDM, VSCCLRM, VSTR to PC, D16+, 16-bit VLDM and PC VSTR.16, empty lists" {
    try std.testing.expect(!claimed(0xEC47, 0x6B13));
    try std.testing.expect(!claimed(0xEC30, 0x0A00));
    try std.testing.expect(!claimed(0xEC9F, 0x0A04));
    try std.testing.expect(!claimed(0xED8F, 0x0A01));
    try std.testing.expect(!claimed(0xEDD0, 0x0B00));
    try std.testing.expect(!claimed(0xEC90, 0x0901));
    try std.testing.expect(!claimed(0xED8F, 0x0901));
    try std.testing.expect(!claimed(0xEDB0, 0x0901));
    try std.testing.expect(!claimed(0xECBD, 0x0B00));
    try std.testing.expect(!claimed(0xEDBD, 0x0B04));
    try std.testing.expect(claimed(0xED2D, 0x8A08));
}

test "vstr.16 s1, [r0, #6] then vldr.16 s2, [r0, #6] zero the top half" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    cpu.regs.set(0, Ram.base);
    ram.put(Ram.base + 8, 0x5555_5555);
    cpu.fp.bank.writeS(1, 0xFFFF_3C00);
    try run(&cpu, at(0, 0xEDC0, 0x0903));
    try std.testing.expectEqual(@as(u32, 0x3C00_0000), ram.word(Ram.base + 4));
    try std.testing.expectEqual(@as(u32, 0x5555_5555), ram.word(Ram.base + 8));
    cpu.fp.bank.writeS(2, 0xFFFF_FFFF);
    try run(&cpu, at(0, 0xED90, 0x1903));
    try std.testing.expectEqual(@as(u32, 0x3C00), cpu.fp.bank.readS(2));
}

test "vldr.16 s0, [r1, #-2] and vldr.16 s0, [pc, #4]" {
    var ram: Ram = .{};
    var cpu: Cpu = .{ .bus = ram.view() };
    ram.put(Ram.base + 4, 0xBEEF_0000);
    ram.put(Ram.base + 8, 0xAAAA_1234);
    cpu.regs.set(1, Ram.base + 8);
    try run(&cpu, at(0, 0xED11, 0x0901));
    try std.testing.expectEqual(@as(u32, 0xBEEF), cpu.fp.bank.readS(0));
    try run(&cpu, at(Ram.base + 2, 0xED9F, 0x0902));
    try std.testing.expectEqual(@as(u32, 0x1234), cpu.fp.bank.readS(0));
}

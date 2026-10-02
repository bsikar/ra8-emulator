//! Covers src/core/cpu/ops/it.zig and the IT handling in Cpu.step.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.core.cpu.bus;
const Cpu = ra8.core.cpu.cpu.Cpu;
const Instr = ra8.core.cpu.instr.Instr;
const it = ra8.core.cpu.ops.it;
const it_state = ra8.core.cpu.it_state;
const flags = ra8.core.cpu.flags;

/// Code at address 0, read-only.
const Code = struct {
    bytes: []const u8,

    fn view(self: *Code) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Code = @ptrCast(@alignCast(ctx));
        if (address + into.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        _ = .{ ctx, address, from };
        return bus.Error.Unmapped;
    }
};

fn at(hw1: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .size = 2 };
}

test "decode claims IT and leaves the hints and firstcond 1111 alone" {
    try std.testing.expect(it.group.decode(at(0xBF18)) != null); // it ne
    try std.testing.expect(it.group.decode(at(0xBF05)) != null); // ittet eq
    for ([_]u16{ 0xBF00, 0xBF10, 0xBF20, 0xBFF8, 0xBA00 }) |hw1| {
        try std.testing.expect(it.group.decode(at(hw1)) == null);
    }
}

test "ITE NE runs the then-instruction and skips the else when Z is clear" {
    // ite ne ; movne r0, #1 ; moveq r0, #2 ; movs r1, #3
    var code: Code = .{ .bytes = &.{ 0x14, 0xBF, 0x01, 0x20, 0x02, 0x20, 0x03, 0x21 } };
    var cpu: Cpu = .{ .bus = code.view() };
    cpu.regs.xpsr = ra8.core.cpu.regs.xpsr_bits.thumb;
    try std.testing.expect(cpu.run(1) == .count);
    try std.testing.expectEqual(@as(u8, 0x14), it_state.get(cpu.regs.xpsr));
    try std.testing.expect(cpu.run(2) == .count);
    try std.testing.expectEqual(@as(u32, 1), cpu.regs.low[0]);
    // Inside the block MOVS sets no flags; Z stays clear from reset.
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.xpsr & flags.bits.z);
    try std.testing.expect(!it_state.active(it_state.get(cpu.regs.xpsr)));
    try std.testing.expect(cpu.run(1) == .count);
    try std.testing.expectEqual(@as(u32, 3), cpu.regs.low[1]);
    try std.testing.expectEqual(@as(u32, 8), cpu.regs.pc);
    try std.testing.expectEqual(@as(u64, 4), cpu.retired);
}

test "ITE NE skips the then-instruction and runs the else when Z is set" {
    var code: Code = .{ .bytes = &.{ 0x14, 0xBF, 0x01, 0x20, 0x02, 0x20 } };
    var cpu: Cpu = .{ .bus = code.view() };
    cpu.regs.xpsr = ra8.core.cpu.regs.xpsr_bits.thumb | flags.bits.z;
    try std.testing.expect(cpu.run(3) == .count);
    try std.testing.expectEqual(@as(u32, 2), cpu.regs.low[0]);
    try std.testing.expectEqual(flags.bits.z, cpu.regs.xpsr & flags.bits.z);
    try std.testing.expectEqual(@as(u8, 0), it_state.get(cpu.regs.xpsr));
}

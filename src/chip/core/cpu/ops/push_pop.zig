//! PUSH and POP, 16-bit (T1): a register list on the current stack.
//!
//! Registers go lowest-numbered at the lowest address. An empty list is
//! UNPREDICTABLE, so the group leaves it unclaimed. POP into the PC
//! interworks: bit 0 sets EPSR.T. An EXC_RETURN value popped in Handler mode
//! is an exception return, which the core performs once the POP retires
//! (src/chip/core/cpu/exception/ret.zig). The stack-limit check runs at the core's
//! instruction boundary; PUSH checks before it writes any words.
const std = @import("std");
const op = @import("../op.zig");
const alignment = @import("../alignment.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

pub const encodings = struct {
    /// Bits [15:9] of the first halfword.
    pub const mask: u16 = 0xFE00;
    pub const push_t1: u16 = 0xB400;
    pub const pop_t1: u16 = 0xBC00;
    /// Bit 8: LR for PUSH, PC for POP.
    pub const extra: u16 = 1 << 8;
};

pub const group: op.Group = .{ .name = "push_pop", .decode = decode };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 2 or instr.hw1 & 0xFF == 0 and instr.hw1 & encodings.extra == 0) return null;
    return switch (instr.hw1 & encodings.mask) {
        encodings.push_t1 => push,
        encodings.pop_t1 => pop,
        else => null,
    };
}

/// The register list as a bitmap over r0..r15.
pub fn list(hw1: u16) u16 {
    const extra_reg: u4 = if (hw1 & encodings.mask == encodings.push_t1) 14 else 15;
    const low = hw1 & 0xFF;
    return if (hw1 & encodings.extra != 0) low | (@as(u16, 1) << extra_reg) else low;
}

fn push(cpu: *Cpu, instr: Instr) op.Error!void {
    const registers = list(instr.hw1);
    const start = cpu.regs.sp() -% 4 * @as(u32, @popCount(registers));
    var address = start;
    try alignment.memA(start, 4);
    if (start < cpu.regs.spLimit()) return error.StackOverflow;
    for (0..16) |i| {
        if (registers & (@as(u16, 1) << @intCast(i)) == 0) continue;
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, cpu.regs.get(@intCast(i)), .little);
        try cpu.bus.write(address, &bytes);
        address +%= 4;
    }
    cpu.regs.setSp(start);
}

fn pop(cpu: *Cpu, instr: Instr) op.Error!void {
    const registers = list(instr.hw1);
    var values: [16]u32 = undefined;
    var address = cpu.regs.sp();
    try alignment.memA(address, 4);
    for (0..16) |i| {
        if (registers & (@as(u16, 1) << @intCast(i)) == 0) continue;
        values[i] = try cpu.bus.readWord(address);
        address +%= 4;
    }
    cpu.regs.setSp(address);
    for (0..15) |i| {
        if (registers & (@as(u16, 1) << @intCast(i)) != 0) cpu.regs.set(@intCast(i), values[i]);
    }
    if (registers & (1 << 15) != 0) cpu.regs.bxWritePc(values[15]);
}

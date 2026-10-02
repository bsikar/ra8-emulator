//! MOVW (MOV T3) and MOVT (T1): a 16-bit immediate into the low half of Rd,
//! or into the high half keeping the low one. imm16 is imm4:i:imm3:imm8.
//! Neither touches the flags. Rd of SP or PC is UNPREDICTABLE and left
//! unclaimed, so the core stops rather than guess.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

pub const encodings = struct {
    /// hw1 with i ([10]) and imm4 ([3:0]) masked out.
    pub const mask: u16 = 0xFBF0;
    pub const movw: u16 = 0xF240;
    pub const movt: u16 = 0xF2C0;
    /// hw2[15] is zero in both.
    pub const hw2_zero: u16 = 0x8000;
};

pub const group: op.Group = .{ .name = "mov_wide", .decode = decode };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4 or instr.hw2 & encodings.hw2_zero != 0) return null;
    const rd = rdOf(instr);
    if (rd == 13 or rd == 15) return null;
    return switch (instr.hw1 & encodings.mask) {
        encodings.movw => movw,
        encodings.movt => movt,
        else => null,
    };
}

fn rdOf(instr: Instr) u4 {
    return @intCast((instr.hw2 >> 8) & 0xF);
}

pub fn imm16(instr: Instr) u16 {
    const imm4: u16 = instr.hw1 & 0xF;
    const i: u16 = (instr.hw1 >> 10) & 0x1;
    const imm3: u16 = (instr.hw2 >> 12) & 0x7;
    const imm8: u16 = instr.hw2 & 0xFF;
    return (imm4 << 12) | (i << 11) | (imm3 << 8) | imm8;
}

fn movw(cpu: *Cpu, instr: Instr) op.Error!void {
    cpu.regs.set(rdOf(instr), imm16(instr));
}

fn movt(cpu: *Cpu, instr: Instr) op.Error!void {
    const rd = rdOf(instr);
    const low = cpu.regs.get(rd) & 0xFFFF;
    cpu.regs.set(rd, (@as(u32, imm16(instr)) << 16) | low);
}

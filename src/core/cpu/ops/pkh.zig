//! PKHBT and PKHTB (T1), the DSP halfword packs. PKHBT keeps Rn's bottom
//! halfword and takes the top halfword of Rm LSL #imm; PKHTB keeps Rn's top
//! halfword and takes the bottom halfword of Rm ASR #imm, where #0 means #32.
//! No flags change. This is the S = 0, opcode 0110 row that dp_shifted leaves.
//!
//! Left unclaimed: SP or PC in Rd, Rn or Rm (UNPREDICTABLE), and a set hw2[15]
//! or hw2[4].
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;
const shift = @import("../shift.zig");

pub const encodings = struct {
    /// hw1 with Rn ([3:0]) masked out.
    pub const mask: u16 = 0xFFF0;
    pub const pkh: u16 = 0xEAC0;
    /// hw2[15] and hw2[4] must be zero.
    pub const hw2_zero: u16 = 0x8010;
};

pub const group: op.Group = .{ .name = "pkh", .decode = decode };

pub const Fields = struct {
    /// PKHTB when set, PKHBT otherwise.
    tb: bool,
    rn: u4,
    rd: u4,
    rm: u4,
    imm5: u5,

    pub fn of(instr: Instr) ?Fields {
        if (instr.size != 4 or instr.hw1 & encodings.mask != encodings.pkh) return null;
        if (instr.hw2 & encodings.hw2_zero != 0) return null;
        const imm3: u5 = @intCast((instr.hw2 >> 12) & 0x7);
        const imm2: u5 = @intCast((instr.hw2 >> 6) & 0x3);
        return .{
            .tb = instr.hw2 & 0x20 != 0,
            .rn = @intCast(instr.hw1 & 0xF),
            .rd = @intCast((instr.hw2 >> 8) & 0xF),
            .rm = @intCast(instr.hw2 & 0xF),
            .imm5 = (imm3 << 2) | imm2,
        };
    }
};

fn spOrPc(n: u4) bool {
    return n == 13 or n == 15;
}

fn decode(instr: Instr) ?op.Exec {
    const f = Fields.of(instr) orelse return null;
    if (spOrPc(f.rd) or spOrPc(f.rn) or spOrPc(f.rm)) return null;
    return exec;
}

/// What Rd gets from Rn and Rm.
pub fn result(f: Fields, rn: u32, rm: u32) u32 {
    const kind: shift.Kind = if (f.tb) .asr else .lsl;
    const operand = shift.shiftC(rm, kind, shift.immAmount(kind, f.imm5), false).result;
    return if (f.tb)
        (rn & 0xFFFF_0000) | (operand & 0xFFFF)
    else
        (operand & 0xFFFF_0000) | (rn & 0xFFFF);
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = Fields.of(instr).?;
    cpu.regs.set(f.rd, result(f, cpu.regs.get(f.rn), cpu.regs.get(f.rm)));
}

//! The preload hints PLD, PLDW and PLI (RA8EMU-132): the immediate (T1
//! imm12, T2 negative imm8), literal and register forms. They are the
//! 32-bit byte loads with Rt = PC, hw1 = 1111 100 S U 0 W 1 Rn.
//!
//! A preload is a hint with no architectural effect, so the core makes no
//! bus access and raises no fault; the MPU and SAU never see it. The
//! halfword loads with Rt = PC (other than PLDW) are unallocated hints and
//! stay unclaimed, as do the register forms with Rm = SP or PC.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

pub const encodings = struct {
    /// hw1 with S ([8]), U ([7]), W ([5]) and Rn masked out: a byte load.
    pub const mask: u16 = 0xFE50;
    pub const match: u16 = 0xF810;
    pub const pli_bit: u16 = 0x0100;
    pub const imm12_bit: u16 = 0x0080;
    pub const w_bit: u16 = 0x0020;
    /// hw2[11:8] of the T2 form: P = 1, U = 0, W = 0.
    pub const t2_negative: u16 = 0x0C00;
};

pub const group: op.Group = .{ .name = "preload", .decode = decode };

pub const Kind = enum { pld, pldw, pli };

pub fn kind(instr: Instr) ?Kind {
    const e = encodings;
    if (instr.size != 4 or instr.hw2 >> 12 != 15) return null;
    if (instr.hw1 & e.mask != e.match) return null;
    const pli = instr.hw1 & e.pli_bit != 0;
    const w = instr.hw1 & e.w_bit != 0;
    if (pli and w) return null;
    if (instr.hw1 & 0xF == 15) {
        if (w) return null;
    } else if (instr.hw1 & e.imm12_bit == 0 and !lowForm(instr.hw2)) return null;
    return if (pli) .pli else if (w) .pldw else .pld;
}

/// The forms with U clear and Rn not PC: T2 negative imm8, or a register
/// offset with hw2[11:6] zero.
fn lowForm(hw2: u16) bool {
    if (hw2 & 0x0F00 == encodings.t2_negative) return true;
    if (hw2 & 0x0FC0 != 0) return false;
    const rm = hw2 & 0xF;
    return rm != 13 and rm != 15;
}

fn decode(instr: Instr) ?op.Exec {
    return if (kind(instr) == null) null else preload;
}

fn preload(cpu: *Cpu, instr: Instr) op.Error!void {
    _ = cpu;
    _ = instr;
}

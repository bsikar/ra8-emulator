//! Hints: NOP, YIELD, WFE, WFI and SEV, in both widths.
//!
//! The architecture lets every one of them complete at once, and until the
//! Zig core takes exceptions itself (RA8EMU-18) that is what they do here:
//! WFI and WFE fall straight through instead of waiting for an interrupt the
//! core could not take yet, and YIELD and SEV have nobody to tell. A loop
//! around WFI therefore spins on the budget rather than stopping the run on
//! an unknown encoding.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

pub const encodings = struct {
    pub const nop_t1: u16 = 0xBF00;
    pub const nop_t2_hw1: u16 = 0xF3AF;
    pub const nop_t2_hw2: u16 = 0x8000;
    /// hint number 0 NOP, 1 YIELD, 2 WFE, 3 WFI, 4 SEV
    pub const last_hint: u16 = 4;
};

pub const group: op.Group = .{ .name = "hint", .decode = decode };

fn decode(instr: Instr) ?op.Exec {
    const e = encodings;
    if (instr.size == 2) {
        // 1011 1111 hint 0000: the mask field zero is what makes it a hint
        // and not an IT.
        if (instr.hw1 & 0xFF0F != e.nop_t1) return null;
        return if ((instr.hw1 >> 4) & 0xF <= e.last_hint) complete else null;
    }
    if (instr.hw1 != e.nop_t2_hw1) return null;
    if (instr.hw2 & 0xFF00 != e.nop_t2_hw2) return null;
    return if (instr.hw2 & 0xFF <= e.last_hint) complete else null;
}

fn complete(cpu: *Cpu, instr: Instr) op.Error!void {
    _ = cpu;
    _ = instr;
}

//! Hints: NOP in both widths.
//!
//! YIELD, WFE, WFI and SEV join once the Zig core is wired into the run loop,
//! because each of them is a statement about idling that src/core/idle.zig
//! has to hear.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

pub const encodings = struct {
    pub const nop_t1: u16 = 0xBF00;
    pub const nop_t2_hw1: u16 = 0xF3AF;
    pub const nop_t2_hw2: u16 = 0x8000;
};

pub const group: op.Group = .{ .name = "hint", .decode = decode };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size == 2 and instr.hw1 == encodings.nop_t1) return nop;
    if (instr.size == 4 and instr.hw1 == encodings.nop_t2_hw1 and instr.hw2 == encodings.nop_t2_hw2) return nop;
    return null;
}

fn nop(cpu: *Cpu, instr: Instr) op.Error!void {
    _ = cpu;
    _ = instr;
}

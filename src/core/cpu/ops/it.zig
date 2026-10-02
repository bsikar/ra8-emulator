//! IT (T1): opens an IT block by writing firstcond:mask into EPSR.IT. The
//! step loop then runs or skips each of the next instructions under it and
//! advances the state (src/core/cpu/it_state.zig). Mask 0b0000 is a hint and
//! stays with the hint group. firstcond 0b1111 is UNPREDICTABLE and stays
//! unclaimed; an IT inside a block (also UNPREDICTABLE) simply starts anew.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;
const it_state = @import("../it_state.zig");

pub const encodings = struct {
    pub const mask: u16 = 0xFF00;
    pub const it: u16 = 0xBF00;
};

pub const group: op.Group = .{ .name = "it", .decode = decode };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 2 or instr.hw1 & encodings.mask != encodings.it) return null;
    if (instr.hw1 & 0xF == 0) return null; // the hints
    if ((instr.hw1 >> 4) & 0xF == 0xF) return null;
    return run;
}

fn run(cpu: *Cpu, instr: Instr) op.Error!void {
    cpu.regs.xpsr = it_state.put(cpu.regs.xpsr, @truncate(instr.hw1));
}

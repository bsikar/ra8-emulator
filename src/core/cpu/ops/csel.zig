//! Armv8.1-M conditional select (T1): CSEL, CSINC, CSINV and CSNEG, and the
//! CSET, CSETM and CINC aliases a compiler actually emits for them.
//!
//! The encoding and the select itself live in src/core/csel.zig, and this
//! group reuses both. Register 0b1111 in Rn or
//! Rm is the zero register, never the PC. None of the four writes flags.
//!
//! Left unclaimed (decode in csel.zig refuses them): SP in any register
//! field, Rd = 0b1111, and AL or the unconditional condition.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;
const csel = @import("../../csel.zig");

pub const group: op.Group = .{ .name = "csel", .decode = decode };

fn fields(instr: Instr) ?csel.Instruction {
    if (instr.size != 4) return null;
    return csel.decode(instr.hw1, instr.hw2);
}

fn decode(instr: Instr) ?op.Exec {
    _ = fields(instr) orelse return null;
    return exec;
}

/// Reads a source field, giving zero for the zero register.
fn source(cpu: *const Cpu, n: u4) u32 {
    if (n == csel.encoding.zero_register) return 0;
    return cpu.regs.get(n);
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = fields(instr).?;
    const value = csel.select(f, cpu.regs.xpsr, source(cpu, f.then_source), source(cpu, f.else_source));
    cpu.regs.set(f.destination, value);
}

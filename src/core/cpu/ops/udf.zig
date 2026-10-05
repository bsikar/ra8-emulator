//! UDF, the permanently undefined instruction (T1 and T2). It never runs:
//! the core takes it as a UsageFault with CFSR.UNDEFINSTR set, and the
//! stacked return address is the UDF itself.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

pub const group: op.Group = .{ .name = "udf", .decode = decode, .oracle = false };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size == 2 and instr.hw1 & 0xFF00 == 0xDE00) return undefinedInstr;
    if (instr.size == 4 and instr.hw1 & 0xFFF0 == 0xF7F0 and instr.hw2 & 0xF000 == 0xA000) return undefinedInstr;
    return null;
}

fn undefinedInstr(_: *Cpu, _: Instr) op.Error!void {
    return error.Undefined;
}

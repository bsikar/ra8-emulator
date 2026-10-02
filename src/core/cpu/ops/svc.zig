//! SVC (T1), the supervisor call: exception 11, taken once the instruction
//! retires, so the stacked return address is the next instruction and the
//! stacked IT state has already moved past it.
//!
//! Not checked against Unicorn yet: whether Unicorn takes the SVC itself or
//! hands it to an interrupt hook depends on how the run hooks it, so lockstep
//! brings Unicorn to the Zig core's state instead.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

pub const group: op.Group = .{ .name = "svc", .decode = decode, .oracle = false };

pub const exception_number = 11;

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 2 or instr.hw1 & 0xFF00 != 0xDF00) return null;
    return call;
}

fn call(cpu: *Cpu, _: Instr) op.Error!void {
    cpu.raised = exception_number;
}

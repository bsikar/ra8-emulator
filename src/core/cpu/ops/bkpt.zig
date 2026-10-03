//! BKPT (T1), the software breakpoint. It never runs: the core takes the
//! debug event it raises (exception/debug_event.zig), so the PC is left on
//! the BKPT for a debugger, or stacked as the return address for the
//! handler.
//!
//! Not checked against Unicorn: Unicorn hands BKPT to an interrupt hook
//! instead of taking the debug event, so lockstep cannot follow it.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

pub const group: op.Group = .{ .name = "bkpt", .decode = decode, .oracle = false };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 2 or instr.hw1 & 0xFF00 != 0xBE00) return null;
    return breakpoint;
}

fn breakpoint(_: *Cpu, _: Instr) op.Error!void {
    return error.Breakpoint;
}

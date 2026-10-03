//! ExecuteFPCheck() in front of the FP and MVE groups (RA8EMU-170). The
//! decode table wraps each of those groups with `gated`, so an instruction
//! that passes its condition first finishes any pending lazy preservation
//! (FPCCR.LSPACT, RA8EMU-163), then opens a new FP context: with
//! FPCCR.ASPEN set and CONTROL.FPCA clear, FPSCR loads from FPDSCR and FPCA
//! is set.
//!
//! The NOCP check (RA8EMU-145) belongs here too when it lands.
//!
//! The wrapper decodes the instruction a second time when it runs, because
//! a group's decode hands back a bare function with nothing to close over.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;
const lazy = @import("../fpu/lazy.zig");

/// The same group, with ExecuteFPCheck() ahead of every instruction it runs.
pub fn gated(comptime inner: op.Group) op.Group {
    const Wrap = struct {
        fn decode(instr: Instr) ?op.Exec {
            return if (inner.decode(instr) != null) &exec else null;
        }

        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            try check(cpu);
            const run = inner.decode(instr).?;
            return run(cpu, instr);
        }
    };
    return .{ .name = inner.name, .decode = &Wrap.decode, .oracle = inner.oracle };
}

/// The checks an FP or MVE instruction makes before it touches FP state.
pub fn check(cpu: *Cpu) op.Error!void {
    if (lazy.pending(&cpu.fp)) try lazy.preserve(cpu.bus, &cpu.fp);
    cpu.regs.control = cpu.fp.context.touch(cpu.regs.control, &cpu.fp.fpscr);
}

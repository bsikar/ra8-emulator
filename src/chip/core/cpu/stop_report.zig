//! Text diagnostics for a completed core run.
const cpu_mod = @import("cpu.zig");

pub fn report(out: anytype, cpu: cpu_mod.Cpu, stopped: cpu_mod.Stop) !u8 {
    switch (stopped) {
        .count => {
            try out.print("zig core: ran {d} instructions clean, pc 0x{X:0>8}\n", .{ cpu.retired, cpu.regs.pc });
            return 0;
        },
        .unknown => |instr| try out.print(
            "zig core: unknown encoding at {f} after {d} instructions\n",
            .{ instr, cpu.retired },
        ),
        .invalid_state => |at| try out.print(
            "zig core: EPSR.T clear at 0x{X:0>8} after {d} instructions\n",
            .{ at, cpu.retired },
        ),
        .bus_fault => |at| try out.print(
            "zig core: bus fault at 0x{X:0>8} after {d} instructions\n",
            .{ at, cpu.retired },
        ),
        .invalid_return => |at| try out.print(
            "zig core: invalid exception return at 0x{X:0>8} after {d} instructions\n",
            .{ at, cpu.retired },
        ),
        .breakpoint => |at| try out.print(
            "zig core: BKPT halted at 0x{X:0>8} after {d} instructions\n",
            .{ at, cpu.retired },
        ),
        .unaligned => |at| try out.print(
            "zig core: unaligned MemA access at 0x{X:0>8} after {d} instructions\n",
            .{ at, cpu.retired },
        ),
        .stack_overflow => |at| try out.print(
            "zig core: stack limit overrun at 0x{X:0>8} after {d} instructions\n",
            .{ at, cpu.retired },
        ),
    }
    return 1;
}

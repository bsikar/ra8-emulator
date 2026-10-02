//! A run on the Zig core instead of Unicorn, chosen with `--cpu zig`.
//!
//! The image is loaded and the board RAM mapped exactly as for a Unicorn
//! run; the Zig core then resets out of the same vector table and runs until
//! its budget is spent or it meets something it cannot do yet, most often an
//! encoding no group in src/core/cpu/ops/table.zig claims. The report is one
//! line saying which, so a corpus sweep can tell how far each image gets.
const engine = @import("../engine.zig");
const EngineBus = @import("engine_bus.zig").EngineBus;
const BoardBus = @import("board_bus.zig").BoardBus;
const registry = @import("../../periph/registry.zig");
const cpu_mod = @import("cpu.zig");
const elf = @import("../elf.zig");
const Choice = @import("choice.zig").Choice;
const lockstep_mode = @import("lockstep/mode.zig");
const NvicSource = @import("exception/nvic_source.zig").NvicSource;

/// The hand-off from main for any CPU but Unicorn.
/// `periph` is the board's peripheral bus; a `--cpu zig` run reaches the
/// peripherals through it.
pub fn start(out: anytype, choice: Choice, image: elf.Image, core: *const engine.Engine, periph: ?*registry.Bus, vector_base: u32, budget: u64) !u8 {
    return switch (choice) {
        .unicorn => unreachable,
        .zig => if (periph) |board| runOnBoard(out, core, board, vector_base, budget) else run(out, core, vector_base, budget),
        .lockstep => lockstep_mode.run(out, image, core, vector_base, budget),
    };
}

/// Run the image already loaded into `core` on the Zig core, print how it
/// ended, and return the exit status: 0 when the budget was spent, 1 when
/// the core stopped short of it.
pub fn run(out: anytype, core: *const engine.Engine, vector_base: u32, budget: u64) !u8 {
    var memory: EngineBus = .{ .core = core };
    return runOn(out, memory.view(), vector_base, budget);
}

/// As `run`, with the peripheral windows answered by the board's bus.
pub fn runOnBoard(out: anytype, core: *const engine.Engine, periph: *registry.Bus, vector_base: u32, budget: u64) !u8 {
    var board: BoardBus = .{ .memory = .{ .core = core }, .periph = periph };
    return runOn(out, board.view(), vector_base, budget);
}

fn runOn(out: anytype, memory: @import("bus.zig").Bus, vector_base: u32, budget: u64) !u8 {
    var cpu: cpu_mod.Cpu = .{ .bus = memory };
    var pending: NvicSource = .{};
    cpu.source = pending.source();
    cpu.reset(vector_base) catch {
        try out.print("zig core: no vector table at 0x{X:0>8}\n", .{vector_base});
        return 1;
    };
    const stopped = cpu.run(budget);
    return report(out, cpu, stopped);
}

pub fn report(out: anytype, cpu: cpu_mod.Cpu, stopped: cpu_mod.Stop) !u8 {
    switch (stopped) {
        .count => {
            try out.print("zig core: ran {d} instructions clean, pc 0x{X:0>8}\n", .{ cpu.retired, cpu.regs.pc });
            return 0;
        },
        .unknown => |instr| try out.print(
            "zig core: unknown encoding at {} after {d} instructions\n",
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
    }
    return 1;
}

//! A run on the Zig core instead of Unicorn, chosen with `--cpu zig`.
//!
//! The image is loaded and the board RAM mapped exactly as for a Unicorn
//! run; the Zig core then resets out of the same vector table and runs until
//! its budget is spent or it meets something it cannot do yet, most often an
//! encoding no group in src/core/cpu/ops/table.zig claims. This file prints
//! one line saying which, so a corpus sweep can tell how far each image
//! gets; main then prints the board's own report (report/run.zig, zigCore).
const engine = @import("../engine.zig");
const EngineBus = @import("engine_bus.zig").EngineBus;
const BoardBus = @import("board_bus.zig").BoardBus;
const registry = @import("../../periph/registry.zig");
const cpu_mod = @import("cpu.zig");
const elf = @import("../elf.zig");
const Choice = @import("choice.zig").Choice;
const lockstep_mode = @import("lockstep/mode.zig");
const NvicSource = @import("exception/nvic_source.zig").NvicSource;
const QuietSource = @import("exception/quiet_source.zig").QuietSource;
const DecodeCache = @import("decode_cache.zig").DecodeCache;
const sau = @import("../../periph/sau.zig");
const mpu = @import("../../periph/mpu/mpu.zig");
const fault_clear = @import("../../periph/fault_clear.zig");
const Bus = @import("bus.zig").Bus;
const Source = @import("exception/source.zig").Source;

/// Where a `--cpu zig` run hands time back to the board. The core runs
/// `width` instructions, then `close` charges them: SysTick and DWT_CYCCNT
/// count, the blocks tick, and whatever they pend is taken by the core's
/// own NVIC poll before the next instruction. Without one nothing on the
/// board moves, and a ThreadX image idles forever waiting for its first tick.
pub const Boundary = struct {
    context: *anyopaque,
    widthFn: *const fn (context: *anyopaque) u32,
    closeFn: *const fn (context: *anyopaque, instructions: u32) anyerror!void,
};

/// A debugger listening to a `--cpu zig` run: handed the bus and the
/// exception source the core would use, it returns the ones the core uses
/// instead (src/debug/rtos_zig.zig, RA8EMU-261).
pub const Wrap = struct {
    context: *anyopaque,
    busFn: *const fn (context: *anyopaque, inner: Bus) Bus,
    sourceFn: *const fn (context: *anyopaque, inner: Source) Source,
    /// Lent the core's retired-instruction count for the run, so a listener
    /// can time what it sees per instruction (RA8EMU-284).
    retiredFn: ?*const fn (context: *anyopaque, retired: *const u64) void = null,
};

/// What the board hands a `--cpu zig` run besides its peripheral bus: the
/// boundary that moves time, the core-private SAU and MPU its stores bank
/// into, and the fault status words its stores clear.
pub const Wiring = struct {
    boundary: ?Boundary = null,
    /// A listener put in front of the core's bus and exception source.
    wrap: ?Wrap = null,
    partitions: ?*sau.Sau = null,
    regions: ?*mpu.Mpu = null,
    clears: ?*fault_clear.Clears = null,
};

/// The hand-off from main for any CPU but Unicorn.
/// `periph` is the board's peripheral bus; a `--cpu zig` run reaches the
/// peripherals through it.
/// `ran` is set to how many instructions a `--cpu zig` run retired.
pub fn start(out: anytype, choice: Choice, image: elf.Image, core: *const engine.Engine, periph: ?*registry.Bus, vector_base: u32, budget: u64, ran: *u64, wiring: Wiring) !u8 {
    return switch (choice) {
        .unicorn => unreachable,
        .zig => if (periph) |board| runOnBoard(out, core, board, vector_base, budget, ran, wiring) else run(out, core, vector_base, budget),
        .lockstep => lockstep_mode.run(out, image, core, vector_base, budget, wiring.clears),
    };
}

/// Run the image already loaded into `core` on the Zig core, print how it
/// ended, and return the exit status: 0 when the budget was spent, 1 when
/// the core stopped short of it.
pub fn run(out: anytype, core: *const engine.Engine, vector_base: u32, budget: u64) !u8 {
    var memory: EngineBus = .{ .core = core };
    return runOn(out, memory.view(), vector_base, budget, null, null, null);
}

/// As `run`, with the peripheral windows answered by the board's bus.
pub fn runOnBoard(out: anytype, core: *const engine.Engine, periph: *registry.Bus, vector_base: u32, budget: u64, ran: ?*u64, wiring: Wiring) !u8 {
    var board: BoardBus = .{ .memory = .{ .core = core }, .periph = periph, .scs = .{ .partitions = wiring.partitions, .regions = wiring.regions, .clears = wiring.clears } };
    return runOn(out, board.view(), vector_base, budget, ran, wiring.boundary, wiring.wrap);
}

fn runOn(out: anytype, memory: Bus, vector_base: u32, budget: u64, ran: ?*u64, boundary: ?Boundary, wrap: ?Wrap) !u8 {
    var pending: NvicSource = .{};
    // A wrapped run listens to every poll, so it keeps the plain one.
    var quiet: QuietSource = .{ .inner = pending.source(), .memory = memory };
    var cpu: cpu_mod.Cpu = if (wrap) |w|
        .{ .bus = w.busFn(w.context, memory), .source = w.sourceFn(w.context, pending.source()) }
    else
        .{ .bus = quiet.bus(), .source = quiet.source(), .quiet = &quiet };
    var decoded: DecodeCache = .{};
    cpu.decoded = &decoded;
    if (wrap) |w| if (w.retiredFn) |lend| lend(w.context, &cpu.retired);
    cpu.reset(vector_base) catch {
        try out.print("zig core: no vector table at 0x{X:0>8}\n", .{vector_base});
        return 1;
    };
    const stopped = try stretches(&cpu, budget, boundary);
    if (ran) |count| count.* = cpu.retired;
    return report(out, cpu, stopped);
}

/// The budget in stretches, each closed by the boundary. A stretch the core
/// stops inside is not closed: it never ran to its edge.
pub fn stretches(cpu: *cpu_mod.Cpu, budget: u64, boundary: ?Boundary) !cpu_mod.Stop {
    const edge = boundary orelse return cpu.run(budget);
    var left = budget;
    while (left > 0) {
        const width: u32 = @intCast(@min(left, @max(1, edge.widthFn(edge.context))));
        const stopped = cpu.run(width);
        if (stopped != .count) return stopped;
        left -= width;
        try edge.closeFn(edge.context, width);
    }
    return .count;
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
        .unaligned => |at| try out.print(
            "zig core: unaligned MemA access at 0x{X:0>8} after {d} instructions\n",
            .{ at, cpu.retired },
        ),
    }
    return 1;
}

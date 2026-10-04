//! A run on the Zig core instead of Unicorn, chosen with `--cpu zig`.
//!
//! The image is loaded and the board RAM mapped exactly as for a Unicorn
//! run; the Zig core then resets out of the same vector table and runs until
//! its budget is spent or it meets something it cannot do yet, most often an
//! encoding no group in src/core/cpu/ops/table.zig claims. This file prints
//! one line saying which, so a corpus sweep can tell how far each image
//! gets; main then prints the board's own report (report/run.zig, zigCore).
const std = @import("std");
const Guest = @import("memory/guest.zig").Guest;
const GuestBus = @import("memory/guest_bus.zig").GuestBus;
const BoardBus = @import("board_bus.zig").BoardBus;
const registry = @import("../../periph/registry.zig");
const cpu_mod = @import("cpu.zig");
const elf = @import("../elf.zig");
const Choice = @import("choice.zig").Choice;
const lockstep_mode = @import("lockstep/mode.zig");
const lockstep_dual = @import("lockstep/dual.zig");
const NvicSource = @import("exception/nvic_source.zig").NvicSource;
const QuietSource = @import("exception/quiet_source.zig").QuietSource;
const DecodeCache = @import("decode_cache.zig").DecodeCache;
const BlockCache = @import("block_cache.zig").BlockCache;
const sau = @import("../../periph/sau.zig");
const SauSource = @import("sau_source.zig").SauSource;
const DataGate = @import("data_gate.zig").Gate;
const Attribution = @import("attribution.zig").Attribution;
const mpu = @import("../../periph/mpu/mpu.zig");
const fault_clear = @import("../../periph/fault_clear.zig");
const fault_status = @import("../../periph/fault_status.zig");
const Bus = @import("bus.zig").Bus;
const code_lines = @import("code_lines.zig");
const FpState = @import("fpu/state.zig").State;
const mpu_check = @import("mpu_check.zig");
const Source = @import("exception/source.zig").Source;
const Until = @import("../until.zig").Until;
const Reboot = @import("../reboot.zig").Reboot;
/// The register file a `--cpu zig` run hands back when it ends.
pub const Regs = @import("regs.zig").Regs;

/// Where a `--cpu zig` run hands time back to the board. The core runs
/// `width` instructions, then `close` charges them: SysTick and DWT_CYCCNT
/// count, the blocks tick, and whatever they pend is taken by the core's
/// own NVIC poll before the next instruction. Without one nothing on the
/// board moves, and a ThreadX image idles forever waiting for its first tick.
pub const Boundary = struct {
    context: *anyopaque,
    widthFn: *const fn (context: *anyopaque) u32,
    closeFn: *const fn (context: *anyopaque, instructions: u32) anyerror!void,
    /// The reset a block asked for at this boundary (a watchdog underflow,
    /// AIRCR.SYSRESETREQ), performed before the next stretch the way the
    /// Unicorn run loop performs it (RA8EMU-508).
    reboot: ?*Reboot = null,
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
    /// A finished console line that ends the run at its next boundary.
    until: ?*Until = null,
    /// A listener put in front of the core's bus and exception source.
    wrap: ?Wrap = null,
    /// A listener called with the address of each retired instruction.
    retire_listener: ?cpu_mod.RetireListener = null,
    partitions: ?*sau.Sau = null,
    /// The part's IDAU map beside the SAU (RA8EMU-277).
    idau: ?*const sau.idau.Map = null,
    regions: ?*mpu.Mpu = null,
    /// The Non-secure MPU (RA8EMU-446), banked beside `regions`.
    regions_ns: ?*mpu.Mpu = null,
    clears: ?*fault_clear.Clears = null,
    /// The SysTick timers whose arming ends a stretch (RA8EMU-464).
    cut: ?*cpu_mod.systick_cut.Cut = null,
    /// Direct MRAM/SRAM access is enabled only when the run has no memory
    /// watch or fault instrumentation that must observe each access.
    fast_memory: bool = false,
    /// `--blocks`: run from formed blocks (RA8EMU-405).
    blocks: bool = false,
    /// CPU1 under `--cpu lockstep --cpu1` (RA8EMU-235).
    cpu1: ?*lockstep_dual.Cpu1 = null,
    /// The `--ns` half, loaded into lockstep's own engine beside the main
    /// image so both sides start from the same memory (RA8EMU-372).
    ns_image: ?elf.Image = null,
    /// Filled with the core's registers as the run left them, for the
    /// `--report json` register dump (RA8EMU-579).
    final: ?*Regs = null,
};

/// The hand-off from main for any CPU but Unicorn.
/// `periph` is the board's peripheral bus; a `--cpu zig` run reaches the
/// peripherals through it.
/// `ran` is set to how many instructions a `--cpu zig` run retired.
pub fn start(out: anytype, choice: Choice, image: elf.Image, memory: Guest, periph: ?*registry.Bus, vector_base: u32, budget: u64, ran: *u64, wiring: Wiring) !u8 {
    return switch (choice) {
        .unicorn => unreachable,
        .zig => if (periph) |board| runOnBoard(out, memory, board, vector_base, budget, ran, wiring) else run(out, memory, vector_base, budget, wiring.retire_listener),
        // Lockstep compares against Unicorn, so it only runs over the engine.
        .lockstep => lockstep_mode.run(out, .{ .main = image, .ns = wiring.ns_image }, &memory.engine, vector_base, budget, wiring.clears, wiring.cpu1, wiring.retire_listener, wiring.blocks),
    };
}

/// Run the image already loaded into `memory` on the Zig core, print how it
/// ended, and return the exit status: 0 when the budget was spent, 1 when
/// the core stopped short of it.
pub fn run(out: anytype, memory: Guest, vector_base: u32, budget: u64, retire_listener: ?cpu_mod.RetireListener) !u8 {
    var reach = GuestBus.of(&memory, false);
    return runOn(out, reach.view(), vector_base, budget, null, null, null, retire_listener, null, null, false, null, null);
}

/// As `run`, with the peripheral windows answered by the board's bus.
pub fn runOnBoard(out: anytype, memory: Guest, periph: *registry.Bus, vector_base: u32, budget: u64, ran: ?*u64, wiring: Wiring) !u8 {
    var board: BoardBus = .{ .memory = GuestBus.of(&memory, wiring.fast_memory), .periph = periph, .scs = .{ .partitions = wiring.partitions, .regions = wiring.regions, .regions_ns = wiring.regions_ns, .clears = wiring.clears, .cut = wiring.cut } };
    var partitions: SauSource = undefined;
    const source: ?Attribution = if (wiring.partitions) |unit| blk: {
        partitions = .{ .unit = unit, .idau = wiring.idau };
        break :blk partitions.source();
    } else null;
    return runOn(out, board.view(), vector_base, budget, ran, wiring.boundary, wiring.wrap, wiring.retire_listener, &board, source, wiring.blocks, wiring.until, wiring.final);
}

fn runOn(out: anytype, memory: Bus, vector_base: u32, budget: u64, ran: ?*u64, boundary: ?Boundary, wrap: ?Wrap, retire_listener: ?cpu_mod.RetireListener, board: ?*BoardBus, source: ?Attribution, blocks: bool, until: ?*Until, final: ?*Regs) !u8 {
    var pending: NvicSource = .{};
    // A wrapped run listens to every poll, so it keeps the plain one.
    var quiet: QuietSource = .{ .inner = pending.source(), .memory = memory };
    var cpu: cpu_mod.Cpu = if (wrap) |w|
        .{ .bus = w.busFn(w.context, memory), .source = w.sourceFn(w.context, pending.source()) }
    else
        .{ .bus = quiet.bus(), .source = quiet.source(), .quiet = &quiet };
    pending.banked = &cpu.banked;
    var decoded: DecodeCache = .{};
    cpu.decoded = &decoded;
    const formed: ?*BlockCache = if (blocks) try std.heap.page_allocator.create(BlockCache) else null;
    defer if (formed) |cache| std.heap.page_allocator.destroy(cache);
    if (formed) |cache| {
        cache.init();
        try code_lines.watch(&cache.lines);
    }
    defer if (formed) |cache| code_lines.unwatch(&cache.lines);
    cpu.blocks = formed;
    cpu.retire_listener = retire_listener;
    cpu.until = until;
    cpu.attribution = source;
    var check: mpu_check.Check = undefined;
    var gate: DataGate = undefined;
    if (source) |from| {
        gate = .{ .source = from, .current = &cpu.banked.current };
        cpu.bus.gate = &gate;
    }
    if (board) |b| {
        b.scs.fp = &cpu.fp;
        b.security = &cpu.banked;
        cpu.cut = b.scs.cut;
        if (b.scs.regions) |unit| {
            check = .{ .unit = unit, .unit_ns = b.scs.regions_ns, .state = &cpu.banked.current };
            b.check = &check;
            cpu.mpu = &check;
        }
    }
    if (wrap) |w| if (w.retiredFn) |lend| lend(w.context, &cpu.retired);
    cpu.reset(vector_base) catch {
        try out.print("zig core: no vector table at 0x{X:0>8}\n", .{vector_base});
        return 1;
    };
    const stopped = try stretches(&cpu, budget, boundary, until);
    if (ran) |count| count.* = cpu.retired;
    if (final) |into| into.* = cpu.regs;
    const code = try report(out, cpu, stopped);
    if (until) |wait| if (wait.reached) {
        try out.print("stopped clean on the console line \"{s}\", pc 0x{X:0>8}\n", .{ wait.needle, cpu.regs.pc });
    };
    if (board) |b| try fault_status.line(out, b.faults());
    return code;
}

/// The budget in stretches, each closed by the boundary. A stretch the core
/// stops inside is not closed: it never ran to its edge.
pub fn stretches(cpu: *cpu_mod.Cpu, budget: u64, boundary: ?Boundary, until: ?*Until) !cpu_mod.Stop {
    const edge = boundary orelse return cpu.run(budget);
    var left = budget;
    while (left > 0) {
        const width: u32 = @intCast(@min(left, @max(1, edge.widthFn(edge.context))));
        const stopped = cpu.run(width);
        if (until) |wait| if (wait.reached) return .count;
        if (stopped != .count) return stopped;
        // The firmware armed SysTick inside this stretch: like the Unicorn
        // run loop, charge it one instruction and no time, and cut the next
        // stretch from the period now armed (RA8EMU-464).
        if (cpu.cut) |cut| if (cut.take()) {
            left -= 1;
            continue;
        };
        left -= width;
        try edge.closeFn(edge.context, width);
        if (edge.reboot) |pending| if (pending.requested) try rebooted(cpu, pending);
    }
    return .count;
}

/// A warm reboot of the Zig core, as src/core/reboot.zig performs one on
/// Unicorn: SP and PC from the vector table, PRIMASK clear, handler frames
/// abandoned, RAM kept. The retired count is the run's, so it carries on.
fn rebooted(cpu: *cpu_mod.Cpu, pending: *Reboot) !void {
    pending.requested = false;
    pending.performed +%= 1;
    const retired = cpu.retired;
    try cpu.reset(pending.vector_base);
    cpu.retired = retired;
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

//! A `--cpu zig` (or `--cpu lockstep`) run started from main, with the
//! board's time wired in. The Unicorn run loop charges SysTick, DWT_CYCCNT
//! and the blocks at every chunk boundary; this gives the Zig core the same
//! boundary, so a ThreadX image gets its tick and the peripherals that count
//! time (the USB host script among them) move.
const std = @import("std");
const engine = @import("../../core/engine.zig");
const boot = @import("../../core/cpu/boot.zig");
const elf = @import("../../core/elf.zig");
const clocks = @import("../../periph/clocks.zig");
const systick_bank = @import("../../core/systick_bank.zig");
const cli = @import("cli.zig");
const Board = @import("../../board/board.zig").Board;
const report_run = @import("report/run.zig");
const json_run = @import("report/json_run.zig");
const report_dumps = @import("report/dumps.zig");
const frame_out = @import("frame_out.zig");
const rtos_hook = @import("../../debug/rtos_hook.zig");
const second_core = @import("../../core/second_core.zig");
const lockstep_dual = @import("../../core/cpu/lockstep/dual.zig");
const profile = @import("../../debug/profile.zig");
const mem_dump = @import("../../debug/mem_dump.zig");
const cpu = @import("../../core/cpu/cpu.zig");
const systick_cut = cpu.systick_cut;
const Until = @import("../../core/until.zig").Until;

const BootWriter = struct {
    output: *std.fs.File.Writer,
    quiet: bool,

    pub fn print(self: BootWriter, comptime format: []const u8, args: anytype) !void {
        if (!self.quiet) try self.output.print(format, args);
    }

    pub fn writeAll(self: BootWriter, bytes: []const u8) !void {
        if (!self.quiet) try self.output.writeAll(bytes);
    }
};

/// The board side of a Zig-core boundary.
pub const Clock = struct {
    core: *engine.Engine,
    board: *Board,
    timebase: *clocks.Clocks,
    /// CPU0's Non-secure SysTick (RA8EMU-449). Only its timer is charged:
    /// DWT_CYCCNT and the run's own count belong to `timebase`.
    ns_timebase: clocks.Clocks = .{ .words = systick_bank.non_secure_words },
    /// CPU1 on its Zig core under --cpu zig --cpu1, or null (RA8EMU-234).
    cpu1: ?*second_core.zig_run.Driver = null,

    pub fn boundary(self: *Clock) boot.Boundary {
        return .{ .context = self, .widthFn = widthThunk, .closeFn = closeThunk };
    }

    /// The chunk the Unicorn path uses, cut down to the armed SysTick period
    /// so a stretch never swallows more than one wrap.
    pub fn width(self: *const Clock) u32 {
        const period = systick_bank.width(self.timebase.period(self.core.*), self.ns_timebase.period(self.core.*));
        if (period != 0 and period < self.timebase.per_chunk) return period;
        return self.timebase.per_chunk;
    }

    /// Charge the stretch to the clocks, then tick the blocks, in the order
    /// the Unicorn run loop does.
    pub fn close(self: *Clock, instructions: u32) !void {
        try self.timebase.advance(self.core.*, instructions);
        try self.ns_timebase.advanceSysTick(self.core.*, instructions);
        try self.board.tick(self.core.*, instructions);
        if (self.cpu1) |second| second.round(instructions);
    }
};

fn widthThunk(context: *anyopaque) u32 {
    const self: *Clock = @ptrCast(@alignCast(context));
    return self.width();
}

fn closeThunk(context: *anyopaque, instructions: u32) anyerror!void {
    const self: *Clock = @ptrCast(@alignCast(context));
    return self.close(instructions);
}

/// Run off Unicorn, then, for a Zig run, print what the board has to say.
pub fn run(out: std.fs.File.Writer, core: *engine.Engine, board: *Board, timebase: *clocks.Clocks, image: elf.Image, options: cli.Options, vector_base: u32, profile_table: ?*profile.Table, until: ?*Until) !u8 {
    var ran: u64 = 0;
    var clock: Clock = .{ .core = core, .board = board, .timebase = timebase };
    var cut: systick_cut.Cut = .{ .clocks = .{ timebase, &clock.ns_timebase } };
    var pair: second_core.zig_run.Driver = undefined;
    const path = if (options.cpu == .zig) options.cpu1_path else null;
    if (path) |named| {
        pair.open(std.heap.page_allocator, core, board, named) catch |err| {
            std.debug.print("cannot bring up the second core from {s}: {s}\n", .{ named, @errorName(err) });
            return 1;
        };
        if (options.blocks) pair.core.useBlocks() catch |err| {
            pair.close();
            std.debug.print("cannot give the second core its block cache: {s}\n", .{@errorName(err)});
            return 1;
        };
        clock.cpu1 = &pair;
        rtos_hook.second.armZig(&pair, options.rtosWanted(), named);
    }
    defer if (clock.cpu1) |second| second.close();
    var checked: lockstep_dual.Cpu1 = undefined;
    const checked_path = if (options.cpu == .lockstep) options.cpu1_path else null;
    if (checked_path) |named| {
        checked.open(std.heap.page_allocator, core, board, named) catch |err| {
            std.debug.print("cannot bring up the second core from {s}: {s}\n", .{ named, @errorName(err) });
            return 1;
        };
    }
    defer if (checked_path != null) checked.close();
    // --trace-rtos listens in front of the core (src/debug/rtos_zig.zig).
    var tracer = if (options.cpu == .zig) rtos_hook.resolve(image, options.rtosWanted()) else null;
    var listener: rtos_hook.zig.Listener = undefined;
    if (tracer) |*found| {
        found.now = &timebase.ticks;
        listener = .{ .tracer = found };
    }
    const wrap = if (tracer != null) listener.wrap() else null;
    const retire_listener: ?cpu.RetireListener = if (profile_table) |table| .{ .context = table, .instructionFn = profileInstruction } else null;
    var boot_output = out;
    const status = try boot.start(BootWriter{ .output = &boot_output, .quiet = options.ctl_cpu_load }, options.cpu, image, core, &board.bus, vector_base, options.budgetFor(false), &ran, .{
        .boundary = clock.boundary(),
        .partitions = &board.partitions,
        .idau = &board.idau,
        .regions = &board.regions,
        .regions_ns = &board.regions_ns,
        .clears = &board.clears,
        .cut = &cut,
        .fast_memory = options.watch_place == null and wrap == null,
        .blocks = options.blocks,
        .wrap = wrap,
        .cpu1 = if (checked_path != null) &checked else null,
        .retire_listener = retire_listener,
        .ns_image = if (options.cpu == .lockstep) try report_dumps.nonSecure(std.heap.page_allocator, options) else null,
        .until = if (options.cpu == .zig) until else null,
    });
    if (options.cpu == .zig) {
        // The core lent its retired count; `ran` holds the final count.
        if (tracer) |*found| found.trace.fine = &ran;
        if (options.ctl_cpu_load) return ctlLoad(out, loadOf(core, if (tracer) |*found| found else null, clock.cpu1), status);
        if (options.report_json) {
            const load = loadOf(core, if (tracer) |*found| found else null, clock.cpu1);
            try json_run.document(out, board, .{ .engine = "zig", .elapsed = ran, .where = .{ .image = image, .profile = profile_table }, .dumps = &.{ .core = core.*, .image = image, .options = &options }, .load = if (options.cpu_load) &load else null });
        } else try report_run.zigCore(out, board, timebase.*, ran);
        try second_core.report(out, if (clock.cpu1) |second| &second.second else null);
        // The globals a memory-probe verdict reads. The Zig core's stores land
        // in the same engine memory, so the line is the Unicorn run's line.
        if (!options.report_json) try report_dumps.dumpSymbols(out, core.*, image, options);
        if (!options.report_json) try mem_dump.print(out, core.*, image, options.dump_mem, options.dump_mem_words);
        if (tracer) |*found| try rtos_hook.report.all(out, options, found, rtos_hook.Memory{ .handle = core.handle });
        if (clock.cpu1) |second| try rtos_hook.second.print(out, options, &second.second);
        try frame_out.report(out, board, options.frame_out);
    } else if (options.ctl_cpu_load) return ctlLoad(out, .{}, status);
    return status;
}

/// `ctl cpu-load` prints only the load object, then the run's status.
fn ctlLoad(out: std.fs.File.Writer, load: json_run.json_load.Load, status: u8) !u8 {
    try json_run.json_load.document(out, &load);
    return status;
}

/// The traced cores `--cpu-load` reads under `--report json` (RA8EMU-266).
fn loadOf(core: *engine.Engine, tracer: ?*const rtos_hook.Tracer, cpu1: ?*second_core.zig_run.Driver) json_run.json_load.Load {
    return .{
        .cpu0 = rtos_hook.report.sideOf(tracer, .{ .handle = core.handle }),
        .cpu1 = rtos_hook.second.side(if (cpu1) |pair| &pair.second else null),
    };
}

fn profileInstruction(context: *anyopaque, address: u32) void {
    const table: *profile.Table = @ptrCast(@alignCast(context));
    table.instruction(address);
}

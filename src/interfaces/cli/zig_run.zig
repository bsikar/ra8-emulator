//! A `--cpu zig` run started from main, with the
//! board's time wired in. The Unicorn run loop charges SysTick, DWT_CYCCNT
//! and the blocks at every chunk boundary; this gives the Zig core the same
//! boundary, so a ThreadX image gets its tick and the peripherals that count
//! time (the USB host script among them) move.
const std = @import("std");
const engine = @import("../../core/engine.zig");
const Guest = @import("../../core/cpu/memory/guest.zig").Guest;
const boot = @import("../../core/cpu/boot.zig");
const elf = @import("../../core/elf.zig");
const clocks = @import("../../periph/clocks.zig");
const systick_bank = @import("../../core/systick_bank.zig");
const scs_route = @import("../../core/cpu/scs_route.zig");
const sleep_pace = @import("../../core/sleep_pace.zig");
const board_edge = @import("../../board/boundary.zig");
const quiet_due = @import("../../board/quiet_due.zig");
const cli = @import("cli.zig");
const Board = @import("../../board/board.zig").Board;
const report_run = @import("report/run.zig");
const json_run = @import("report/json_run.zig");
const report_dumps = @import("report/dumps.zig");
const frame_out = @import("frame_out.zig");
const frames_out = @import("report.zig").frames_out;
const rtos_hook = @import("../../debug/rtos_hook.zig");
const second_core = @import("../../core/second_core.zig");
const profile = @import("../../debug/profile.zig");
const mem_dump = @import("../../debug/mem_dump.zig");
const cpu = @import("../../core/cpu/cpu.zig");
const systick_cut = cpu.systick_cut;
const Until = @import("../../core/until.zig").Until;
const Stop = @import("../../core/stop.zig").Stop;
const Deadline = @import("../../core/deadline.zig").Deadline;
/// The `--stop-sym` counter a Zig run watches: src/interfaces/cli/zig_stop.zig.
pub const stop_sym = @import("zig_stop.zig");
/// The `--break-sym` arrival a Zig run counts: src/interfaces/cli/zig_break.zig.
pub const break_sym = @import("zig_break.zig");
/// `--stop-on-undefined` on a Zig run: src/interfaces/cli/zig_undefined.zig.
pub const undefined_sites = @import("zig_undefined.zig");

/// What ends a Zig run before its budget: the `--stop-sym` counter and the
/// `--break-sym` arrival (RA8EMU-603).
pub const Ends = struct {
    stop: ?*Stop = null,
    point: ?*break_sym.Break = null,
    /// The `--ms` window, read against the clocks' SysTick periods.
    timed: ?*Deadline = null,
    /// The swept sites `--stop-on-undefined` ends the run on.
    undefined_sites: ?*undefined_sites.Found = null,
};
/// CPU0's memory for a single-core run: src/interfaces/cli/zig_memory.zig.
pub const cpu0_memory = @import("zig_memory.zig");
/// A `--cpu zig` run from main, with no engine opened: RA8EMU-592.
pub const main_path = @import("zig_main.zig");

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
    /// The memory the clocks, the board tick and the reports read and write.
    memory: Guest,
    board: *Board,
    timebase: *clocks.Clocks,
    /// CPU0's Non-secure SysTick (RA8EMU-449). Only its timer is charged:
    /// DWT_CYCCNT and the run's own count belong to `timebase`.
    ns_timebase: clocks.Clocks = .{ .words = systick_bank.non_secure_words },
    /// CPU1 on its Zig core under --cpu zig --cpu1, or null (RA8EMU-234).
    cpu1: ?*second_core.zig_run.Driver = null,
    /// The `--stop-sym` counter, read at each boundary (RA8EMU-603).
    stop: ?*Stop = null,
    /// The `--break-sym` arrival, which ends the run once met.
    point: ?*break_sym.Break = null,
    /// The `--ms` window, which ends the run once modelled time runs out.
    timed: ?*Deadline = null,
    undefined_sites: ?*undefined_sites.Found = null,
    /// `--idle-skip`: a sleeping CPU0 runs straight to the next edge (RA8EMU-185).
    idle_skip: bool = false,

    pub fn boundary(self: *Clock) boot.Boundary {
        return .{ .context = self, .widthFn = widthThunk, .closeFn = closeThunk, .reboot = self.board.reboot, .doneFn = doneThunk, .sleepFn = if (self.idle_skip) sleepThunk else null };
    }

    /// A sleeping CPU0's width: to the nearest armed SysTick period, the
    /// board's next queued event, the panel's next vsync or the GPT's next
    /// wrap, turn or match. CPU1 shares each boundary, so a run with
    /// it keeps the normal width, as does a board with a block mid-work.
    pub fn asleepWidth(self: *Clock, normal: u32) u32 {
        if (self.cpu1 != null or !quiet_due.quietUntilDue(self.board)) return normal;
        const edges = [_]u64{ self.timebase.period(self.memory), self.ns_timebase.period(self.memory), board_edge.cyclesToDue(self.board), quiet_due.vsyncDue(self.board), quiet_due.gptDue(self.board) };
        return sleep_pace.width(normal, true, &edges);
    }

    /// Has a soak event (a watchdog reset, or a fault latched since the last
    /// boundary) ended the run, or the watched counter climbed to its floor? An unreadable word is not a stop, as on the Unicorn path
    /// (src/core/stop.zig).
    pub fn done(self: *Clock) bool {
        self.soakFaults();
        if (self.board.time.soak.ended()) return true;
        if (self.point) |point| if (point.reached) return true;
        if (self.timed) |due| if (due.met(self.timebase.ticks)) return true;
        if (self.undefined_sites) |found| if (found.stoppedAt() != null) return true;
        const watch = self.stop orelse return false;
        return watch.met(self.memory.readWord(watch.address) catch null);
    }

    /// Note a fault the core latched as the soak's event, when it is armed and
    /// has none yet. Also asked once after the run, for a core that stopped
    /// inside a stretch and never reached its boundary.
    pub fn soakFaults(self: *Clock) void {
        const soak = &self.board.time.soak;
        if (!soak.armed or soak.ended()) return;
        const latched = clocks.soak_fault.words(self.memory, &landScs);
        if (clocks.soak_fault.kind(latched)) |fault| soak.note(fault, self.board.time.base.now());
    }

    /// The chunk the Unicorn path uses, cut down to the armed SysTick period
    /// so a stretch never swallows more than one wrap.
    pub fn width(self: *const Clock) u32 {
        const period = systick_bank.width(self.timebase.period(self.memory), self.ns_timebase.period(self.memory));
        if (period != 0 and period < self.timebase.per_chunk) return period;
        return self.timebase.per_chunk;
    }

    /// Charge the stretch to the clocks, then tick the blocks, in the order
    /// the Unicorn run loop does.
    pub fn close(self: *Clock, instructions: u32) !void {
        try self.timebase.advance(self.memory, instructions);
        try self.ns_timebase.advanceSysTick(self.memory, instructions);
        try self.board.tick(self.memory, instructions);
        if (self.cpu1) |second| second.round(instructions);
    }
};

/// Where the Zig core keeps an SCB word, read as Secure (src/core/cpu/scs_route.zig).
fn landScs(address: u32) ?u32 {
    return switch (scs_route.land(null, address)) {
        .at => |at| at,
        .res0 => null,
    };
}

fn widthThunk(context: *anyopaque) u32 {
    const self: *Clock = @ptrCast(@alignCast(context));
    return self.width();
}

fn sleepThunk(context: *anyopaque, normal: u32) u32 {
    const self: *Clock = @ptrCast(@alignCast(context));
    return self.asleepWidth(normal);
}

fn doneThunk(context: *anyopaque) bool {
    const self: *Clock = @ptrCast(@alignCast(context));
    return self.done();
}

fn closeThunk(context: *anyopaque, instructions: u32) anyerror!void {
    const self: *Clock = @ptrCast(@alignCast(context));
    return self.close(instructions);
}

/// Run off Unicorn, then, for a Zig run, print what the board has to say.
/// `memory` is CPU0's store (RA8EMU-577); no engine is opened (RA8EMU-607).
pub fn run(out: std.fs.File.Writer, memory: Guest, board: *Board, timebase: *clocks.Clocks, image: elf.Image, options: cli.Options, vector_base: u32, profile_table: ?*profile.Table, until: ?*Until, ends: Ends) !u8 {
    var ran: u64 = 0;
    var clock: Clock = .{ .memory = memory, .board = board, .timebase = timebase, .stop = ends.stop, .point = ends.point, .timed = ends.timed, .undefined_sites = ends.undefined_sites, .idle_skip = options.idle_skip };
    var cut: systick_cut.Cut = .{ .clocks = .{ timebase, &clock.ns_timebase } };
    var pair: second_core.zig_run.Driver = undefined;
    const path = if (options.cpu == .zig) options.cpu1_path else null;
    if (path) |named| {
        pair.open(std.heap.page_allocator, board, named, memory) catch |err| {
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
    // --trace-rtos listens in front of the core (src/debug/rtos_zig.zig).
    var tracer = if (options.cpu == .zig) rtos_hook.resolve(image, options.rtosWanted()) else null;
    var listener: rtos_hook.zig.Listener = undefined;
    if (tracer) |*found| {
        found.now = &timebase.ticks;
        listener = .{ .tracer = found };
    }
    const wrap = if (tracer != null) listener.wrap() else null;
    const budget = options.budgetFor(ends.stop != null);
    var retire: break_sym.Retire = .{ .table = profile_table, .point = ends.point };
    var boot_output = out;
    var final: boot.Regs = .{};
    const status = try boot.start(BootWriter{ .output = &boot_output, .quiet = options.ctl_cpu_load }, options.cpu, clock.memory, &board.bus, vector_base, budget, &ran, .{
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
        .retire_listener = retire.listener(),
        .fetch_guard = if (ends.undefined_sites) |found| undefined_sites.guard(found) else null,
        .until = if (options.cpu == .zig) until else null,
        .final = &final,
    });
    clock.soakFaults();
    board.time.soak.place(final.pc, if (board.clock.running()) board.clock.now else null);
    const said = BootWriter{ .output = &boot_output, .quiet = options.ctl_cpu_load };
    if (ends.point) |point| {
        try break_sym.verdict(said, options.break_place.?, point.*, retire.at, final.pc, budget);
    } else try stop_sym.verdict(said, options, if (ends.stop) |watch| watch.* else null, if (ends.timed) |due| due.* else null, final.pc, budget);
    if (ends.undefined_sites) |found| try undefined_sites.print(said, image, found.*);
    if (options.cpu == .zig) {
        // The core lent its retired count; `ran` holds the final count.
        if (tracer) |*found| found.trace.fine = &ran;
        if (options.ctl_cpu_load) return ctlLoad(out, loadOf(clock.memory, if (tracer) |*found| found else null, clock.cpu1), status);
        var frames = try frames_out.Run.initForCli(std.heap.page_allocator, board, options.frames);
        defer frames.deinit(board);
        if (options.report_json) {
            const load = loadOf(clock.memory, if (tracer) |*found| found else null, clock.cpu1);
            try json_run.document(out, board, .{ .engine = "zig", .elapsed = ran, .where = .{ .image = image, .profile = profile_table }, .dumps = &.{ .registers = .{ .zig = &final }, .memory = clock.memory, .image = image, .options = &options }, .load = if (options.cpu_load) &load else null });
        } else try report_run.zigCore(out, board, timebase.*, ran);
        try second_core.report(out, if (clock.cpu1) |second| &second.second else null);
        // The globals a memory-probe verdict reads, out of the Zig core's
        // own memory, so the line is the Unicorn run's line.
        if (!options.report_json) try report_dumps.dumpSymbols(out, clock.memory, image, options);
        if (!options.report_json) try mem_dump.printAll(out, clock.memory, image, options.memDumps());
        if (tracer) |*found| try rtos_hook.report.all(out, options, found, rtos_hook.Memory{ .guest = clock.memory });
        if (clock.cpu1) |second| try rtos_hook.second.printOn(out, options, second.guest());
        try finishFrames(out, board, options, &frames);
    } else if (options.ctl_cpu_load) {
        return ctlLoad(out, .{}, status);
    } else try captureFrames(board, options);
    return status;
}

fn finishFrames(out: std.fs.File.Writer, board: *Board, options: cli.Options, frames: *frames_out.Run) !void {
    try frames.finish(board);
    try frame_out.report(out, board, options.frame_out, options.panel_only);
}

fn captureFrames(board: *Board, options: cli.Options) !void {
    var frames = try frames_out.Run.initForCli(std.heap.page_allocator, board, options.frames);
    defer frames.deinit(board);
    try frames.finish(board);
}

/// `ctl cpu-load` prints only the load object, then the run's status.
fn ctlLoad(out: std.fs.File.Writer, load: json_run.json_load.Load, status: u8) !u8 {
    try json_run.json_load.document(out, &load);
    return status;
}

/// The traced cores `--cpu-load` reads under `--report json` (RA8EMU-266).
fn loadOf(memory: Guest, tracer: ?*const rtos_hook.Tracer, cpu1: ?*second_core.zig_run.Driver) json_run.json_load.Load {
    return .{
        .cpu0 = rtos_hook.report.sideOf(tracer, .{ .guest = memory }),
        .cpu1 = if (cpu1) |pair| rtos_hook.second.sideOn(pair.guest()) else null,
    };
}

//! ra8_emulator: the RA8D2 board emulator (#14, the Zig rewrite).
//!
//! This file wires the ELF, board and run together; the machine and its
//! peripherals live in src/core and src/periph, reached through "ra8".
const std = @import("std");
const ra8 = @import("ra8");

const cli = ra8.core.cli;
const card_setup = cli.card_setup;
const parts_mod = ra8.board.parts;
const Parts = parts_mod.Parts;
const elf = ra8.core.elf;
const symbols = ra8.core.symbols;
const undefined_ops = ra8.core.undefined_ops;
const stop_watch = ra8.core.stop;
const deadline = ra8.core.deadline;
const engine = ra8.core.engine;
const second_core = ra8.core.second_core;
const rtos_hook = ra8.core.step_hook.rtos_hook;
const lob = ra8.core.lob;
const clocks = ra8.periph.clocks;
const breakpoint = ra8.core.breakpoint;
const watchpoint = ra8.core.watchpoint;
const taken_in = ra8.core.taken_in;
const mem_dump = ra8.core.mem_dump;
const registers = ra8.core.registers;
const sd_dump = ra8.periph.sd_dump;
const nvic = ra8.periph.nvic;
const Board = ra8.board.Board;
const report = ra8.board.report;
const report_steps = ra8.board.report_steps;
const report_run = ra8.board.report_run;
const report_dumps = ra8.board.report_dumps;

/// Read the image off disk and parse it, saying which of the two failed.
fn openImage(allocator: std.mem.Allocator, path: []const u8) !elf.Image {
    const bytes = try readImage(allocator, path);
    return elf.Image.init(bytes) catch |err| {
        std.debug.print("{s} is not a loadable image: {s}\n", .{ path, @errorName(err) });
        return err;
    };
}

/// A TrustZone build's Non-Secure half (`--ns`), loaded at its load
/// addresses for the Secure boot to copy out. It goes in beside the main
/// image, never instead of it, and its entry point is the Secure side's to
/// find: nothing here resets into it.
fn loadNonSecure(allocator: std.mem.Allocator, core: engine.Engine, path: []const u8) !void {
    _ = try core.loadImage(try openImage(allocator, path));
}

/// Hand the watched place the run's own period counter, then hook it.
///
/// The stamp has to be wired before the first store lands, and the clock it
/// reads is the one the run advances, so the two are set together here.
fn armWatch(core: engine.Engine, one: *watchpoint.Watched, clock: *const u64) !void {
    one.now = clock;
    try core.attachWatchpoint(one);
}

/// Load the image, then read its option-setting memory the way the boot ROM
/// does before the first instruction: src/board/option_memory.zig.
fn loadAll(core: *engine.Engine, board: *Board, image: elf.Image, parts: *Parts, options: cli.Options) !u32 {
    if (options.console) board.console_input.enabled = true;
    parts.tap = .{ .echo = options.console, .wait = if (options.until) |text| .{ .needle = text } else null };
    cli.console_output.configure(&board.serial.line, &parts.tap);
    const written = try attachAll(core, image, parts, options);
    // TT answers from the SAU the firmware programmed: src/core/tt_hook.zig.
    _ = try ra8.core.csel.tt_hook.attach(core.handle, image, &board.partitions);
    _ = try ra8.core.csel.vscclrm_hook.attach(core.handle, image);
    ra8.board.option_memory.apply(board, core.*);
    return written;
}

fn attachAll(core: *engine.Engine, image: elf.Image, parts: *Parts, options: cli.Options) !u32 {
    // Addresses come off the command line already parsed, so nothing here
    // can fail: an empty list counts nothing and attaches no hook.
    for (options.count_pc[0..options.count_pc_len]) |at| parts.hits.want(at);
    try core.attachHits(&parts.hits);
    try core.attachWatch(&parts.watch);
    try core.attachLoops(&parts.loops);
    try core.attachSelects(&parts.selects);
    try ra8.core.csel.clrm_hook.attach(core.handle, &parts.clears);
    try core.attachIdle(&parts.idle);
    try core.attachTimebase(&parts.timebase);
    // Set before the hook is attached, since it is read as a store
    // retires. src/core/pend_break.zig carries what it does and why it is
    // off unless asked for.
    parts.pend.look.policy = if (options.drain_pends)
        .every
    else if (options.look_per_rise)
        .per_rise
    else
        .off;
    // Same reason: read as a boundary opens, and off unless asked for.
    // src/core/mask_pace.zig carries the measurement that says narrowing
    // while a mask holds recovers nothing.
    parts.mask_pacing.on = options.pace_masked;
    try core.attachPend(&parts.pend);
    parts.fns = .{ .image = image };
    if (options.profile) try parts.attachProfile(core.*, image, options.cpu == .unicorn);
    const written = try core.loadImage(image);
    try core.attachWorlds(image, &parts.worlds);
    return written;
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const argv = try std.process.argsAlloc(allocator);
    const options = cli.parse(argv) catch return ra8.core.debug_front.refused(allocator, argv);
    const image = openImage(allocator, options.path) catch return 1;

    var core = try engine.Engine.open();
    defer core.close();
    try core.mapBoardRam();

    var board = Board.init(allocator);
    defer board.deinit();
    fitBoard(&board, allocator, options) catch return 2;
    defer card_setup.saveBack(&board, options.sd_path, options.sd_save);
    try board.attach(&core);

    var parts = Parts{};
    const written = try loadAll(&core, &board, image, &parts, options);
    if (options.ns_path) |path| loadNonSecure(allocator, core, path) catch return 1;

    const vector_base = image.vectorBase() orelse {
        std.debug.print("no executable segment, nothing to reset into\n", .{});
        return 1;
    };
    try core.resetFromVectorTable(vector_base);
    const entry = try core.register(.pc);
    const out = try announce(core, written, vector_base, entry, options.ctl_cpu_load);
    var reboot = ra8.core.reboot.Reboot{ .vector_base = vector_base };
    board.reboot = &reboot;
    if (options.cpu != .unicorn) return ra8.board.zig_run.run(out, &core, &board, &parts.timebase, image, options, vector_base, if (parts.profile) |*table| table else null, if (options.cpu == .zig) parts.tap.waiting() else null);

    var interrupts = nvic.Nvic{ .vector_base = vector_base };
    _ = try parts.divide.arm(&core, &interrupts, image);
    var stop = resolveStop(image, options);
    var point = resolveBreak(image, options);
    if (point) |*one| try core.attachBreak(one);
    var watched = watchpoint.resolve(image, options.watch_place);
    if (watched) |*one| try armWatch(core, one, &parts.timebase.ticks);
    const tracer = try rtos_hook.arm(core.handle, image, options.rtosWanted(), &parts.timebase, &interrupts);
    var window = taken_in.resolve(image, options.taken_in_place);
    var undefined_found = resolveUndefined(image, options);
    try core.attachUndefined(&undefined_found);
    var storage: second_core.Second = undefined;
    var timed = resolveDeadline(options);
    const second = rtos_hook.second.arm(second_core.start(allocator, &core, &board, options.cpu1_path, &storage), options.rtosWanted(), options.cpu1_path) catch |err| {
        std.debug.print("cannot bring up the second core from {s}: {s}\n", .{ options.cpu1_path orelse "?", @errorName(err) });
        return 1;
    };
    defer if (second) |one| one.close();
    const fault = try second_core.interleave(core, entry, options.budgetFor(stop != null), .{
        .watch = &parts.watch,
        .timebase = &parts.timebase,
        .interrupts = &interrupts,
        .board = board.ticker(),
        .reboot = &reboot,
        .protection = &board.guard,
        .stop = if (stop) |*one| one else null,
        .until = parts.tap.waiting(),
        .brk = if (point) |*one| one else null,
        .undefined_sites = if (options.stop_on_undefined) &undefined_found else null,
        .deadline = if (timed) |*one| one else null,
        .idle = &parts.idle,
        .unmask = &parts.release,
        .pend = &parts.pend,
        .pend_pace = &parts.pacing,
        .mask_pace = &parts.mask_pacing,
        .pcs = &parts.pcs,
        .fns = &parts.fns.?,
        .taken_from = &parts.taken,
        .taken_in = if (window) |*one| one else null,
        .per_boundary = options.chunk_instructions,
        .bus_errors = if (options.bus_errors) &parts.bus_tally else null,
    }, second);

    try reportAll(out, core, &board, image, options, parts_mod.tallyOf(parts, interrupts, reboot, undefined_found), parts, second, watched, window, tracer);
    if (options.ctl_cpu_load) return if (fault != null) 1 else 0;
    return verdict(out, core, options, fault, stop, point, timed, options.budgetFor(stop != null), if (parts.tap.waiting()) |wait| wait.reached else false);
}

/// The opening line for ordinary runs, plus the writer used for the report.
fn announce(core: engine.Engine, written: u32, vector_base: u32, entry: u32, quiet: bool) !std.fs.File.Writer {
    const out = std.io.getStdOut().writer();
    if (!quiet) try out.print("loaded {d} bytes, vectors at 0x{X:0>8}, sp 0x{X:0>8}, pc 0x{X:0>8}\n", .{ written, vector_base, try core.register(.sp), entry });
    return out;
}

/// Everything a finished run prints, in the order it prints it.
///
/// Lifted out of `main` so the run's setup and the run's report are two
/// functions rather than one over the length gate. The order is the
/// contract: the board's own report first, then where the run spent
/// itself, then the second core, then whatever was dumped by request.
fn reportAll(
    out: anytype,
    core: engine.Engine,
    board: *Board,
    image: elf.Image,
    options: cli.Options,
    run: report_run.Tally,
    parts: Parts,
    second: ?*second_core.Second,
    watched: ?watchpoint.Watched,
    window: ?taken_in.Window,
    tracer: ?*const rtos_hook.Tracer,
) !void {
    const cpu0 = rtos_hook.report.sideOf(tracer, .{ .handle = core.handle });
    if (options.ctl_cpu_load) {
        const load = report.json_run.json_load.Load{ .cpu0 = cpu0, .cpu1 = rtos_hook.second.side(second) };
        try report.json_run.json_load.document(out, &load);
        return;
    }
    const tally = run.within(core, image, &options, window, watched).loaded(options.cpu_load, cpu0, rtos_hook.second.side(second));
    try report_run.pick(out, board, image, tally, options.report_json);
    if (!options.report_json) try ra8.board.report.after.text(out, image, options, parts, window);
    try second_core.report(out, second);
    if (!options.report_json) try report_dumps.dumps(out, core, image, options, board, watched);
    try rtos_hook.report.all(out, options, tracer, rtos_hook.Memory{ .guest = .{ .engine = core } });
    try rtos_hook.second.print(out, options, second);
    try report.frame_out.report(out, board, options.frame_out);
}

/// How the run ended, in one line, and the exit status that goes with it.
///
/// Four outcomes now, and the two middle ones are why this is not a single
/// print. A watched run that reached its counter stopped early and is a
/// pass, while a watched run that ran out never arrived at all; under the
/// plain "ran N instructions clean" line those read identically, which is
/// exactly the confusion a progress counter exists to settle. And what ran
/// out is worth naming too: a timed run that spent its whole window says so
/// in milliseconds, because an instruction count is not what was asked for
/// and is not what would be raised to get further.
fn verdict(
    out: anytype,
    core: engine.Engine,
    options: cli.Options,
    fault: ?engine.Fault,
    stop: ?stop_watch.Stop,
    point: ?breakpoint.Break,
    timed: ?deadline.Deadline,
    budget: usize,
    waited: bool,
) !u8 {
    if (fault) |taken| {
        try report.fault(out, taken);
        return 1;
    }
    const pc = try core.register(.pc);
    if (point) |arrived| return arrivals(out, options, arrived, pc, budget);
    if (waited) {
        try out.print("stopped clean on the console line \"{s}\", pc 0x{X:0>8}\n", .{ options.until.?, pc });
        return 0;
    }
    const spent = if (timed) |due| due.reached else false;
    const watched = stop orelse {
        if (spent) {
            try out.print("stopped clean after {d} ms, pc 0x{X:0>8}\n", .{ timed.?.periods, pc });
        } else {
            try out.print("ran {d} instructions clean, pc 0x{X:0>8}\n", .{ budget, pc });
        }
        return 0;
    };
    if (watched.reached) {
        try out.print(
            "stopped clean on {s} >= {d}, pc 0x{X:0>8}\n",
            .{ options.stop_symbol.?, watched.reaches, pc },
        );
        return 0;
    }
    if (spent) {
        try out.print(
            "ran {d} ms, {s} never reached {d}, pc 0x{X:0>8}\n",
            .{ timed.?.periods, options.stop_symbol.?, watched.reaches, pc },
        );
        return 0;
    }
    try out.print(
        "ran {d} instructions, {s} never reached {d}, pc 0x{X:0>8}\n",
        .{ budget, options.stop_symbol.?, watched.reaches, pc },
    );
    return 0;
}

/// Whether the run arrived at the address `--break-sym` named.
///
/// The negative is the useful half and is said plainly: a run that spent
/// its budget without arriving proves the firmware never called that
/// function. That is evidence a command trace cannot give, because a
/// function that touches no peripheral leaves no trace either way.
fn arrivals(
    out: anytype,
    options: cli.Options,
    point: breakpoint.Break,
    pc: u32,
    budget: usize,
) !u8 {
    if (point.reached) {
        try out.print(
            "reached {s} arrival {d}, pc 0x{X:0>8}\n",
            .{ options.break_place.?, point.seen, pc },
        );
        return 0;
    }
    try out.print(
        "ran {d} instructions, reached {s} {d} time(s) of {d}, pc 0x{X:0>8}\n",
        .{ budget, options.break_place.?, point.seen, point.arrival, pc },
    );
    return 0;
}

/// The modelled-time window a run is allowed, or none.
/// The undefined-instruction sweep, told to end the run when asked.
fn resolveUndefined(image: elf.Image, options: cli.Options) undefined_ops.Found {
    var found = undefined_ops.sweep(image);
    if (options.stop_on_undefined) found.stopOnRun();
    return found;
}

fn resolveDeadline(options: cli.Options) ?deadline.Deadline {
    const milliseconds = options.ms orelse return null;
    return .{ .periods = milliseconds };
}

/// The function `--break-sym` named, resolved against the image's symbol
/// table. A missing name goes to the instruction budget, as `--stop-sym` does.
fn resolveBreak(image: elf.Image, options: cli.Options) ?breakpoint.Break {
    const spec = options.break_place orelse return null;
    return breakpoint.resolve(image, spec, options.break_arrival) catch |err| {
        std.debug.print("--break-sym {s}: {s}\n", .{ spec, @errorName(err) });
        return null;
    };
}

/// The counter `--stop-sym` named, resolved against the image's symbol
/// table. A name the image does not carry is reported and the run goes to
/// its instruction budget instead: a missing symbol is the suite's own
/// verdict to make, not a reason to refuse the run.
fn resolveStop(image: elf.Image, options: cli.Options) ?stop_watch.Stop {
    const name = options.stop_symbol orelse return null;
    const address = symbols.addressOf(image, name) orelse {
        std.debug.print("--stop-sym {s} not found in symbol table\n", .{name});
        return null;
    };
    return .{ .address = address, .reaches = options.stop_at };
}

/// Put the world the command line described onto the board: the part it is,
/// the card in its slot, the contacts queued on its panel, the charge in
/// its cell and the stick in its USB jack. Each piece refuses on its own
/// terms and says so; this only puts them in order.
fn fitBoard(board: *Board, allocator: std.mem.Allocator, options: cli.Options) !void {
    board.part = options.part;
    board.memory_monitors = .{ .cms = options.cms, .sfs = options.sfs };
    board.wire.click = options.click;
    board.asks.keep(allocator, options.attaches[0..options.attach_count]);
    if (options.usb_loop) board.usb.loopBack();
    board.capture.source = options.camera.open();
    try card_setup.prepare(board, options.trace_sd, options.sd_path, options.sd_size_mb, options.sd_new, options.sd_label);
    queueTouches(board, options);
    if (options.touch_in) |path| try board.touch_input.open(path);
    try setBattery(board, options);
    try ra8.board.usb_plug.apply(&board.usb, allocator, options.usb_disk);
}

/// Put the contacts the command line asked for on the touch panel. The queue
/// is the same depth as the flag allows, so nothing here can overflow it.
fn queueTouches(board: *Board, options: cli.Options) void {
    for (options.touches[0..options.touch_count]) |contact| {
        board.wire.panel.queue(contact) catch return;
    }
}

/// Tell the fuel gauge what is in the battery. A state-of-charge over full
/// is refused here rather than clamped into a number nothing measured.
fn setBattery(board: *Board, options: cli.Options) !void {
    board.wire.gauge.setBattery(options.battery) catch |err| {
        std.debug.print("--battery {d}: not a state-of-charge a cell can hold\n", .{options.battery.soc_pct});
        return err;
    };
}

/// The file behind `path`, or a printed complaint and the error that caused
/// it. The bytes outlive the file and are owned by the caller's arena.
/// CPU1 on CPU0's board: shared RAM through `start`, shared peripheral bus through the board's own attach.
fn readImage(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("cannot open {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer file.close();
    return file.readToEndAlloc(allocator, 64 * 1024 * 1024);
}

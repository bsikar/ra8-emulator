//! ra8_emulator: the RA8D2 board emulator (#14, the Zig rewrite).
//!
//! This file is wiring and nothing else: read an ELF, build the board, reset
//! out of the vector table, run a bounded number of instructions, and say
//! what happened. The machine lives in src/core, the blocks that answer on
//! the peripheral bus in src/periph, the board holding them and the words
//! about them in src/board, all reached through the "ra8" module.
const std = @import("std");
const ra8 = @import("ra8");

const cli = ra8.core.cli;
const elf = ra8.core.elf;
const symbols = ra8.core.symbols;
const undefined_ops = ra8.core.undefined_ops;
const stop_watch = ra8.core.stop;
const deadline = ra8.core.deadline;
const engine = ra8.core.engine;
const second_core = ra8.core.second_core;
const lob = ra8.core.lob;
const clocks = ra8.periph.clocks;
const sd_format = ra8.periph.sd_format;
const sd_advice = ra8.periph.sd_format_advice;
const breakpoint = ra8.core.breakpoint;
const watchpoint = ra8.core.watchpoint;
const taken_in = ra8.core.taken_in;
const mem_dump = ra8.core.mem_dump;
const registers = ra8.core.registers;
const sd_dump = ra8.periph.sd_dump;
const sd_image = ra8.periph.sd_image;
const nvic = ra8.periph.nvic;
const Board = ra8.board.Board;
const report = ra8.board.report;
const report_steps = ra8.board.report_steps;
const report_run = ra8.board.report_run;
const report_dumps = ra8.board.report_dumps;
const report_hotspots = ra8.board.report_hotspots;
const report_timing = ra8.board.report_timing;

/// Read the image off disk and parse it, saying which of the two failed.
fn openImage(allocator: std.mem.Allocator, path: []const u8) !elf.Image {
    const bytes = try readImage(allocator, path);
    return elf.Image.init(bytes) catch |err| {
        std.debug.print("{s} is not a loadable image: {s}\n", .{ path, @errorName(err) });
        return err;
    };
}

/// Everything that has to be hooked onto the core before the image runs,
/// and the image itself, which is loaded in the middle of it.
///
/// The order matters in one place and not the rest: the Non-Secure world's
/// BLXNS is found by reading the bytes as loaded, so `attachWorlds` has to
/// follow `loadImage`. Everything else is independent, and the caller owns
/// all of it, which is why each piece arrives as a pointer and the count
/// of bytes written goes back.
/// The pieces a run hangs on the core before it starts and reads back
/// once it has stopped. One struct rather than six locals because that is
/// what they are: every one of them is attached in the same breath and
/// reported on in the same breath.
const Parts = struct {
    watch: engine.Watch = .{},
    loops: lob.Loops = .{},
    selects: ra8.core.csel.Selects = .{},
    worlds: ra8.core.tz.Worlds = .{},
    idle: ra8.core.idle.Seam = .{},
    release: ra8.core.unmask.Release = .{},
    pcs: ra8.core.hotspots.Table = .{},
    fns: ?ra8.core.functions.Table = null,
    taken: ra8.core.tally.Tally = .{},
    timebase: clocks.Clocks = .{},
};

fn attachAll(core: *engine.Engine, image: elf.Image, parts: *Parts) !u32 {
    try core.attachWatch(&parts.watch);
    try core.attachLoops(&parts.loops);
    try core.attachSelects(&parts.selects);
    try core.attachIdle(&parts.idle);
    try core.attachTimebase(&parts.timebase);
    const written = try core.loadImage(image);
    try core.attachWorlds(image, &parts.worlds);
    return written;
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const argv = try std.process.argsAlloc(allocator);
    const options = cli.parse(argv) catch {
        std.debug.print("{s}", .{cli.usage});
        return 2;
    };

    const image = openImage(allocator, options.path) catch return 1;

    var core = try engine.Engine.open();
    defer core.close();
    try core.mapBoardRam();

    var board = Board.init(allocator);
    defer board.deinit();
    fitBoard(&board, options) catch return 2;
    try board.attach(&core);

    var parts = Parts{};
    const written = try attachAll(&core, image, &parts);

    const vector_base = image.vectorBase() orelse {
        std.debug.print("no executable segment, nothing to reset into\n", .{});
        return 1;
    };
    try core.resetFromVectorTable(vector_base);
    const entry = try core.register(.pc);
    var out = std.io.getStdOut().writer();
    try out.print("loaded {d} bytes, vectors at 0x{X:0>8}, sp 0x{X:0>8}, pc 0x{X:0>8}\n", .{ written, vector_base, try core.register(.sp), entry });

    var interrupts = nvic.Nvic{ .vector_base = vector_base };
    var reboot = ra8.core.reboot.Reboot{ .vector_base = vector_base };
    board.reboot = &reboot;
    var stop = resolveStop(image, options);
    var point = resolveBreak(image, options);
    if (point) |*one| try core.attachBreak(one);
    var watched = watchpoint.resolve(image, options.watch_place);
    if (watched) |*one| try core.attachWatchpoint(one);
    var window = taken_in.resolve(image, options.taken_in_place);
    var undefined_found = undefined_ops.sweep(image);
    if (options.stop_on_undefined) undefined_found.stopOnRun();
    try core.attachUndefined(&undefined_found);
    var storage: second_core.Second = undefined;
    var timed = resolveDeadline(options);
    const second = second_core.start(allocator, &core, &board, options.cpu1_path, &storage) catch |err| {
        std.debug.print("cannot bring up the second core from {s}: {s}\n", .{ options.cpu1_path orelse "?", @errorName(err) });
        return 1;
    };
    defer if (second) |one| one.close();
    const budget = options.budgetFor(stop != null);
    parts.fns = .{ .image = image };
    const fault = try second_core.interleave(core, entry, budget, .{
        .watch = &parts.watch,
        .timebase = &parts.timebase,
        .interrupts = &interrupts,
        .board = board.ticker(),
        .reboot = &reboot,
        .protection = &board.guard,
        .stop = if (stop) |*one| one else null,
        .brk = if (point) |*one| one else null,
        .undefined_sites = if (options.stop_on_undefined) &undefined_found else null,
        .deadline = if (timed) |*one| one else null,
        .idle = &parts.idle,
        .unmask = &parts.release,
        .pcs = &parts.pcs,
        .fns = &parts.fns.?,
        .taken_from = &parts.taken,
        .taken_in = if (window) |*one| one else null,
        .per_boundary = options.chunk_instructions,
    }, second);

    try reportAll(out, core, &board, image, options, .{ .timebase = parts.timebase, .idle = parts.idle, .release = parts.release, .interrupts = interrupts, .reboot = reboot, .loops = parts.loops, .selects = parts.selects, .worlds = parts.worlds, .undefined_found = undefined_found }, parts, second, watched, window);
    return verdict(out, core, options, fault, stop, point, timed, budget);
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
) !void {
    try report_run.all(out, board, image, run);
    try report_hotspots.spent(out, image, parts.pcs);
    try report_hotspots.spentIn(out, image, parts.fns.?);
    try report_timing.takenFrom(out, image, parts.taken);
    try report_timing.takenIn(out, image, options.taken_in_place, window);
    try second_core.report(out, second);
    try report_dumps.dumps(out, core, image, options, board, watched);
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
) !u8 {
    if (fault) |taken| {
        try report.fault(out, taken);
        return 1;
    }
    const pc = try core.register(.pc);
    if (point) |arrived| return arrivals(out, options, arrived, pc, budget);
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
/// the card in its slot, the contacts queued on its panel and the charge in
/// its cell. Each piece refuses on its own terms and says so; this only puts
/// them in order.
fn fitBoard(board: *Board, options: cli.Options) !void {
    board.part = options.part;
    try prepareCard(board, options);
    queueTouches(board, options);
    try setBattery(board, options);
}

/// Size and format the card on the SPI line, when the command line asked for
/// it. A card that cannot carry the volume it was asked for is refused here
/// rather than stamped with a BPB that contradicts it.
fn prepareCard(board: *Board, options: cli.Options) !void {
    board.sd.trace = options.trace_sd;
    if (options.sd_size_mb) |megabytes| {
        const blocks = megabytes *| (1024 * 1024 / sd_image.geometry.block_bytes);
        if (!board.sd.img.resize(blocks)) {
            std.debug.print("--sd-size {d}: not a card size this model can state exactly\n", .{megabytes});
            return error.BadCardSize;
        }
    }
    const kind = options.sd_new orelse return;
    board.sd_volume = sd_format.apply(&board.sd.img, kind, options.sd_label) catch |err| {
        std.debug.print("--sd-new {s}: {s}\n", .{ kind.text(), @errorName(err) });
        sd_advice.printRemedy(kind, err);
        return err;
    };
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

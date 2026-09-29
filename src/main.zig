//! ra8_emulator: the RA8D2 board emulator (#14, the Zig rewrite).
//!
//! This file is wiring and nothing else: read an ELF, build the board, reset
//! out of the vector table, run a bounded number of instructions, and say
//! what happened. The machine lives in src/core, every block that answers on
//! the peripheral bus lives in src/periph, the board that holds them and the
//! words about them live in src/board, and all of it is reached through the
//! "ra8" module.
const std = @import("std");
const ra8 = @import("ra8");

const cli = ra8.core.cli;
const elf = ra8.core.elf;
const symbols = ra8.core.symbols;
const stop_watch = ra8.core.stop;
const deadline = ra8.core.deadline;
const engine = ra8.core.engine;
const lob = ra8.core.lob;
const clocks = ra8.periph.clocks;
const sd_format = ra8.periph.sd_format;
const breakpoint = ra8.core.breakpoint;
const mem_dump = ra8.core.mem_dump;
const registers = ra8.core.registers;
const sd_dump = ra8.periph.sd_dump;
const sd_image = ra8.periph.sd_image;
const nvic = ra8.periph.nvic;
const Board = ra8.board.Board;
const report = ra8.board.report;
const report_steps = ra8.board.report_steps;

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const argv = try std.process.argsAlloc(allocator);
    const options = cli.parse(argv) catch {
        std.debug.print("{s}", .{cli.usage});
        return 2;
    };

    const bytes = readImage(allocator, options.path) catch return 1;
    const image = elf.Image.init(bytes) catch |err| {
        std.debug.print("{s} is not a loadable image: {s}\n", .{ options.path, @errorName(err) });
        return 1;
    };

    var core = try engine.Engine.open();
    defer core.close();
    try core.mapBoardRam();

    var board = Board.init(allocator);
    defer board.deinit();
    fitBoard(&board, options) catch return 2;
    try board.attach(&core);

    var watch = engine.Watch{};
    try core.attachWatch(&watch);
    var loops = lob.Loops{};
    try core.attachLoops(&loops);
    var selects = ra8.core.csel.Selects{};
    try core.attachSelects(&selects);
    const written = try core.loadImage(image);

    const vector_base = image.vectorBase() orelse {
        std.debug.print("no executable segment, nothing to reset into\n", .{});
        return 1;
    };
    try core.resetFromVectorTable(vector_base);

    const stack_pointer = try core.register(.sp);
    const entry = try core.register(.pc);
    var out = std.io.getStdOut().writer();
    try out.print("loaded {d} bytes, vectors at 0x{X:0>8}, sp 0x{X:0>8}, pc 0x{X:0>8}\n", .{ written, vector_base, stack_pointer, entry });

    var timebase = clocks.Clocks{};
    var interrupts = nvic.Nvic{ .vector_base = vector_base };
    var reboot = ra8.core.reboot.Reboot{ .vector_base = vector_base };
    board.reboot = &reboot;
    var stop = resolveStop(image, options);
    var point = resolveBreak(image, options);
    if (point) |*one| try core.attachBreak(one);
    var timed = resolveDeadline(options);
    const budget = options.budgetFor(stop != null);
    const fault = try core.run(entry, budget, .{
        .watch = &watch,
        .timebase = &timebase,
        .interrupts = &interrupts,
        .board = board.ticker(),
        .reboot = &reboot,
        .protection = &board.guard,
        .stop = if (stop) |*one| one else null,
        .brk = if (point) |*one| one else null,
        .deadline = if (timed) |*one| one else null,
    });

    try report.bus(&board, out);
    try report.timing(out, timebase, interrupts);
    try report.reboots(out, reboot);
    try report_steps.loops(out, loops);
    try report_steps.selects(out, selects);
    try report.blocks(&board, out);
    try dumpSymbols(out, core, image, options);
    try dumpBlock(out, &board, options);
    try dumpRegisters(out, core, options);
    try mem_dump.print(out, core, image, options.dump_mem, options.dump_mem_words);
    return verdict(out, core, options, fault, stop, point, timed, budget);
}

/// The core registers as the run left them, when `--dump-regs` asked.
///
/// At a break this is the function's own call boundary, so r0-r3 and the
/// words at the stack pointer are still its arguments. A register the
/// core refuses to hand back is printed as unreadable rather than as a
/// zero that would read like a real value.
fn dumpRegisters(out: anytype, core: engine.Engine, options: cli.Options) !void {
    if (!options.dump_regs) return;
    try out.print("  dump-regs     :", .{});
    for (registers.dumped, 0..) |named, index| {
        if (core.register(named.which)) |value| {
            try out.print(" {s} 0x{X:0>8}", .{ named.name, value });
        } else |_| {
            try out.print(" {s} <unreadable>", .{named.name});
        }
        if (registers.endsLine(index)) try out.print("\n                 ", .{});
    }
    const sp = core.register(.sp) catch return out.print("sp unreadable\n", .{});
    for (0..registers.limits.stack_words) |index| {
        const at = registers.stackWord(sp, index);
        if (core.readWord(at)) |value| {
            try out.print(" [sp+{d}] 0x{X:0>8}", .{ index * 4, value });
        } else |_| {
            try out.print(" [sp+{d}] <unreadable>", .{index * 4});
        }
    }
    try out.print("\n", .{});
}

/// One card block back as hex, when `--dump-sd` asked for it.
///
/// Rows of nothing but zeros are dropped: a block of a freshly formatted
/// volume is mostly zeros, and the few rows carrying a directory entry or a
/// boot field are the whole reason to look. The count of dropped rows is
/// printed so a reader can tell an elided block from a short one.
fn dumpBlock(out: anytype, board: anytype, options: cli.Options) !void {
    const index = options.dump_sd orelse return;
    var block: sd_image.Block = undefined;
    if (!board.sd.img.read(index, &block)) {
        try out.print("  dump-sd       : block {d} is not on this card\n", .{index});
        return;
    }
    try out.print("  dump-sd       : block {d} (0x{X})\n", .{ index, index });
    var offset: usize = 0;
    var dropped: usize = 0;
    while (offset < block.len) : (offset += sd_dump.row_bytes) {
        const end = @min(offset + sd_dump.row_bytes, block.len);
        const bytes = block[offset..end];
        if (sd_dump.blank(bytes)) {
            dropped += 1;
            continue;
        }
        var buf: sd_dump.Buffer = undefined;
        try out.print("{s}\n", .{sd_dump.row(&buf, offset, bytes)});
    }
    if (dropped > 0) try out.print("  dump-sd       : {d} zero row(s) not shown\n", .{dropped});
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
            .{ options.break_symbol.?, point.seen, pc },
        );
        return 0;
    }
    try out.print(
        "ran {d} instructions, reached {s} {d} time(s) of {d}, pc 0x{X:0>8}\n",
        .{ budget, options.break_symbol.?, point.seen, point.arrival, pc },
    );
    return 0;
}

/// The function `--break-sym` named, resolved against the image's symbol
/// table. A name the image does not carry is reported and the run goes to
/// its instruction budget, the same way a missing `--stop-sym` does.
/// The modelled-time window a run is allowed, or none.
fn resolveDeadline(options: cli.Options) ?deadline.Deadline {
    const milliseconds = options.ms orelse return null;
    return .{ .periods = milliseconds };
}

fn resolveBreak(image: elf.Image, options: cli.Options) ?breakpoint.Break {
    const name = options.break_symbol orelse return null;
    const address = symbols.addressOf(image, name) orelse {
        std.debug.print("--break-sym {s} not found in symbol table\n", .{name});
        return null;
    };
    return .{ .address = address, .arrival = options.break_arrival };
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

/// Read each `--dump-sym` global out of RAM and print it.
///
/// The shape of the line is load-bearing: the firmware's own
/// emulator-in-the-loop suite parses it with a regex over
/// "dump-sym : <name> @0x<addr> = <decimal> ", so the name, the address,
/// the decimal value and something after it all have to be there. A symbol
/// the image does not carry, or an address that will not read, says so
/// plainly instead of printing a number nothing measured.
fn dumpSymbols(out: anytype, core: engine.Engine, image: elf.Image, options: cli.Options) !void {
    for (options.dumps()) |name| {
        const address = symbols.addressOf(image, name) orelse {
            try out.print("  dump-sym      : {s} <unresolved>\n", .{name});
            continue;
        };
        const value = core.readWord(address) catch {
            try out.print("  dump-sym      : {s} @0x{X:0>8} <unreadable>\n", .{ name, address });
            continue;
        };
        try out.print(
            "  dump-sym      : {s} @0x{X:0>8} = {d} (0x{X:0>8})\n",
            .{ name, address, value, value },
        );
    }
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
fn readImage(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("cannot open {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer file.close();
    return file.readToEndAlloc(allocator, 64 * 1024 * 1024);
}

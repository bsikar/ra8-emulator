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
const engine = ra8.core.engine;
const lob = ra8.core.lob;
const clocks = ra8.periph.clocks;
const nvic = ra8.periph.nvic;
const Board = ra8.board.Board;
const report = ra8.board.report;

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
    board.part = options.part;
    try board.attach(&core);

    var watch = engine.Watch{};
    try core.attachWatch(&watch);
    var loops = lob.Loops{};
    try core.attachLoops(&loops);
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
    const fault = try core.run(entry, options.instructions, .{
        .watch = &watch,
        .timebase = &timebase,
        .interrupts = &interrupts,
        .board = board.ticker(),
        .reboot = &reboot,
    });

    try report.bus(&board, out);
    try report.timing(out, timebase, interrupts);
    try report.reboots(out, reboot);
    try report.loops(out, loops);
    try report.blocks(&board, out);
    if (fault) |taken| {
        try report.fault(out, taken);
        return 1;
    }
    try out.print("ran {d} instructions clean, pc 0x{X:0>8}\n", .{ options.instructions, try core.register(.pc) });
    return 0;
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

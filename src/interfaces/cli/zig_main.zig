//! Every run from main, on the Zig core
//! (RA8EMU-592, slice 4e-2 of RA8EMU-481).
//!
//! CPU0 goes on its own store (src/interfaces/cli/zig_memory.zig), the
//! opening line reads SP and the reset vector off that store, option memory
//! is read from it, and src/interfaces/cli/zig_run.zig gets no engine.
const std = @import("std");
const elf = @import("../../core/elf.zig");
const Guest = @import("../../core/cpu/memory/guest.zig").Guest;
const Reboot = @import("../../core/reboot.zig").Reboot;
const Board = @import("../../board/board.zig").Board;
const option_memory = @import("../../board/option_memory.zig");
const cli = @import("cli.zig");
const Parts = @import("parts.zig").Parts;
const report = @import("report.zig");
const zig_run = @import("zig_run.zig");
const fault_file = @import("fault_file.zig");
const window_main = @import("window_main.zig");
const Cpu0 = @import("zig_memory.zig").Cpu0;

/// Fitting the board is shared with main's engine path.
pub const fit = @import("board_fit.zig").fit;
const fit_verdict = @import("board_fit.zig").tapeVerdict;

/// The whole run, in the order main's engine path takes it: fit the board,
/// load, announce, then run on the Zig core.
pub fn run(allocator: std.mem.Allocator, io: std.Io, image: elf.Image, options: cli.Options) !u8 {
    var board = Board.init(allocator);
    defer board.deinit();
    fit(&board, allocator, io, options) catch return 2;
    defer cli.card_setup.saveBack(&board, io, options.sd_path, options.sd_save);
    defer cli.card_setup.saveSdhi(&board, io, options.sdhi);
    var cpu0: Cpu0 = .{};
    defer cpu0.close();
    var parts = Parts{};
    const written = try prepare(&cpu0, &board, io, image, &parts, options);
    if (options.ns_path) |path| loadNonSecure(allocator, &cpu0, path) catch return 1;
    const vector_base = vectorBase(image) catch return 1;
    const memory = cpu0.own();
    const out = try announce(memory, written, vector_base, options.ctl_cpu_load);
    var reboot = Reboot{ .vector_base = vector_base };
    board.reboot = &reboot;
    const table = if (parts.profile) |*one| one else null;
    var stop = zig_run.stop_sym.resolve(image, options);
    var point = zig_run.break_sym.resolve(image, options);
    var timed = zig_run.stop_sym.deadline(options);
    var swept = zig_run.undefined_sites.resolve(image, options);
    var schedule: fault_file.Run = undefined;
    if (options.faults) |path| schedule.open(&board, path) catch return 2;
    defer if (options.faults != null) schedule.deinit();
    const ends: zig_run.Ends = .{
        .stop = if (stop) |*watch| watch else null,
        .point = if (point) |*one| one else null,
        .timed = if (timed) |*due| due else null,
        .undefined_sites = if (swept) |*found| found else null,
        .schedule = if (options.faults != null) &schedule.applier else null,
    };
    if (options.frames.live) return fit_verdict(&board, try window_main.show(allocator, .{ .io = io, .out = out, .memory = memory, .board = &board, .timebase = &parts.timebase, .image = image, .options = options, .vector_base = vector_base, .profile_table = table, .until = parts.tap.waiting(), .ends = ends }));
    return fit_verdict(&board, try zig_run.run(out, io, memory, &board, &parts.timebase, image, options, vector_base, table, parts.tap.waiting(), ends));
}

/// CPU0's store, the console tap, the profile table and option memory: what
/// main's `loadAll` sets up that a Zig run reads. Returns the bytes loaded.
pub fn prepare(cpu0: *Cpu0, board: *Board, io: std.Io, image: elf.Image, parts: *Parts, options: cli.Options) !u32 {
    const written = try cpu0.attachStore(board, image);
    if (options.console) board.console_input.enabled = true;
    board.console_input.reply = options.console_reply;
    parts.tap = .{ .echo = if (options.console) io else null, .wait = if (options.until) |text| .{ .needle = text } else null };
    if (options.console_reply.armed()) parts.tap.reply = &board.console_input.reply;
    cli.console_output.configure(&board.serial.line, &parts.tap);
    if (options.profile) parts.prepareProfile(image);
    option_memory.apply(board, cpu0.own());
    if (!options.ctl_cpu_load) _ = try report.frames_out.Armed.armForCli(std.heap.page_allocator, board, options.frames);
    return written;
}

/// Where the image's vector table is, or a printed complaint when it has
/// no executable segment to reset into. Shared with main's engine path.
pub fn vectorBase(image: elf.Image) error{NoVectors}!u32 {
    return image.vectorBase() orelse {
        std.debug.print("no executable segment, nothing to reset into\n", .{});
        return error.NoVectors;
    };
}

/// A TrustZone build's Non-Secure half (`--ns`), beside the main image.
fn loadNonSecure(allocator: std.mem.Allocator, cpu0: *Cpu0, path: []const u8) !void {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("cannot open {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    const ns = elf.Image.init(bytes) catch |err| {
        std.debug.print("{s} is not a loadable image: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    try cpu0.load(ns);
}

/// The opening line, read off the store the way the engine's reset read it:
/// SP from the vector table, PC from the reset vector with its Thumb bit off.
pub fn announce(memory: Guest, written: u32, vector_base: u32, quiet: bool) !std.fs.File.Writer {
    const out = std.io.getStdOut().writer();
    if (quiet) return out;
    const sp = try memory.readWord(vector_base);
    const pc = (try memory.readWord(vector_base + 4)) & ~@as(u32, 1);
    try out.print("loaded {d} bytes, vectors at 0x{X:0>8}, sp 0x{X:0>8}, pc 0x{X:0>8}\n", .{ written, vector_base, sp, pc });
    return out;
}

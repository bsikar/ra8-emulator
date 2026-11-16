//! A `--cpu zig` run started from main, with the board's time wired in. This
//! charges SysTick, DWT_CYCCNT and the blocks at every chunk boundary, the
//! same boundary, so a ThreadX image gets its tick and the peripherals that
//! count time (the USB host script among them) move.
const run_report = @import("run_report.zig");
const session = @import("ra8_session");

const std = @import("std");

const audio_out = @import("../audio_out.zig");
const Board = @import("ra8_board").board.Board;
const board_wiring = @import("ra8_board").wiring;
const cli = @import("../cli.zig");
const clocks = @import("ra8_chip").periph.clocks;
const eink_log = @import("../eink_log.zig");
const elf = @import("ra8_board").image.elf;
const file_ops = @import("ra8_session").file_ops;
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const profile = @import("ra8_session").profile;
const rtos_hook = @import("ra8_session").rtos.hook;
const run_loop = @import("ra8_session").run.loop;
const second_core = @import("ra8_chip").core.second.core;
const session_files = @import("ra8_host").session_files;

/// `--watch` on a Zig run: src/session/zig/watch.zig.
const Until = @import("ra8_chip").core.until.Until;
pub const zig_watch = @import("ra8_session").zig.watch;

/// The `--stop-sym` counter a Zig run watches: src/session/zig.stop.zig.
pub const stop_sym = @import("ra8_session").zig.stop;

/// Re-exported for tests/session/itm_console_test.zig: cli.zig is full.
pub const itm_console = @import("ra8_session").itm_console;

/// The `--break-sym` arrival a Zig run counts: src/session/zig.break_sym.zig.
pub const break_sym = @import("ra8_session").zig.break_sym;

/// `--stop-on-undefined` on a Zig run: src/session/zig.undefined_sites.zig.
pub const undefined_sites = @import("ra8_session").zig.undefined_sites;

/// `--save-state` / `--load-state` (RA8EMU-696).
pub const state_args = @import("../state_args.zig");
pub const zig_snapshot = @import("ra8_session").zig.snapshot;

/// What ends a Zig run before its budget: src/session/run/loop.zig.
pub const Ends = run_loop.Ends;
/// A `--cpu zig` run from main, with no engine opened: RA8EMU-592.
pub const main_path = @import("main.zig");

const BootWriter = run_report.BootWriter;

pub const Clock = run_loop.Clock;

/// Run, then print what the board has to say.
/// `memory` is CPU0's store (RA8EMU-577); no engine is opened (RA8EMU-607).
pub fn run(
    out: *std.Io.Writer,
    io: std.Io,
    memory: Guest,
    board: *Board,
    timebase: *clocks.Clocks,
    image: elf.Image,
    options: cli.Options,
    vector_base: u32,
    profile_table: ?*profile.Table,
    until: ?*Until,
    ends: Ends,
) !u8 {
    var pair: second_core.zig.run.Driver = undefined;
    var cpu1: ?*second_core.zig.run.Driver = null;
    var cpu1_identity: ?[16]u8 = null;
    const host_files = options.state.files orelse session_files.cwd(file_ops.Ops);
    var second_tracers: rtos_hook.second.Tracers = .{};
    if (if (options.cpu == .zig) options.cpu1_path else null) |named| {
        cpu1_identity = openSecond(&pair, io, board, named, memory, options.blocks, host_files.reader) orelse return 1;
        cpu1 = &pair;
        rtos_hook.second.armZig(&pair, io, host_files.reader, options.rtosWanted(), named, &second_tracers);
    }
    defer if (cpu1) |second| second.close();
    var loop: run_loop.Loop = .{};
    var loop_open = false;
    defer if (loop_open) loop.clock.deinitSnapshot();
    var eink_recorder = eink_log.Run.init(std.heap.page_allocator, board);
    if (options.frames.eink_log != null) eink_recorder.arm();
    defer eink_recorder.deinit();
    var audio: audio_out.Run = .{};
    audio.arm(board, if (options.cpu == .zig) options.audio else .{});
    defer audio.deinit();
    const budget = options.budgetFor(ends.stop != null);
    loop_open = true;
    try loop.run(
        BootWriter{ .output = out, .quiet = options.ctl_cpu_load },
        out,
        io,
        memory,
        board,
        timebase,
        image,
        loopOptions(options, budget),
        vector_base,
        profile_table,
        until,
        cpu1,
        cpu1_identity,
        ends,
    );
    return run_report.afterRun(
        out,
        io,
        board,
        image,
        options,
        profile_table,
        ends,
        budget,
        &loop,
        host_files.writer,
        &second_tracers,
        &eink_recorder,
        &audio,
    );
}

/// The loop's options, read off the CLI's.
fn loopOptions(options: cli.Options, budget: usize) run_loop.Options {
    var state = options.state;
    if (state.wanted() and state.files == null) state.files = session_files.cwd(file_ops.Ops);
    return .{
        .cpu = options.cpu,
        .blocks = options.blocks,
        .rtos = options.rtosWanted(),
        .watch_place = options.watch_place,
        .idle_skip = options.idle_skip,
        .state = state,
        .console = options.console,
        .bus_errors = options.bus_errors,
        .budget = budget,
    };
}

/// Bring CPU1 up from `named`, with its block cache when asked; false once
/// the reason it could not is printed.
fn openSecond(
    pair: *second_core.zig.run.Driver,
    io: std.Io,
    board: *Board,
    named: []const u8,
    memory: Guest,
    blocks: bool,
    reader: file_ops.Reader,
) ?[16]u8 {
    const identity = session.cpu1.image.openIdentified(
        pair,
        std.heap.page_allocator,
        io,
        reader,
        board_wiring.cpu1(board),
        named,
        memory,
    ) catch |err| {
        std.debug.print("cannot bring up the second core from {s}: {s}\n", .{ named, @errorName(err) });
        return null;
    };
    if (blocks) pair.core.useBlocks() catch |err| {
        pair.close();
        std.debug.print("cannot give the second core its block cache: {s}\n", .{@errorName(err)});
        return null;
    };
    return identity;
}

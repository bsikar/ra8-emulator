//! The debugger's front end: `--debug-script FILE` and `--debug`.
//!
//! ```
//! ra8_emulator firmware.elf --debug-script session.gdb
//! ra8_emulator firmware.elf --debug
//! ```
//!
//! The first plays a script and prints its transcript, each command echoed
//! behind the prompt. The second reads commands from the terminal until
//! `quit` or end of input. Both load the image onto the board, reset out of
//! its vector table, and hand the core to a debugger session; `run` starts
//! from the reset handler. Either flag takes over the whole invocation, so
//! neither mixes with the run-and-report flags.
//!
//! The session steps the core on its own, without the run loop that drives
//! SysTick and the interrupt controller, so firmware that waits on an
//! interrupt waits forever here. Bringing the run loop under the session is
//! the next step for this front end.
const std = @import("std");
const cli = @import("cli.zig");
const elf = @import("../../core/elf.zig");
const engine = @import("../../core/engine.zig");
const Board = @import("../../board/board.zig").Board;
const script = @import("../../debug/script.zig");
const session = @import("../../debug/session.zig");
const step_hook = @import("../../debug/step_hook.zig");
const stop_machine = @import("../../debug/stop_machine.zig");

pub const usage =
    \\usage: ra8_emulator <firmware.elf> --debug-script FILE
    \\       ra8_emulator <firmware.elf> --debug
    \\
;

pub const limits = struct {
    /// The largest image or script read in. Firmware images here run to a
    /// few megabytes with their debug sections.
    pub const max_file: usize = 64 * 1024 * 1024;
    /// The longest command line read from the terminal.
    pub const max_line: usize = 1024;
};

pub const Mode = union(enum) {
    script: []const u8,
    interactive,
};

/// The debugger mode the command line asks for, or null when it asks for
/// an ordinary run. A malformed debugger command line is reported as such
/// rather than handed to the ordinary parser.
pub fn wanted(argv: []const []const u8) ?error{BadUsage}!Mode {
    for (argv, 0..) |arg, index| {
        const is_script = std.mem.eql(u8, arg, "--debug-script");
        const is_interactive = std.mem.eql(u8, arg, "--debug");
        if (!is_script and !is_interactive) continue;
        if (index != 2) return error.BadUsage;
        if (is_interactive) return if (argv.len == 3) .interactive else error.BadUsage;
        if (argv.len != 4) return error.BadUsage;
        return .{ .script = argv[3] };
    }
    return null;
}

/// A command line the run parser refused. The debugger flags are not run
/// flags, so a debugger invocation lands here: run it, print the
/// debugger's usage when it is malformed, or the run usage when it was
/// never a debugger invocation at all.
pub fn refused(allocator: std.mem.Allocator, argv: []const []const u8) !u8 {
    const asked = wanted(argv) orelse {
        std.debug.print("{s}", .{cli.usage});
        return 2;
    };
    const mode = asked catch {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    return run(allocator, argv, mode);
}

/// Load the image, open a session on CPU0 and run the mode asked for.
pub fn run(allocator: std.mem.Allocator, argv: []const []const u8, mode: Mode) !u8 {
    const bytes = std.fs.cwd().readFileAlloc(allocator, argv[1], limits.max_file) catch |err| {
        std.debug.print("cannot read {s}: {s}\n", .{ argv[1], @errorName(err) });
        return 1;
    };
    const image = elf.Image.init(bytes) catch |err| {
        std.debug.print("{s} is not a loadable image: {s}\n", .{ argv[1], @errorName(err) });
        return 1;
    };
    var core = try engine.Engine.open();
    defer core.close();
    try core.mapBoardRam();
    var board = Board.init(allocator);
    defer board.deinit();
    try board.attach(&core);
    _ = try core.loadImage(image);
    const vector_base = image.vectorBase() orelse {
        std.debug.print("no executable segment, nothing to reset into\n", .{});
        return 1;
    };
    try core.resetFromVectorTable(vector_base);
    var machine = stop_machine.Machine{};
    var driver = step_hook.Driver{ .machine = &machine };
    try step_hook.attach(core.handle, &driver, true);
    var target = session.Session{ .core = &core, .driver = &driver, .entry = try core.register(.pc), .image = image };
    const out = std.io.getStdOut().writer();
    switch (mode) {
        .script => |path| {
            const text = std.fs.cwd().readFileAlloc(allocator, path, limits.max_file) catch |err| {
                std.debug.print("cannot read {s}: {s}\n", .{ path, @errorName(err) });
                return 1;
            };
            _ = try script.play(&target, text, out, true);
        },
        .interactive => try converse(&target, out),
    }
    return 0;
}

/// Prompt, read a line, apply it, until `quit` or the end of input.
fn converse(target: *session.Session, out: anytype) !void {
    const input = std.io.getStdIn().reader();
    var buffer: [limits.max_line]u8 = undefined;
    while (true) {
        try out.print("{s}", .{script.prompt});
        const line = input.readUntilDelimiterOrEof(&buffer, '\n') catch |err| switch (err) {
            error.StreamTooLong => {
                try input.skipUntilDelimiterOrEof('\n');
                try out.print("error: LineTooLong\n", .{});
                continue;
            },
            else => return err,
        } orelse return out.print("\n", .{});
        if (try script.one(target, line, out, false) == .quit) return;
    }
}

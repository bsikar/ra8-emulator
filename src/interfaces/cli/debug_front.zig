//! The debugger's front end: `--debug-script FILE` and `--debug`.
//!
//! ```
//! ra8_emulator firmware.elf [--cpu1 IMAGE.elf] --debug-script session.gdb
//! ra8_emulator firmware.elf [--cpu1 IMAGE.elf] --debug
//! ```
//!
//! The first plays a script and prints its transcript, each command echoed
//! behind the prompt. The second reads commands from the terminal until
//! `quit` or end of input. Both load the image onto the board, reset out of
//! its vector table, and hand the core to a debugger session; `run` starts
//! from the reset handler. With `--cpu1`, the second core comes up on the
//! same board from its own image, the way an ordinary run brings it up,
//! and `core 1` selects it. Either flag takes over the whole invocation, so
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
const second_core = @import("../../core/second_core.zig");
const step_hook = @import("../../debug/step_hook.zig");
const stop_machine = @import("../../debug/stop_machine.zig");

pub const usage =
    \\usage: ra8_emulator <firmware.elf> [--cpu1 IMAGE.elf] --debug-script FILE
    \\       ra8_emulator <firmware.elf> [--cpu1 IMAGE.elf] --debug
    \\
;

pub const limits = struct {
    /// The largest image or script read in. Firmware images here run to a
    /// few megabytes with their debug sections.
    pub const max_file: usize = 64 * 1024 * 1024;
    /// The longest command line read from the terminal.
    pub const max_line: usize = 1024;
};

pub const flags = struct {
    pub const script = "--debug-script";
    pub const interactive = "--debug";
    pub const cpu1 = "--cpu1";
};

pub const Mode = union(enum) {
    script: []const u8,
    interactive,
};

/// What the debugger command line asked for.
pub const Request = struct {
    mode: Mode,
    /// The image the second core runs, when one was named.
    cpu1: ?[]const u8 = null,
};

/// The debugger request the command line makes, or null when it asks for
/// an ordinary run. A malformed debugger command line is reported as such
/// rather than handed to the ordinary parser.
pub fn wanted(argv: []const []const u8) ?error{BadUsage}!Request {
    const at = for (argv, 0..) |arg, index| {
        if (isDebugFlag(arg)) break index;
    } else return null;
    var request = Request{ .mode = .interactive };
    var index: usize = 2;
    if (index + 1 < argv.len and std.mem.eql(u8, argv[index], flags.cpu1)) {
        request.cpu1 = argv[index + 1];
        index += 2;
    }
    if (index != at) return error.BadUsage;
    if (std.mem.eql(u8, argv[at], flags.interactive)) {
        return if (argv.len == at + 1) request else error.BadUsage;
    }
    if (argv.len != at + 2) return error.BadUsage;
    request.mode = .{ .script = argv[at + 1] };
    return request;
}

fn isDebugFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, flags.script) or std.mem.eql(u8, arg, flags.interactive);
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
    const request = asked catch {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    return run(allocator, argv, request);
}

/// One CPU's stop machine and the hook driver feeding it. Kept in the
/// caller's frame, because the hook holds a pointer to the driver.
const Cpu = struct {
    machine: stop_machine.Machine = .{},
    driver: step_hook.Driver = undefined,

    fn attach(self: *Cpu, core: *const engine.Engine) !void {
        self.driver = .{ .machine = &self.machine };
        try step_hook.attach(core.handle, &self.driver, true);
    }
};

/// Load the images, open a session on CPU0 with CPU1 parked beside it when
/// one was named, and run the mode asked for.
pub fn run(allocator: std.mem.Allocator, argv: []const []const u8, request: Request) !u8 {
    const image = readImage(allocator, argv[1]) orelse return 1;
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
    var cpu0 = Cpu{};
    try cpu0.attach(&core);
    var target = session.Session{ .core = &core, .driver = &cpu0.driver, .entry = try core.register(.pc), .image = image };
    var second: second_core.Second = undefined;
    var cpu1 = Cpu{};
    if (request.cpu1) |path| {
        const image1 = readImage(allocator, path) orelse return 1;
        second.open(&core, &board, image1) catch |err| {
            std.debug.print("cannot bring up the second core from {s}: {s}\n", .{ path, @errorName(err) });
            return 1;
        };
        try cpu1.attach(&second.core);
        target.other = .{ .core = &second.core, .driver = &cpu1.driver, .entry = second.pc, .image = image1 };
    }
    defer if (request.cpu1 != null) second.close();
    return drive(allocator, &target, request.mode);
}

/// Play the script or talk to the terminal.
fn drive(allocator: std.mem.Allocator, target: *session.Session, mode: Mode) !u8 {
    const out = std.io.getStdOut().writer();
    switch (mode) {
        .script => |path| {
            const text = std.fs.cwd().readFileAlloc(allocator, path, limits.max_file) catch |err| {
                std.debug.print("cannot read {s}: {s}\n", .{ path, @errorName(err) });
                return 1;
            };
            _ = try script.play(target, text, out, true);
        },
        .interactive => try converse(target, out),
    }
    return 0;
}

/// An image read and checked, or null after saying why it could not be.
fn readImage(allocator: std.mem.Allocator, path: []const u8) ?elf.Image {
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, limits.max_file) catch |err| {
        std.debug.print("cannot read {s}: {s}\n", .{ path, @errorName(err) });
        return null;
    };
    return elf.Image.init(bytes) catch |err| {
        std.debug.print("{s} is not a loadable image: {s}\n", .{ path, @errorName(err) });
        return null;
    };
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

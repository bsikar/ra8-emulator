//! `--gui` from main (RA8EMU-646): the run goes on its own thread, paced
//! one 60 Hz frame of core time per window tick, and the window shows the
//! board until the run ends or the window closes. The caller hands in the
//! run as a `Runner` (RA8EMU-1074), so the window never reaches into an
//! engine or the command line.
const std = @import("std");
const Board = @import("../../board/board.zig").Board;
const request = @import("../../components/request.zig");
const source_spec = @import("../../host/camera/source_spec.zig");
const duration = @import("../../session/duration.zig");
const window_pace = @import("../../session/window_pace.zig");
const window_run = @import("window_run.zig");
const window_devices = @import("window_devices.zig");
const window_stills = @import("window_stills.zig");
const platform = @import("platform.zig");

/// One 60 Hz frame, in ns of core time.
pub const frame_ns: u64 = 16_666_667;

/// The run the window paces: `run` charges `pacer` as it goes and returns
/// the run's exit code.
pub const Runner = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, pacer: *window_pace.Pacer) u8,
};

/// What the window reads.
pub const Args = struct {
    io: std.Io,
    board: *Board,
    runner: Runner,
    /// Where `--window-stills` writes, and every how many frames.
    stills: ?[]const u8 = null,
    stills_every: u32 = 1,
    /// The `--attach` requests and `--click`, for the devices pane.
    attaches: []const request.Request = &.{},
    click: bool = false,
    camera: source_spec.Spec = .{},
};

/// How the executable opens and closes its window. src/main.zig sets it
/// in a -Dgui build (src/interfaces/gui/gui_window.zig, SDL); otherwise there is none.
pub const Opener = struct {
    open: *const fn () ?platform.Platform,
    close: *const fn () void,
};

pub var opener: ?Opener = null;

/// The window this build opens, or null when it has none to open.
pub fn open() ?platform.Platform {
    const how = opener orelse return null;
    return how.open();
}

/// Runs `args` in the window; 2 when there is no window to open.
pub fn show(allocator: std.mem.Allocator, args: Args) !u8 {
    const how = opener orelse {
        std.debug.print("--gui needs a window: build the emulator with -Dgui\n", .{});
        return 2;
    };
    const window = how.open() orelse {
        std.debug.print("--gui could not open a window\n", .{});
        return 2;
    };
    defer how.close();
    var pacer = window_pace.Pacer{ .per_frame = duration.cycles(frame_ns, args.board.time.base.hz), .io = args.io };
    const stills_dir = try window_stills.openDir(args.io, args.stills);
    defer if (stills_dir) |dir| dir.close(args.io);
    var recorder = window_stills.Recorder{ .allocator = allocator, .inner = window, .io = args.io, .dir = stills_dir orelse std.Io.Dir.cwd(), .stem = "window", .every = args.stills_every };
    const shown = if (stills_dir != null) recorder.platform() else window;
    var live = Live{ .runner = args.runner, .pacer = &pacer };
    var devices: window_devices.Devices = undefined;
    devices.init(allocator, args.io, args.board, args.attaches, args.click);
    defer devices.deinit();
    const result = try window_run.show(allocator, args.io, shown, args.board, &pacer, live.engine(), args.camera, &devices);
    std.debug.print("window: {d} frames, board snapshot up to {d} bytes per frame\n", .{ result.frames, result.snapshot_bytes });
    return live.code;
}

/// The runner as the window's engine, charging the window's pacer.
const Live = struct {
    runner: Runner,
    pacer: *window_pace.Pacer,
    /// The run's exit code.
    code: u8 = 1,

    fn engine(self: *Live) window_run.Engine {
        return .{ .ctx = self, .run = run };
    }

    fn run(ctx: *anyopaque) void {
        const self: *Live = @ptrCast(@alignCast(ctx));
        self.code = self.runner.run(self.runner.ctx, self.pacer);
    }
};

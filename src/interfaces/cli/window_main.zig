//! `--gui` from main (RA8EMU-646): the Zig-core run goes on its own thread,
//! paced one 60 Hz frame of core time per window tick, and the window shows
//! the board until the run ends or the window closes.
const std = @import("std");
const elf = @import("../../core/elf.zig");
const Guest = @import("../../core/cpu/memory/guest.zig").Guest;
const Board = @import("../../board/board.zig").Board;
const clocks = @import("../../periph/clocks.zig");
const duration = @import("duration.zig");
const profile = @import("../../debug/profile.zig");
const Until = @import("../../core/until.zig").Until;
const cli = @import("cli.zig");
const zig_run = @import("zig_run.zig");
const window_pace = @import("window_pace.zig");
const window_run = @import("window_run.zig");
const window_devices = @import("window_devices.zig");
const window_stills = @import("window_stills.zig");
const platform = @import("../../gui/platform.zig");

/// One 60 Hz frame, in ns of core time.
pub const frame_ns: u64 = 16_666_667;

/// What zig_run.run takes, gathered by zig_main.
pub const Args = struct {
    io: std.Io,
    out: *std.Io.Writer,
    memory: Guest,
    board: *Board,
    timebase: *clocks.Clocks,
    image: elf.Image,
    options: cli.Options,
    vector_base: u32,
    profile_table: ?*profile.Table,
    until: ?*Until,
    ends: zig_run.Ends,
};

/// How the executable opens and closes its window. src/main.zig sets it
/// in a -Dgui build (src/gui_window.zig, SDL); otherwise there is none.
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
    const stills_dir = try window_stills.openDir(args.io, args.options.frames.window_stills);
    defer if (stills_dir) |dir| dir.close(args.io);
    var recorder = window_stills.Recorder{ .allocator = allocator, .inner = window, .io = args.io, .dir = stills_dir orelse std.Io.Dir.cwd(), .stem = "window", .every = args.options.frames.window_stills_every };
    const shown = if (stills_dir != null) recorder.platform() else window;
    var live = Live{ .args = args, .pacer = &pacer };
    var devices: window_devices.Devices = undefined;
    devices.init(allocator, args.io, args.board, args.options.attaches[0..args.options.attach_count], args.options.click);
    defer devices.deinit();
    const result = try window_run.show(allocator, args.io, shown, args.board, &pacer, live.engine(), args.options.camera, &devices);
    std.debug.print("window: {d} frames, board snapshot up to {d} bytes per frame\n", .{ result.frames, result.snapshot_bytes });
    return live.code;
}

/// zig_run.run as the window's engine, with its clock charging the pacer.
pub const Live = struct {
    args: Args,
    pacer: *window_pace.Pacer,
    /// The run's exit code; 1 when the run failed outright.
    code: u8 = 1,

    pub fn engine(self: *Live) window_run.Engine {
        return .{ .ctx = self, .run = run };
    }

    fn run(ctx: *anyopaque) void {
        const self: *Live = @ptrCast(@alignCast(ctx));
        const a = self.args;
        var ends = a.ends;
        ends.pace = self.pacer;
        self.code = zig_run.run(a.out, a.io, a.memory, a.board, a.timebase, a.image, a.options, a.vector_base, a.profile_table, a.until, ends) catch 1;
    }
};

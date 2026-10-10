//! `--gui` from the command line (RA8EMU-1074): zig_run.run as the
//! window's runner, its clock charging the window's pacer, with the
//! window's settings read from the parsed options.
const std = @import("std");
const elf = @import("../../board/loader/elf.zig");
const Guest = @import("../../chip/core/cpu/memory/guest.zig").Guest;
const Board = @import("../../board/board.zig").Board;
const clocks = @import("../../chip/periph/clocks.zig");
const profile = @import("../../session/profile.zig");
const Until = @import("../../chip/core/until.zig").Until;
const window_pace = @import("../../session/window_pace.zig");
const cli = @import("cli.zig");
const zig_run = @import("zig_run.zig");
const window_main = @import("window_main.zig");

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

/// Runs `args` in the window; 2 when there is no window to open.
pub fn show(allocator: std.mem.Allocator, args: Args) !u8 {
    var live = Live{ .args = args };
    const frames = args.options.frames;
    return window_main.show(allocator, .{
        .io = args.io,
        .board = args.board,
        .runner = live.runner(),
        .stills = frames.window_stills,
        .stills_every = frames.window_stills_every,
        .attaches = args.options.attaches[0..args.options.attach_count],
        .click = args.options.click,
        .camera = args.options.camera,
    });
}

const Live = struct {
    args: Args,

    fn runner(self: *Live) window_main.Runner {
        return .{ .ctx = self, .run = run };
    }

    fn run(ctx: *anyopaque, pacer: *window_pace.Pacer) u8 {
        const self: *Live = @ptrCast(@alignCast(ctx));
        const a = self.args;
        var ends = a.ends;
        ends.pace = pacer;
        return zig_run.run(a.out, a.io, a.memory, a.board, a.timebase, a.image, a.options, a.vector_base, a.profile_table, a.until, ends) catch 1;
    }
};

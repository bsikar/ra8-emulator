//! ra8_gui's live run (RA8EMU-1074, moved out of the command line by
//! RA8EMU-1088): zig_run.run as the window's runner, its clock charging the
//! window's pacer. The window's stills settings are ra8_gui's own flags
//! (gui_args, RA8EMU-1091), which ra8_gui's main stores in `window` first.
//! ra8_gui hands `show` to zig_main.window; ra8_emulator never sets it.
const std = @import("std");
const window_pace = @import("../../session/window_pace.zig");
const zig_run = @import("../cli/zig_run.zig");
const run_args = @import("../cli/run_args.zig");
const window_main = @import("window_main.zig");
const gui_args = @import("gui_args.zig");

pub const Args = run_args.Args;

/// The window flags ra8_gui parsed; ra8_gui sets this before the run.
pub var window: gui_args.Window = .{};

/// Runs `args` in the window; 2 when there is no window to open.
pub fn show(allocator: std.mem.Allocator, args: Args) !u8 {
    var live = Live{ .args = args };
    return window_main.show(allocator, .{
        .io = args.io,
        .board = args.board,
        .runner = live.runner(),
        .stills = window.stills,
        .stills_every = window.stills_every,
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

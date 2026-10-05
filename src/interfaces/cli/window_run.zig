//! A run shown live in the host window (RA8EMU-646): the engine runs to
//! its end on its own thread, paced one frame per window tick, while the
//! window draws the board and takes input. Closing the window ends the run
//! at its next boundary; the run ending closes the loop.
const std = @import("std");
const Board = @import("../../board/board.zig").Board;
const window_board = @import("window_board.zig");
const window_pace = @import("window_pace.zig");
const host_loop = @import("../../gui/host_loop.zig");
const platform = @import("../../gui/platform.zig");
const camera_devices = @import("../../gui/camera_devices.zig");

/// Runs the emulation to its end. Its clock must charge `pacer`, as
/// zig_run's Clock does when Ends.pace is set.
pub const Engine = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque) void,
};

/// What a shown run ended with.
pub const Shown = struct {
    /// Ticks that drew a frame with the run still going; the tick the run
    /// ended on draws one more, the board as the run left it.
    frames: u32,
    /// The window closed before the run ended.
    closed: bool,
};

/// Shows `board` in `window` while `engine` runs it. The panel is scanned
/// once before the engine starts, so the first frame never races it.
pub fn show(allocator: std.mem.Allocator, window: platform.Platform, board: *Board, pacer: *window_pace.Pacer, engine: Engine) !Shown {
    var screen = try window_board.Screen.init(allocator, board, pacer.stepper());
    defer screen.deinit();
    var loop = host_loop.Loop{ .allocator = allocator };
    defer loop.deinit();
    loop.adoptDevices(try camera_devices.listHost(allocator));
    const thread = try std.Thread.spawn(.{}, runThenFinish, .{ engine, pacer });
    defer {
        pacer.stop();
        thread.join();
    }
    var frames: u32 = 0;
    while (try loop.tick(window, screen.run())) frames += 1;
    return .{ .frames = frames, .closed = !ended(pacer) };
}

fn runThenFinish(engine: Engine, pacer: *window_pace.Pacer) void {
    defer pacer.finish();
    engine.run(engine.ctx);
}

fn ended(pacer: *window_pace.Pacer) bool {
    pacer.mutex.lock();
    defer pacer.mutex.unlock();
    return pacer.ended;
}

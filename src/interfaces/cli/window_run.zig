//! A run shown live in the host window (RA8EMU-646): the engine runs to
//! its end on its own thread, at most one frame per window tick, while the
//! window draws the newest board the engine published and takes input. The
//! window never waits on the engine (RA8EMU-227). Closing the window ends the run
//! at its next boundary; the run ending closes the loop.
const std = @import("std");
const Board = @import("../../board/board.zig").Board;
const window_board = @import("window_board.zig");
const window_pace = @import("window_pace.zig");
const host_loop = @import("../../gui/host_loop.zig");
const platform = @import("../../gui/platform.zig");
const camera_devices = @import("../../gui/camera_devices.zig");
const registry = @import("../../periph/camera/camera_registry.zig");
const thread_priority = @import("../../gui/thread_priority.zig");
const console_feed = @import("../../gui/console_feed.zig");
const console_log = @import("../../gui/console_log.zig");
const sci = @import("../../periph/sci/sci.zig");
const window_devices = @import("window_devices.zig");

/// Finished lines each channel's console keeps.
pub const console_capacity: usize = 2000;

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
    /// The most one board handoff to the window carried (RA8EMU-227).
    snapshot_bytes: usize = 0,
    /// Finished lines the console channel's log held at the end, and the
    /// bytes the feed could not keep (RA8EMU-206).
    console_lines: usize = 0,
    console_lost: u64 = 0,
};

/// Shows `board` in `window` while `engine` runs it, the camera pane
/// starting on `camera`, the run's own source. The panel is scanned once
/// before the engine starts, so the first frame never races it. The
/// devices pane lists `devices` and plugs through it; null shows none.
pub fn show(allocator: std.mem.Allocator, window: platform.Platform, board: *Board, pacer: *window_pace.Pacer, engine: Engine, camera: registry.Spec, devices: ?*window_devices.Devices) !Shown {
    var screen = try window_board.Screen.init(allocator, board, pacer.granter());
    defer screen.deinit();
    screen.on_engine = true;
    screen.devices = devices;
    pacer.at_park = screen.parkHook();
    var feed = console_feed.Feed{ .allocator = allocator, .now = screen.clock() };
    defer feed.deinit();
    var logs: [sci.channels]console_log.Log = undefined;
    for (&logs) |*log| log.* = .init(allocator, console_capacity);
    defer for (&logs) |*log| log.deinit();
    screen.feed = &feed;
    board.serial.tap = feed.tap();
    defer board.serial.tap = null;
    var loop = host_loop.Loop{ .allocator = allocator };
    defer loop.deinit();
    loop.pane.seed(camera);
    loop.console = &logs[sci.console_channel];
    if (devices) |d| loop.useDevices(&d.panel, &d.post);
    var host_devices: ?std.fs.Dir = std.fs.openDirAbsolute(camera_devices.host_dir, .{ .iterate = true }) catch null;
    defer if (host_devices) |*dir| dir.close();
    if (host_devices) |dir| loop.useDeviceDir(dir);
    loop.useProject(std.fs.cwd());
    var project_media: ?std.fs.Dir = std.fs.cwd().openDir(".", .{ .iterate = true }) catch null;
    defer if (project_media) |*dir| dir.close();
    if (project_media) |dir| loop.useMediaDir(dir);
    const thread = try std.Thread.spawn(.{}, runThenFinish, .{ engine, pacer });
    defer {
        pacer.stop();
        thread.join();
    }
    var frames: u32 = 0;
    var lost: u64 = 0;
    while (try loop.tick(window, screen.run())) : (lost = try feed.drain(&logs)) frames += 1;
    lost = try feed.drain(&logs);
    return .{
        .frames = frames,
        .closed = !ended(pacer),
        .snapshot_bytes = screen.handoff.max_bytes.load(.monotonic),
        .console_lines = logs[sci.console_channel].lines().len,
        .console_lost = lost,
    };
}

fn runThenFinish(engine: Engine, pacer: *window_pace.Pacer) void {
    defer pacer.finish();
    if (thread_priority.raiseEngine() == .refused) std.debug.print("window: the host kept the engine thread at its normal priority\n", .{});
    engine.run(engine.ctx);
}

fn ended(pacer: *window_pace.Pacer) bool {
    pacer.mutex.lock();
    defer pacer.mutex.unlock();
    return pacer.ended;
}

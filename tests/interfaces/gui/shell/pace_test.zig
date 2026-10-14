//! Tests for src/interfaces/gui/shell/pace.zig: a shell answering its own
//! session keeps sixty frames a second, and one with a session on a thread
//! of its own is paced by the display choices, tells the window about
//! vsync, owes a lit run the time each frame took and fills the counter.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const platform = gui_app.platform;
const shell_loop = gui_app.shell.loop;
const shell_run = gui_app.shell.run;
const shell_pace = gui_app.shell.pace;
const Pace = shell_pace.Pace;
const ms = std.time.ns_per_ms;

/// A window that says its refresh rate and counts what it is told of vsync.
const Window = struct {
    refresh_mhz: u32 = 100_000,
    vsync_calls: u32 = 0,
    vsync: bool = false,

    fn view(self: *Window) platform.Platform {
        return .{ .ctx = self, .vtable = &.{ .poll = poll, .size = size, .scale = scale, .present = present, .set_vsync = setVsync, .refresh = refresh } };
    }
    fn from(ctx: *anyopaque) *Window {
        return @ptrCast(@alignCast(ctx));
    }
    fn poll(_: *anyopaque) ?platform.Event {
        return null;
    }
    fn size(_: *anyopaque) platform.Size {
        return .{ .width = 4, .height = 4 };
    }
    fn scale(_: *anyopaque) f32 {
        return 1;
    }
    fn present(_: *anyopaque, _: *const ra8.render.raster.Framebuffer) anyerror!void {}
    fn setVsync(ctx: *anyopaque, on: bool) bool {
        from(ctx).vsync_calls += 1;
        from(ctx).vsync = on;
        return on;
    }
    fn refresh(ctx: *anyopaque) u32 {
        return from(ctx).refresh_mhz;
    }
};

const Bench = struct {
    shell: shell_loop.Shell,
    time: gui_app.shell.time.Time = .{},
    window: Window = .{},
    worker: gui_app.session_worker.Worker = undefined,
    pace: Pace = .{},

    fn open(self: *Bench, apart: bool) !void {
        self.* = .{ .shell = .init(std.testing.allocator, try gui_app.pane_layout.twoCore(std.testing.allocator)) };
        self.shell.time = &self.time;
        // Only whether the shell has a worker is read, never the worker.
        if (apart) self.shell.worker = &self.worker;
    }
};

test "a shell answering its own session keeps sixty frames a second" {
    var bench: Bench = undefined;
    try bench.open(false);
    defer bench.shell.deinit();
    bench.shell.settings.display = .{ .vsync = false, .limit = .fps240, .counter = true };
    bench.pace.begin(&bench.shell, bench.window.view(), 100 * ms);
    try std.testing.expectEqual(100 * ms + shell_run.frame_ns, bench.pace.end(&bench.shell, bench.window.view(), 100 * ms, 101 * ms));
    try std.testing.expectEqual(@as(u32, 0), bench.window.vsync_calls);
    try std.testing.expectEqual(shell_run.frame_ns, bench.time.run.period_ns);
    try std.testing.expectEqual(@as(?[]const u8, null), bench.shell.status.frames);
}

test "the window is told of vsync once, and again when the choice changes" {
    var bench: Bench = undefined;
    try bench.open(true);
    defer bench.shell.deinit();
    const window = bench.window.view();
    bench.pace.begin(&bench.shell, window, 0);
    bench.pace.begin(&bench.shell, window, 10 * ms);
    try std.testing.expectEqual(@as(u32, 1), bench.window.vsync_calls);
    try std.testing.expect(bench.window.vsync);
    bench.shell.settings.display.vsync = false;
    bench.pace.begin(&bench.shell, window, 20 * ms);
    try std.testing.expectEqual(@as(u32, 2), bench.window.vsync_calls);
    try std.testing.expect(!bench.window.vsync);
}

test "a lit run is owed the time each frame took, a stall capped" {
    var bench: Bench = undefined;
    try bench.open(true);
    defer bench.shell.deinit();
    const window = bench.window.view();
    bench.pace.begin(&bench.shell, window, 50 * ms);
    try std.testing.expectEqual(shell_run.frame_ns, bench.time.run.period_ns);
    bench.pace.begin(&bench.shell, window, 57 * ms);
    try std.testing.expectEqual(7 * ms, bench.time.run.period_ns);
    bench.pace.begin(&bench.shell, window, 5057 * ms);
    try std.testing.expectEqual(shell_pace.most_owed_ns, bench.time.run.period_ns);
    // What the frame owes follows: a tenth of real time over seven milliseconds.
    bench.time.run.period_ns = 7 * ms;
    bench.time.run.frame(0, 100);
    try std.testing.expectEqual(@as(?u64, 7 * ms / 10), bench.time.run.owed_ns);
}

test "the next frame begins a refresh later with vsync, sooner on a limit off it, at once unpaced" {
    var bench: Bench = undefined;
    try bench.open(true);
    defer bench.shell.deinit();
    const window = bench.window.view();
    // 100 Hz display, vsync on, no limit.
    try std.testing.expectEqual(110 * ms, bench.pace.end(&bench.shell, window, 100 * ms, 101 * ms));
    bench.shell.settings.display = .{ .vsync = false, .limit = .fps240 };
    bench.pace = .{};
    try std.testing.expectEqual(200 * ms + std.time.ns_per_s / 240, bench.pace.end(&bench.shell, window, 200 * ms, 201 * ms));
    bench.shell.settings.display = .{ .vsync = false, .limit = .none };
    try std.testing.expectEqual(300 * ms, bench.pace.end(&bench.shell, window, 300 * ms, 301 * ms));
}

test "the counter fills the status strip's segment while it is on" {
    var bench: Bench = undefined;
    try bench.open(true);
    defer bench.shell.deinit();
    const window = bench.window.view();
    bench.shell.settings.display.counter = true;
    var began: u64 = 0;
    while (bench.shell.status.frames == null) : (began += 10 * ms) {
        try std.testing.expect(began <= 2 * std.time.ns_per_s);
        _ = bench.pace.end(&bench.shell, window, began, began + 2 * ms);
    }
    try std.testing.expectEqualStrings("100.0 fps 2.0 ms", bench.shell.status.frames.?);
    var line: [256]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, try bench.shell.status.text(.closed, &line), "| 100.0 fps 2.0 ms"));
    bench.shell.settings.display.counter = false;
    _ = bench.pace.end(&bench.shell, window, began, began + 2 * ms);
    try std.testing.expectEqual(@as(?[]const u8, null), bench.shell.status.frames);
}

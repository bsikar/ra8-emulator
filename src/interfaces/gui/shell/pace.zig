//! The drive loop's pacing: when the window's next frame begins. A window
//! someone is using, its session on a thread of its own, is paced by the
//! settings page's display choices (display_settings.zig): to the display's
//! refresh with vsync, to the frame rate limit, or not at all. A lit run is
//! then owed the time each frame really took, so the image keeps the speed
//! asked for at any frame rate. A session on the shell's own thread keeps
//! the fixed sixty frames a second its scripted and counted runs are
//! written against.
const std = @import("std");
const platform = @import("../platform.zig");
const frame_pacer = @import("../frame_pacer.zig");
const shell_loop = @import("loop.zig");
const shell_run = @import("run.zig");

/// The most one frame owes a running image: a stalled window (a dragged
/// title bar, a suspended host) does not come back owing the whole stall.
pub const most_owed_ns: u64 = 100 * std.time.ns_per_ms;

pub const Pace = struct {
    pacer: frame_pacer.Pacer = .{},
    meter: frame_pacer.Meter = .{},
    /// What the window was last asked about vsync; null before the first.
    vsync: ?bool = null,
    text_buf: [40]u8 = undefined,

    /// A frame is about to begin at `now_ns`.
    pub fn begin(self: *Pace, shell: *shell_loop.Shell, window: platform.Platform, now_ns: u64) void {
        if (shell.worker == null) return;
        const display = shell.settings.display;
        if (self.vsync != display.vsync) {
            _ = window.setVsync(display.vsync);
            self.vsync = display.vsync;
        }
        const since = self.pacer.begin(now_ns) orelse shell_run.frame_ns;
        if (shell.time) |time| time.run.period_ns = @min(since, most_owed_ns);
    }

    /// The frame begun at `began_ns` was drawn by `ended_ns`. Returns when
    /// the next one may begin.
    pub fn end(self: *Pace, shell: *shell_loop.Shell, window: platform.Platform, began_ns: u64, ended_ns: u64) u64 {
        if (shell.worker == null) return began_ns + shell_run.frame_ns;
        const display = shell.settings.display;
        if (!display.counter) {
            shell.status.frames = null;
            self.meter = .{};
        } else if (self.meter.count(began_ns, ended_ns)) |reading| {
            shell.status.frames = std.fmt.bufPrint(&self.text_buf, "{d}.{d} fps {d}.{d} ms", .{ reading.fps_tenths / 10, reading.fps_tenths % 10, reading.frame_us / 1000, reading.frame_us % 1000 / 100 }) catch null;
        }
        return self.pacer.next(began_ns, display.interval(window.refresh()));
    }
};

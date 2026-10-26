//! Session API window methods and rewind/stepBack delegation (Slice 21.4).
const std = @import("std");
const api = @import("api.zig");
const session_control = @import("control.zig");
const window_engine = @import("history/window_engine.zig");
const canonical_step = @import("history/canonical_step.zig");

pub const Status = window_engine.Status;

/// How a run slice reaches the window that records the live run: `enter`
/// brings the machine to the window's end before the slice starts,
/// `go` runs the command (slot by slot while the window records) and
/// `settle` drops a window the slice left behind.
pub const Driver = struct {
    context: *anyopaque,
    enterFn: *const fn (context: *anyopaque, session: *api.Session) void,
    goFn: *const fn (context: *anyopaque, session: *api.Session, command: api.Run) anyerror!api.Ended,
    settleFn: *const fn (context: *anyopaque, session: *api.Session) void,
};

/// Attaches an active reverse window to the session.
pub fn attachWindow(self: *api.Session, window: *window_engine.ReverseWindow) void {
    self.window = window;
}

/// Attaches the driver that records the live run into the window.
pub fn attachWindowDriver(self: *api.Session, driver: Driver) void {
    self.window_driver = driver;
}

/// The machine was put back from a saved state: the window described the
/// run before it, so it forgets that run. A rebuild's own restore keeps it.
pub fn dropWindow(self: *api.Session) void {
    const w = self.window orelse return;
    if (w.rebuild == null) w.drop();
}

/// Drops the window, then plants it again at the state the machine stands
/// at, so recording goes on from there. A plant that fails leaves it empty.
pub fn replantWindow(self: *api.Session) void {
    const w = self.window orelse return;
    if (w.rebuild != null) return;
    w.drop();
    w.plant() catch w.drop();
}

/// Returns the current reverse window status, or null if no window is attached.
pub fn windowStatus(self: *const api.Session) ?window_engine.Status {
    const w = self.window orelse return null;
    return w.status();
}

fn toTrailCore(core: api.Core) window_engine.Core {
    return switch (core) {
        .cpu0 => .cpu0,
        .cpu1 => .cpu1,
    };
}

/// Checks whether the reverse window holds at least `count` canonical stops
/// behind the cursor for `core`.
pub fn canStepBack(w: *window_engine.ReverseWindow, core: api.Core, count: u32) bool {
    if (count == 0) return true;
    const tc = toTrailCore(core);
    var remaining = count;
    var pos = w.cursor();
    while (remaining > 0) {
        while (pos > 0 and w.slotAt(pos - 1).core != tc) pos -= 1;
        if (pos == 0) return false;
        pos -= 1;
        remaining -= 1;
    }
    return true;
}

/// Puts the run back `back` recorded stops; uses the reverse window when it
/// covers them, falling back to the history ring outside the window.
pub fn rewind(self: *api.Session, core: api.Core, back: u32) anyerror!void {
    if (self.window) |w| {
        if (canStepBack(w, core, back)) {
            const tc = toTrailCore(core);
            var i: u32 = 0;
            while (i < back) : (i += 1) {
                _ = try canonical_step.stepBack(w, tc);
            }
            self.publish(.{ .core = core, .kind = .rewound });
            return;
        }
    }
    return session_control.rewind(self, core, back);
}

/// Puts the run back one recorded stop on `core`.
pub fn stepBack(self: *api.Session, core: api.Core) anyerror!void {
    return rewind(self, core, 1);
}

//! The frame tap: a passive per-boundary capture hook (RA8EMU milestone M7).
//!
//! It runs once per boundary, after the board's tick. It is never a grid
//! edge and never arms the panel's frame clock: the clock is the run's
//! `panel_vsync` config, and a consumer captures through the tap only when
//! the config has armed no edges to ride. Captures are rate-capped in host
//! time, so a run at `max` speed does not composite at every boundary.
//!
//! What the tap does with a capture (change-trigger or not) is the
//! consumer's own business; the tap only decides when one may happen.
const std = @import("std");

pub const Tap = struct {
    io: std.Io,
    context: *anyopaque,
    captureFn: *const fn (context: *anyopaque, virtual_ns: u64) void,
    /// Host nanoseconds between captures.
    interval_ns: i96 = 16_666_667,
    last_ns: i96 = 0,

    /// One boundary has passed. Capture, unless the host rate cap says not yet.
    pub fn afterBoundary(self: *Tap, virtual_ns: u64) void {
        const now = std.Io.Timestamp.now(self.io, .real).toNanoseconds();
        if (self.last_ns != 0 and now - self.last_ns < self.interval_ns) return;
        self.last_ns = now;
        self.captureFn(self.context, virtual_ns);
    }
};

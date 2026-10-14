//! When the window's next frame begins, and how many it draws a second.
//! Frames are kept to a schedule rather than each waiting out a fixed time
//! after the last began: a wait that overshoots by half a millisecond would
//! otherwise cost a frame or two in every sixty. The meter counts what was
//! drawn over half a second at a time, for the status strip's counter.
const std = @import("std");

pub const Pacer = struct {
    /// When the frame after the last was due to begin; 0 before the first.
    due_ns: u64 = 0,
    /// When the last frame began; null before the first.
    last_ns: ?u64 = null,

    /// A frame begins at `now_ns`. Returns the time since the last began,
    /// which is what the frame owes a running image; null for the first.
    pub fn begin(self: *Pacer, now_ns: u64) ?u64 {
        defer self.last_ns = now_ns;
        const last = self.last_ns orelse return null;
        return now_ns -| last;
    }

    /// When the frame after the one begun at `began_ns` may begin, with
    /// `interval_ns` between frames; zero is at once. A window more than a
    /// frame behind its schedule starts over from here rather than racing
    /// to catch up.
    pub fn next(self: *Pacer, began_ns: u64, interval_ns: u64) u64 {
        if (interval_ns == 0) {
            self.due_ns = 0;
            return began_ns;
        }
        const kept = self.due_ns +| interval_ns;
        const behind = self.due_ns == 0 or kept +| interval_ns < began_ns or kept > began_ns +| 2 * interval_ns;
        self.due_ns = if (behind) began_ns +| interval_ns else kept;
        return self.due_ns;
    }
};

/// How long the meter counts before it reports.
pub const report_ns: u64 = std.time.ns_per_s / 2;

pub const Meter = struct {
    since_ns: ?u64 = null,
    frames: u32 = 0,
    /// Time spent inside the counted frames, waiting left out.
    worked_ns: u64 = 0,

    pub const Reading = struct {
        /// Frames a second, in tenths.
        fps_tenths: u32,
        /// What one frame cost on average, in microseconds.
        frame_us: u32,
    };

    /// A frame that began at `began_ns` and was drawn by `ended_ns`. Returns
    /// a reading once `report_ns` has been counted, and starts over.
    pub fn count(self: *Meter, began_ns: u64, ended_ns: u64) ?Reading {
        const since = self.since_ns orelse {
            self.since_ns = began_ns;
            return null;
        };
        self.frames += 1;
        self.worked_ns += ended_ns -| began_ns;
        const span = began_ns -| since;
        if (span < report_ns) return null;
        const reading: Reading = .{
            .fps_tenths = @intCast(@min(@as(u64, self.frames) * 10 * std.time.ns_per_s / span, std.math.maxInt(u32))),
            .frame_us = @intCast(@min(self.worked_ns / self.frames / std.time.ns_per_us, std.math.maxInt(u32))),
        };
        self.* = .{ .since_ns = began_ns };
        return reading;
    }
};

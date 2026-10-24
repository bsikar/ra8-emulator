//! Building a reverse window by one replay (section 2.5).
//!
//! The first reverse step in an interval with no window restores the
//! nearest checkpoint at or before the interval, replays to the window's
//! start without recording, plants the hot checkpoint there, and replays
//! on to the cursor while recording every slot. The replay is the
//! binding's: its restore readies the recorded interventions and its step
//! runs with the session replaying, so nothing new is recorded and the
//! interventions are re-applied where they were made.
//!
//! The job is sliced so the transport can surface "rebuilding" with its
//! progress and own its cancel; `run` drives it to the end synchronously,
//! the v1 behaviour. A cancel drops the half-built window; putting the
//! machine back at the origin is the caller's, as for any replay job.
const std = @import("std");
const engine = @import("window_engine.zig");
const record = @import("window_record.zig");

const ReverseWindow = engine.ReverseWindow;
const Position = engine.Position;
const Core = engine.Core;

/// Where the replay starts.
pub const Base = union(enum) {
    /// The live state is the base.
    current,
    /// A whole save stream (a checkpoint's object); the job copies it.
    bytes: []const u8,
};

pub const Plan = struct {
    base: Base = .current,
    /// The core whose turn each recorded step runs on.
    core: Core = .cpu0,
    /// Where the window starts; null starts it at the base.
    start: ?Position = null,
    /// The window's end: the cursor the reverse step backs off from.
    end: Position,
};

pub const Phase = enum { restore, seek, record };

pub const Progress = struct {
    phase: Phase,
    reached: ?Position,
    target: Position,
    /// Slots replayed so far, recorded or not.
    slots: u64,
};

pub const Job = struct {
    base: ?[]u8,
    core: Core,
    start: ?Position,
    target: Position,
    phase: Phase = .restore,
    reached: ?Position = null,
    slots: u64 = 0,

    pub fn progress(self: *const Job) Progress {
        return .{ .phase = self.phase, .reached = self.reached, .target = self.target, .slots = self.slots };
    }
};

/// Drops any window and queues a rebuild by `plan`.
pub fn begin(w: *ReverseWindow, plan: Plan) !void {
    const copy: ?[]u8 = switch (plan.base) {
        .current => null,
        .bytes => |bytes| try w.allocator.dupe(u8, bytes),
    };
    w.drop();
    w.rebuild = .{ .base = copy, .core = plan.core, .start = plan.start, .target = plan.end };
}

/// Advances the rebuild by at most `max_slots` replayed slots. True once
/// the window is built; an error drops the half-built window.
pub fn slice(w: *ReverseWindow, max_slots: usize) !bool {
    errdefer w.drop();
    const job = if (w.rebuild) |*held| held else return engine.Error.NoWindow;
    switch (job.phase) {
        .restore => {
            if (job.base) |bytes| try w.port.restoreFull(bytes);
            job.phase = .seek;
            job.reached = w.port.position();
            return false;
        },
        .seek => return seek(w, job, max_slots),
        .record => {
            var n: usize = 0;
            while (n < max_slots) : (n += 1) {
                const at = w.port.position();
                job.reached = at;
                if (try order(at, job.target) != .lt) return finish(w);
                try record.recordSlot(w, job.core);
                job.slots += 1;
            }
            return false;
        },
    }
}

/// Runs a rebuild to its end: the synchronous v1 rebuild.
pub fn run(w: *ReverseWindow, plan: Plan) !void {
    try begin(w, plan);
    while (!try slice(w, std.math.maxInt(usize))) {}
}

/// Abandons a rebuild and the half-built window.
pub fn cancel(w: *ReverseWindow) void {
    w.drop();
}

fn seek(w: *ReverseWindow, job: *Job, max_slots: usize) !bool {
    var n: usize = 0;
    while (n < max_slots) : (n += 1) {
        const at = w.port.position();
        job.reached = at;
        const until = job.start orelse at;
        if (try order(at, until) != .lt or try order(at, job.target) != .lt) {
            try w.plant();
            job.phase = .record;
            return false;
        }
        const mark = w.recording.record_count;
        try w.port.step(job.core);
        record.discardFrom(w.recording, mark);
        if (try order(w.port.position(), at) != .gt) return engine.Error.NoProgress;
        job.slots += 1;
    }
    return false;
}

fn finish(w: *ReverseWindow) bool {
    const job = w.rebuild.?;
    if (job.base) |bytes| w.allocator.free(bytes);
    w.rebuild = null;
    return true;
}

fn order(a: Position, b: Position) !std.math.Order {
    return Position.order(a, b) orelse engine.Error.OtherLine;
}

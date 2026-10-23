//! The history track's model: the machine's recorded extent behind the
//! time bar's seek strip. The strip spans virtual time from the run's
//! root (zero) to the tail past the recorded end the design's track
//! shows, the recorded part drawn solid and the unrun tail hatched. The
//! model answers a click with where it lands: a recorded virtual time
//! to seek to, or an unrun one that starts a turbo run there. Marks the
//! wiring hands in resolve a click to the newest checkpoint at or
//! before it, the base the planner replays from. A model, no paint: the
//! bar's painter reads the span and the cursor fraction.
const std = @import("std");

/// One checkpoint mark on the track: the virtual time it restores and
/// its index in the facts the wiring keeps.
pub const Mark = struct {
    ns: u64,
    /// The checkpoint's index in the wiring's checkpoint list.
    index: usize,
};

/// How much past the recorded end the strip shows: the larger of a
/// quarter again and ten seconds, so a short run still has an unrun
/// region to aim a turbo at.
pub fn pastEnd(end_ns: u64) u64 {
    return @max(end_ns / 4, 10 * std.time.ns_per_s);
}

/// The track's whole span in virtual time: root to the recorded end
/// plus the unrun tail.
pub fn spanTotal(end_ns: u64) u64 {
    return end_ns + pastEnd(end_ns);
}

/// Where a click on the strip lands.
pub const Click = union(enum) {
    /// Inside the recorded part: a virtual time to seek to.
    recorded: u64,
    /// Past the recorded end: a turbo run starts at this virtual time.
    unrun: u64,
};

/// The newest mark at or before `ns`, the seek base the planner
/// replays from; null when no mark sits there.
pub fn checkpointBefore(marks: []const Mark, ns: u64) ?Mark {
    var best: ?Mark = null;
    for (marks) |mark| {
        if (mark.ns > ns) continue;
        if (best == null or mark.ns >= best.?.ns) best = mark;
    }
    return best;
}

pub const Track = struct {
    /// The recorded end in virtual time; null while nothing is recorded.
    end_ns: ?u64 = null,
    /// The cursor's virtual time; null before the first clock answer.
    current_ns: ?u64 = null,

    /// Whether the machine has recorded history to show. An end of zero
    /// is no history: nothing has run.
    pub fn recorded(self: *const Track) bool {
        const end = self.end_ns orelse return false;
        return end > 0;
    }

    /// The strip's whole span in virtual time, or zero while nothing is
    /// recorded.
    pub fn total(self: *const Track) u64 {
        const end = self.end_ns orelse return 0;
        return spanTotal(end);
    }

    /// The cursor's fraction across the strip, 0 to 1. A cursor beyond
    /// the tail clamps to the strip's end; unknown is null.
    pub fn cursorFraction(self: *const Track) ?f64 {
        const now = self.current_ns orelse return null;
        const span = self.total();
        if (span == 0) return null;
        const bounded: u64 = @intFromFloat(@as(f64, @floatFromInt(@min(now, span))));
        return @as(f64, @floatFromInt(bounded)) / @as(f64, @floatFromInt(span));
    }

    /// Where a click at `fraction` (0 to 1) across the strip lands.
    /// Null on an empty track; a click off the ends clamps to the edge.
    pub fn click(self: *const Track, fraction: f64) ?Click {
        const span = self.total();
        if (span == 0) return null;
        const clamped = @max(0.0, @min(1.0, fraction));
        const ns: u64 = @intFromFloat(clamped * @as(f64, @floatFromInt(span)));
        if (ns <= self.end_ns.?) return .{ .recorded = ns };
        return .{ .unrun = ns };
    }
};

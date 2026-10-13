//! The timeline pane's model (RA8EMU-834), piece 2 of 5 under RA8EMU-215.
//!
//! Fed the RTOS trace events src/session/rtos/trace.zig records, this
//! folds them into lanes per core, one lane per thread and one per ISR
//! plus idle, holding [start_ns, end_ns) slices in a bounded ring that
//! keeps the newest window when it fills. Which owner time goes to is
//! RA8EMU-269's own state machine (rtos_load.Core), reused here rather
//! than re-derived. A View holds the visible window over that record:
//! start, span, zoom about a point and pan, clamped to what's recorded,
//! and a hit test maps a pane x through the View to the slice under it.

const std = @import("std");
const session = @import("ra8_session");
pub const rtos_load = session.rtos.load;
pub const rtos_trace = session.rtos.trace;

pub const limits = struct {
    /// Slices kept across every lane. A run past this evicts the slice
    /// with the earliest end, so the ring keeps the newest window.
    pub const slices: usize = 512;
    pub const cores: usize = rtos_trace.limits.cores;
};

/// One lane: one core's time for a thread, an exception, or idle.
pub const Lane = struct {
    core: u1,
    kind: rtos_load.Kind,
    /// The thread's control block or the exception's number; 0 for idle.
    id: u32 = 0,
};

/// One [start_ns, end_ns) stretch on one lane.
pub const Slice = struct {
    start_ns: u64,
    end_ns: u64,
};

const LaneRow = struct {
    lane: Lane,
    slices: std.ArrayListUnmanaged(Slice) = .empty,
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    lanes: std.ArrayListUnmanaged(LaneRow) = .empty,
    /// 269's per-core running state, driving the fold.
    fold: [limits.cores]rtos_load.Core = .{ .{}, .{} },
    /// Slices still held, across every lane.
    kept: usize = 0,
    /// The virtual time the ring still covers; latest_ns is the newest
    /// slice's end. An empty model holds nothing.
    earliest_ns: u64 = std.math.maxInt(u64),
    latest_ns: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Model {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Model) void {
        for (self.lanes.items) |*row| row.slices.deinit(self.allocator);
        self.lanes.deinit(self.allocator);
    }

    /// Take one trace event. Events for one core must come in time order.
    pub fn take(self: *Model, one: rtos_trace.Event) !void {
        try self.charge(one.core, one.when);
        self.fold[one.core].take(one);
    }

    /// Close both cores' open slices at `now`, as the run ends.
    pub fn finish(self: *Model, now: u64) !void {
        for (0..limits.cores) |index| {
            try self.charge(@intCast(index), now);
        }
    }

    /// The lanes, in the order they were first charged.
    pub fn laneCount(self: *const Model) usize {
        return self.lanes.items.len;
    }

    pub fn laneAt(self: *const Model, index: usize) Lane {
        return self.lanes.items[index].lane;
    }

    /// The index of the lane for one owner, or null when none holds it.
    pub fn laneIndex(self: *const Model, core: u1, kind: rtos_load.Kind, id: u32) ?usize {
        for (self.lanes.items, 0..) |*row, index| {
            if (row.lane.core == core and row.lane.kind == kind and row.lane.id == id) return index;
        }
        return null;
    }

    /// One lane's slices, oldest first.
    pub fn slicesOf(self: *const Model, index: usize) []const Slice {
        return self.lanes.items[index].slices.items;
    }

    /// Virtual ticks one lane covered in [from, to), from its slices.
    pub fn laneTicks(self: *const Model, index: usize, from: u64, to: u64) u64 {
        var sum: u64 = 0;
        for (self.lanes.items[index].slices.items) |one| {
            const start = @max(one.start_ns, from);
            const end = @min(one.end_ns, to);
            if (end > start) sum += end - start;
        }
        return sum;
    }

    /// One lane's share of [from, to), in permille, or null on an empty
    /// window.
    pub fn lanePermille(self: *const Model, index: usize, from: u64, to: u64) ?u64 {
        if (to <= from) return null;
        return self.laneTicks(index, from, to) * 1000 / (to - from);
    }

    /// The virtual time the ring still holds, or null when empty.
    pub fn recorded(self: *const Model) ?rtos_load.Window {
        if (self.kept == 0) return null;
        return .{ .from = self.earliest_ns, .to = self.latest_ns };
    }

    /// The slice under pane x on one lane, or null.
    pub fn hit(self: *const Model, index: usize, view: View, x: i32) ?Slice {
        const ns = view.xToNs(x);
        for (self.slicesOf(index)) |one| {
            if (one.start_ns <= ns and ns < one.end_ns) return one;
        }
        return null;
    }

    /// Close the open slice on one core at `now`, charged to whoever 269
    /// says ran since the last event. Time before a core's first event is
    /// 269's `before` and goes on no lane. An owner that only held the
    /// core at an instant, its whole stretch at the time the last event
    /// landed, gets a zero-width slice, so the event that charged it is
    /// still a slice edge on its own lane.
    fn charge(self: *Model, core: u1, now: u64) !void {
        const one = &self.fold[core];
        if (now < one.since) return;
        const owner = one.running();
        if (owner.kind != .before) try self.append(owner, core, one.since, now);
        one.since = now;
    }

    fn append(self: *Model, owner: rtos_load.Owner, core: u1, start_ns: u64, end_ns: u64) !void {
        const row = try self.laneRow(owner, core);
        try row.slices.append(self.allocator, .{ .start_ns = start_ns, .end_ns = end_ns });
        self.kept += 1;
        self.earliest_ns = @min(self.earliest_ns, start_ns);
        self.latest_ns = @max(self.latest_ns, end_ns);
        if (self.kept > limits.slices) self.evictOldest();
    }

    fn laneRow(self: *Model, owner: rtos_load.Owner, core: u1) !*LaneRow {
        const id: u32 = if (owner.kind == .idle) 0 else owner.id;
        if (self.laneIndex(core, owner.kind, id)) |index| return &self.lanes.items[index];
        try self.lanes.append(self.allocator, .{ .lane = .{ .core = core, .kind = owner.kind, .id = id } });
        return &self.lanes.items[self.lanes.items.len - 1];
    }

    /// Drop the slice with the earliest end, over every lane, so the ring
    /// keeps the newest window.
    fn evictOldest(self: *Model) void {
        var best: usize = 0;
        var best_end: u64 = std.math.maxInt(u64);
        var found = false;
        for (self.lanes.items, 0..) |*row, index| {
            if (row.slices.items.len == 0) continue;
            const end = row.slices.items[0].end_ns;
            if (!found or end < best_end) {
                best_end = end;
                best = index;
                found = true;
            }
        }
        if (!found) return;
        _ = self.lanes.items[best].slices.orderedRemove(0);
        self.kept -= 1;
        self.recomputeEarliest();
    }

    fn recomputeEarliest(self: *Model) void {
        self.earliest_ns = std.math.maxInt(u64);
        for (self.lanes.items) |*row| {
            if (row.slices.items.len == 0) continue;
            self.earliest_ns = @min(self.earliest_ns, row.slices.items[0].start_ns);
        }
    }
};

/// The pane's view over the model's record: the visible window and how
/// it maps to pane x. Zoom and pan clamp to the record, so the view
/// never shows time the ring no longer holds.
pub const View = struct {
    start_ns: u64 = 0,
    span_ns: u64 = 1,
    /// Pixels the pane draws the timeline across.
    width_px: u32 = 1,

    /// The ns under pane x, clamped to the view's own window.
    pub fn xToNs(self: View, x: i32) u64 {
        const width: i64 = @intCast(self.width_px);
        const clamped: i64 = @min(@max(x, 0), width - 1);
        const offset = @as(u128, @intCast(clamped)) * self.span_ns / @as(u128, @intCast(width));
        return self.start_ns + @as(u64, @intCast(offset));
    }

    /// The pane x for one ns, clamped to the view.
    pub fn nsToX(self: View, ns: u64) i32 {
        const width: i64 = @intCast(self.width_px);
        if (ns <= self.start_ns) return 0;
        const x = @as(u128, ns - self.start_ns) * @as(u128, @intCast(width)) / self.span_ns;
        return @intCast(@min(x, @as(u128, @intCast(width))));
    }

    /// Zoom by numerator/denominator about `about_ns`, keeping it under
    /// the same x: 1/2 is twice as close, 2/1 twice as far.
    pub fn zoom(self: View, about_ns: u64, numerator: u64, denominator: u64, recorded: rtos_load.Window) View {
        const denom: u128 = if (denominator == 0) 1 else denominator;
        const numer: u128 = if (numerator == 0) 1 else numerator;
        var next = self;
        next.span_ns = clampedSpan(@as(u128, self.span_ns) * numer / denom, recorded);
        const about = @min(@max(about_ns, self.start_ns), self.start_ns + self.span_ns - 1);
        const before: u128 = about - self.start_ns;
        const kept: u128 = before * @as(u128, next.span_ns) / self.span_ns;
        const raw: i128 = @as(i128, about) - @as(i128, @intCast(kept));
        next.start_ns = clampedStart(if (raw < 0) 0 else @intCast(raw), next.span_ns, recorded);
        return next;
    }

    /// Shift the window by `delta_ns`, clamped to the record.
    pub fn pan(self: View, delta_ns: i64, recorded: rtos_load.Window) View {
        const moved: i128 = @as(i128, self.start_ns) + delta_ns;
        const start: u64 = if (moved < 0) 0 else @intCast(moved);
        return .{
            .start_ns = clampedStart(start, self.span_ns, recorded),
            .span_ns = self.span_ns,
            .width_px = self.width_px,
        };
    }
};

fn clampedSpan(span: u128, recorded: rtos_load.Window) u64 {
    const out = @min(@max(span, 1), recorded.to - recorded.from);
    return @intCast(out);
}

fn clampedStart(start: u64, span: u64, recorded: rtos_load.Window) u64 {
    return @min(@max(start, recorded.from), recorded.to - span);
}

/// A session stream event's RTOS payload as a trace event, or null when
/// the event is not an RTOS kind.
pub fn streamToTrace(one: session.event.stream.Event) ?rtos_trace.Event {
    const kind: rtos_trace.Kind = switch (one.kind) {
        .rtos_switch => .switch_to,
        .rtos_idle => .idle,
        .isr_enter => .enter,
        .isr_leave => .leave,
        else => return null,
    };
    const payload = switch (one.payload) {
        .rtos => |rtos| rtos,
        else => return null,
    };
    return .{
        .when = one.virtual_ns,
        .core = switch (one.core) {
            .cpu0 => 0,
            .cpu1 => 1,
        },
        .kind = kind,
        .thread = payload.thread,
        .exception = payload.exception,
    };
}

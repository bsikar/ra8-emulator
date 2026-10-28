//! Reverse-watch backward search machinery: replays forward across checkpoint
//! intervals to find the latest write to an armed write watch, and lands on it.

const std = @import("std");
const api = @import("../api.zig");
const command_mod = @import("command.zig");
const position_mod = @import("../history/position.zig");
const reverse_mod = @import("reverse.zig");
const reverse_watch = @import("../history/reverse_watch.zig");
const session_root = @import("../root.zig");
const transport_mod = @import("transport.zig");

const Error = command_mod.Error;
const ReplayObserver = session_root.search.ReplayObserver;
const Transport = transport_mod.Transport;
const watch_table = session_root.watch.table;

fn isTransportCancelled(context: *anyopaque) bool {
    const self: *Transport = @ptrCast(@alignCast(context));
    return self.job == null or self.cancelled;
}

fn transportComparePositions(context: *anyopaque, a: position_mod.Position, b: position_mod.Position) anyerror!std.math.Order {
    const self: *Transport = @ptrCast(@alignCast(context));
    return self.session.comparePositions(a, b);
}

fn replaySession(
    context: *anyopaque,
    base: reverse_watch.Checkpoint,
    until: position_mod.Position,
    range: reverse_watch.Range,
    sink: *reverse_watch.Sink,
) reverse_watch.Error!void {
    const self: *Transport = @ptrCast(@alignCast(context));
    _ = range;

    self.restoreBase(.{ .checkpoint = .{ .id = base.id, .object = base.object, .position = base.position } }) catch return reverse_watch.Error.ReplayFailed;

    const store = self.session.store() orelse return reverse_watch.Error.ReplayFailed;
    var obs_ctx: ReplayObserver = .{ .sink = sink, .session = self.session };
    const obs = obs_ctx.observer();
    const prev_observer = store.observer;
    store.observer = &obs;
    defer store.observer = prev_observer;

    self.session.replaying = true;
    defer self.session.replaying = false;

    const core = self.session.currentCore();
    while (true) {
        if (self.cancelled or self.job == null) return reverse_watch.Error.Cancelled;
        const grid = self.session.grid orelse return reverse_watch.Error.ReplayFailed;
        const ord = self.session.comparePositions(grid.at, until) catch return reverse_watch.Error.ReplayFailed;
        if (ord != .lt) break;
        const ended = self.session.run(core, .cont) catch return reverse_watch.Error.ReplayFailed;
        if (ended != .count and ended != .stop) break;
    }
}

pub fn watchSearchSlice(self: *Transport, rc: *reverse_mod.Rc) !?api.Ended {
    if (rc.start) return .{ .stop = .history_start };
    if (self.job == null or self.cancelled) return Error.Cancelled;

    const base_cp = switch (rc.base) {
        .checkpoint => |c| c,
        .current => {
            try self.restoreBase(rc.origin);
            return .{ .stop = .history_start };
        },
        // The window only sees breakpoints: a watch searches from the
        // checkpoint behind it, the one the queue kept as `prior`.
        .window => if (rc.prior) |prior| prior.checkpoint else {
            try self.restoreBase(rc.origin);
            return .{ .stop = .history_start };
        },
    };

    const gpa = std.heap.page_allocator;
    const cps = [_]reverse_watch.Checkpoint{.{
        .position = base_cp.position,
        .id = base_cp.id,
        .object = base_cp.object,
        .touched = base_cp.touched,
    }};

    const port: reverse_watch.Port = .{
        .context = self,
        .replay = replaySession,
        .cancelled = isTransportCancelled,
        .compare = transportComparePositions,
    };
    const query: reverse_watch.Query = .{
        .range = rc.range,
        .from = rc.upper,
        .value_change_only = false,
    };
    const res = reverse_watch.search(gpa, port, query, &cps) catch |err| switch (err) {
        error.Cancelled => return Error.Cancelled,
        else => return Error.HistoryBroken,
    };

    switch (res.outcome) {
        .hit => |hit| {
            rc.watch_hit = hit;
            rc.found = hit.position;
            rc.landing = true;
            rc.landing_restored = false;
            return null;
        },
        .history_start, .no_base => {
            if (rc.prior) |earlier| {
                return reverse_mod.fallback(self, rc, earlier);
            }
            try self.restoreBase(rc.origin);
            return .{ .stop = .history_start };
        },
    }
}

pub fn landingSlice(self: *Transport, rc: *reverse_mod.Rc, grid: anytype) !?api.Ended {
    const hit = rc.watch_hit orelse return error.NoHit;
    const found = rc.found orelse return error.NoHit;
    const at = self.session.comparePositions(grid.at, found) catch return error.OtherLine;
    if (at == .gt) return error.OtherLine;
    if (at == .eq) return try watchStop(self, hit);
    if (grid.at.r == found.r) {
        if (found.phase == .cpu0 and grid.at.phase == .cpu0 and found.o > grid.at.o) {
            try self.session.setRunBudget(api.Core.cpu0, found.o - grid.at.o);
        } else if (found.phase == .cpu1 and grid.at.phase == .cpu1 and found.o > grid.at.o) {
            try self.session.setRunBudget(api.Core.cpu1, found.o - grid.at.o);
        } else if (found.phase == .board or (found.phase == .cpu1 and grid.at.phase == .cpu0)) {
            // Persistent history is single-core (armCheckpoints enforces Error.SecondCore);
            // reaching .board phase requires running CPU0 to the end of its turn to trigger
            // the boundary transition to board phase.
            const edge = self.session.live.boundary orelse return error.NoGrid;
            const w = session_root.zig.boundary.widthOf(edge);
            if (w > grid.at.o) try self.session.setRunBudget(api.Core.cpu0, w - grid.at.o);
        }
    }
    const target_core = if (grid.at.phase == .cpu1) api.Core.cpu1 else api.Core.cpu0;
    _ = try self.session.run(target_core, .cont);
    const landed = self.session.comparePositions(grid.at, found) catch return error.OtherLine;
    if (landed == .eq) return try watchStop(self, hit);
    if (landed == .gt) return error.OtherLine;
    return null;
}

pub fn watchStop(self: *Transport, hit: reverse_watch.Hit) !api.Ended {
    const slot = matchingWatch(self.session, hit.address, hit.len) orelse return error.NoHit;
    return .{ .stop = .{ .watchpoint = .{ .id = slot.id, .address = hit.address, .width = @intCast(hit.len), .access = .write } } };
}

fn checkWatches(session: *api.Session, address: ?u32, len: u32, out_range: ?*reverse_watch.Range) ?watch_table.Slot {
    if (address) |addr| return session.matchingWatch(addr, len);
    var min_first: ?u32 = null;
    var max_last: u32 = 0;
    const cores = [_]api.Core{ .cpu0, .cpu1 };
    const count: usize = if (session.hasCore(.cpu1)) 2 else 1;
    for (cores[0..count]) |c| {
        const m = session.machine(c) catch continue;
        for (m.watches.entries()) |slot| {
            if (!slot.enabled or !slot.watch.kind.covers(.write)) continue;
            if (min_first == null or slot.watch.first < min_first.?) min_first = slot.watch.first;
            if (slot.watch.last > max_last) max_last = slot.watch.last;
        }
    }
    if (out_range) |r| if (min_first) |first| {
        r.* = .{ .address = first, .size = (max_last - first) +| 1 };
    };
    return null;
}

pub fn armedWriteRange(session: *api.Session) ?reverse_watch.Range {
    var r: reverse_watch.Range = .{ .address = 0, .size = 0 };
    _ = checkWatches(session, null, 0, &r);
    return if (r.size > 0) r else null;
}

pub fn matchingWatch(session: *api.Session, address: u32, len: u32) ?watch_table.Slot {
    return checkWatches(session, address, len, null);
}

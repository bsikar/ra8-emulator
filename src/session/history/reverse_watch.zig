//! Reverse watch: the latest write to a watched range before the cursor,
//! found by replaying checkpoint intervals backward.
//!
//! The search is a pure session-layer engine over a narrow port. The port
//! knows how to restore a checkpoint and replay forward to a position with
//! a write observer armed on the range, reporting every write in execution
//! order, whoever drove it: either core, a board-phase initiator or an
//! untimed writer. The engine owns the interval order and the choice of
//! the latest hit.
//!
//! Watch semantics: every reported write is a hit, including one that
//! stores the bytes already there. Only a query that asks for value
//! changes drops unchanged writes, and only that query may skip an
//! interval in which none of the watched pages was written at all, as the
//! checkpoint engine recorded it (value_bisect.zig).
//!
//! The intervals run [C_k, end) newest first, where end is the cursor for
//! the newest and the next checkpoint for the others. A hit lies strictly
//! before its interval's end. With no hit anywhere the search ends at the
//! start of the line: the oldest checkpoint on the line is its base.
const std = @import("std");
const position_mod = @import("position.zig");
const trail = @import("trail.zig");
const bisect = @import("value_bisect.zig");
const Initiator = @import("ra8_chip").core.cpu.memory.initiator.Initiator;

pub const Position = position_mod.Position;
pub const PageKey = bisect.PageKey;

pub const Error = error{ Cancelled, ReplayFailed, OutOfMemory };

/// The guest address range being watched.
pub const Range = struct {
    address: u32,
    size: u32,

    pub fn overlaps(self: Range, address: u32, len: u32) bool {
        const from: u64 = self.address;
        const to = from + self.size;
        const start: u64 = address;
        return start < to and start + len > from;
    }
};

/// One write the replay observed.
pub const Write = struct {
    /// Where the write lands: a core write sits in its slot's retire gap.
    position: Position,
    address: u32,
    len: u32,
    initiator: Initiator,
    source: trail.Source,
    /// Whether the bytes differ from what was there before.
    changed: bool,
};

/// The latest write, which is where reverse-continue stops.
pub const Hit = Write;

/// A checkpoint on some line. `touched` is the engine's record of the
/// pages written since the previous capture, that is, across the interval
/// that ends here. Without one that interval is replayed, never skipped.
pub const Checkpoint = struct {
    position: Position,
    id: u32,
    object: [16]u8 = @splat(0),
    touched: ?*const bisect.Touched = null,
};

/// What a replay reports into. The port calls `report` for each write it
/// sees on the armed range, in execution order.
pub const Sink = struct {
    range: Range,
    start: Position,
    until: Position,
    value_change_only: bool,
    best: ?Hit = null,
    /// Writes the port reported that were outside the range, the interval
    /// or the line.
    ignored: u32 = 0,
    port: ?Port = null,

    pub fn order(self: Sink, a: Position, b: Position) !std.math.Order {
        if (self.port) |p| return p.order(a, b);
        return position_mod.compare(a, b);
    }

    pub fn report(self: *Sink, write: Write) void {
        if (!self.range.overlaps(write.address, write.len)) return self.drop();
        if (self.value_change_only and !write.changed) return;
        const before_end = self.order(write.position, self.until) catch return self.drop();
        const after_start = self.order(write.position, self.start) catch return self.drop();
        if (before_end != .lt or after_start == .lt) return self.drop();
        // Execution order is position order; an equal position (two writes
        // in one slot) goes to the later one.
        if (self.best) |held| {
            const ord = self.order(write.position, held.position) catch return self.drop();
            if (ord == .lt) return;
        }
        self.best = write;
    }

    fn drop(self: *Sink) void {
        self.ignored += 1;
    }
};

/// The two things the engine needs from the machine, and nothing else.
pub const Port = struct {
    context: *anyopaque,
    /// Restores `base`, runs forward with a write observer armed on
    /// `range`, and stops before `until`, reporting into `sink`. Replay is
    /// silent: it drives no host output.
    replay: *const fn (context: *anyopaque, base: Checkpoint, until: Position, range: Range, sink: *Sink) Error!void,
    /// Polled between intervals; true cancels the search.
    cancelled: ?*const fn (context: *anyopaque) bool = null,
    /// Line-aware position comparator across fork lines.
    compare: ?*const fn (context: *anyopaque, a: Position, b: Position) anyerror!std.math.Order = null,
    compare_context: ?*anyopaque = null,

    pub fn order(self: Port, a: Position, b: Position) !std.math.Order {
        if (self.compare) |cmp| {
            return cmp(self.compare_context orelse self.context, a, b);
        }
        return position_mod.compare(a, b);
    }
};

pub const Query = struct {
    range: Range,
    /// The cursor. The result is strictly before it.
    from: Position,
    /// Only writes that change the bytes count, and an interval in which
    /// the watched pages were never written may be skipped.
    value_change_only: bool = false,
    /// The pages covering `range`, resolved by the caller. Empty means no
    /// interval can be skipped.
    pages: []const PageKey = &.{},
    /// The pages written from the newest checkpoint before the cursor up
    /// to the cursor, as the live write tracker holds them; its `since`
    /// must be that checkpoint's id. Null means that interval is replayed.
    cursor_touched: ?*const bisect.Touched = null,
};

pub const Outcome = union(enum) {
    hit: Hit,
    /// No write anywhere back to the start of the line.
    history_start,
    /// No checkpoint before the cursor on its line: there is no base to
    /// replay from yet (the reverse window's undo base is still to land).
    no_base,
};

pub const Result = struct {
    outcome: Outcome,
    replayed: u32 = 0,
    skipped: u32 = 0,
};

/// Searches backward from `query.from` over the line's checkpoints, any
/// order. Checkpoints on another line are not candidates.
pub fn search(
    allocator: std.mem.Allocator,
    port: Port,
    query: Query,
    checkpoints: []const Checkpoint,
) Error!Result {
    const line = try lineCheckpoints(allocator, query.from, checkpoints, port);
    defer allocator.free(line);
    if (line.len == 0) return .{ .outcome = .no_base };

    var result: Result = .{ .outcome = .history_start };
    for (line, 0..) |base, i| {
        if (port.cancelled) |poll| if (poll(port.context)) return Error.Cancelled;
        const end_cp: ?Checkpoint = if (i == 0) null else line[i - 1];
        const until = if (end_cp) |cp| cp.position else query.from;
        if (canSkip(query, base, end_cp)) {
            result.skipped += 1;
            continue;
        }
        var sink: Sink = .{
            .range = query.range,
            .start = base.position,
            .until = until,
            .value_change_only = query.value_change_only,
            .port = port,
        };
        try port.replay(port.context, base, until, query.range, &sink);
        result.replayed += 1;
        if (sink.best) |hit| {
            result.outcome = .{ .hit = hit };
            return result;
        }
    }
    return result;
}

const LineSorter = struct {
    port: Port,

    fn newer(self: @This(), a: Checkpoint, b: Checkpoint) bool {
        const order = self.port.order(a.position, b.position) catch return false;
        return order == .gt;
    }
};

/// The checkpoints strictly before the cursor on its line, newest first.
fn lineCheckpoints(allocator: std.mem.Allocator, from: Position, all: []const Checkpoint, port: Port) ![]Checkpoint {
    var list: std.ArrayList(Checkpoint) = .empty;
    errdefer list.deinit(allocator);
    for (all) |cp| {
        const order = port.order(cp.position, from) catch continue;
        if (order == .lt) try list.append(allocator, cp);
    }
    std.mem.sort(Checkpoint, list.items, LineSorter{ .port = port }, LineSorter.newer);
    return list.toOwnedSlice(allocator);
}

/// Whether the interval [base, end) wrote none of the watched pages.
/// `end_cp` null means the interval ends at the cursor.
fn canSkip(query: Query, base: Checkpoint, end_cp: ?Checkpoint) bool {
    if (!query.value_change_only) return false;
    const record = if (end_cp) |cp| cp.touched else query.cursor_touched;
    return bisect.untouched(record, base.id, query.pages);
}

//! Covers src/session/history/reverse_watch.zig: the latest write before
//! the cursor across checkpoint intervals, writes from either core and the
//! board, unchanged writes as watch hits, value-bisection skips, and the
//! outcomes with no base or no hit.
const std = @import("std");
const ra8 = @import("ra8");
const rw = ra8.session.history_reverse_watch;
const Position = ra8.chip.core.scheduler.Position;
const Initiator = ra8.chip.core.cpu.memory.initiator.Initiator;

fn at(r: u64, phase: ra8.chip.core.scheduler.position.Phase, o: u32) Position {
    return .{ .r = r, .phase = phase, .o = o, .gap = .retired };
}

const watched: rw.Range = .{ .address = 0x2000_0100, .size = 4 };

fn write(position: Position, initiator: Initiator, changed: bool) rw.Write {
    const source: ra8.session.history_trail.Source = switch (initiator) {
        .cpu0 => .{ .core = .{ .core = .cpu0, .slots = position.o } },
        .cpu1 => .{ .core = .{ .core = .cpu1, .slots = position.o } },
        else => .{ .board = initiator },
    };
    return .{
        .position = position,
        .address = watched.address,
        .len = 4,
        .initiator = initiator,
        .source = source,
        .changed = changed,
    };
}

/// A scripted machine: every write it will ever perform, in execution
/// order, and the page bytes the cursor state holds.
const Machine = struct {
    writes: []const rw.Write,
    replays: u32 = 0,
    cancel_after: ?u32 = null,

    fn port(self: *Machine) rw.Port {
        return .{ .context = self, .replay = replay, .cancelled = cancelled };
    }

    fn replay(ctx: *anyopaque, base: rw.Checkpoint, until: Position, range: rw.Range, sink: *rw.Sink) rw.Error!void {
        const self: *Machine = @ptrCast(@alignCast(ctx));
        self.replays += 1;
        _ = until;
        // A faithful port runs from the base; the scripted one reports
        // every write at or after the base, even past the interval's end,
        // and leaves the engine to bound them.
        for (self.writes) |w| {
            const order = Position.order(w.position, base.position) orelse continue;
            if (order == .lt) continue;
            if (range.overlaps(w.address, w.len)) sink.report(w);
        }
    }

    fn cancelled(ctx: *anyopaque) bool {
        const self: *Machine = @ptrCast(@alignCast(ctx));
        return if (self.cancel_after) |n| self.replays >= n else false;
    }
};

fn cps(comptime rounds: []const u64) [rounds.len]rw.Checkpoint {
    var out: [rounds.len]rw.Checkpoint = undefined;
    for (rounds, 0..) |r, i| out[i] = .{ .position = .{ .r = r }, .id = @intCast(i) };
    return out;
}

test "finds the last write before the cursor, not a later one or the first" {
    const writes = [_]rw.Write{
        write(at(22, .cpu0, 3), .cpu0, true),
        write(at(23, .cpu0, 5), .cpu0, true),
        write(at(24, .cpu0, 9), .cpu0, true),
        // At and past the cursor: not before it.
        write(at(25, .cpu0, 0), .cpu0, true),
        write(at(26, .cpu0, 2), .cpu0, true),
    };
    var m: Machine = .{ .writes = &writes };
    const list = cps(&.{ 0, 10, 20 });
    const res = try rw.search(std.testing.allocator, m.port(), .{ .range = watched, .from = .{ .r = 25 } }, &list);
    try std.testing.expectEqual(@as(u64, 24), res.outcome.hit.position.r);
    try std.testing.expectEqual(@as(u32, 9), res.outcome.hit.position.o);
    try std.testing.expectEqual(@as(u32, 1), res.replayed);
}

test "a write exactly at the cursor is not a hit" {
    const writes = [_]rw.Write{write(at(25, .cpu0, 0), .cpu0, true)};
    var m: Machine = .{ .writes = &writes };
    const list = cps(&.{ 0, 20 });
    const res = try rw.search(std.testing.allocator, m.port(), .{ .range = watched, .from = .{ .r = 25 } }, &list);
    try std.testing.expect(res.outcome == .history_start);
}

test "the other core's write later in a round wins over the first core's" {
    const writes = [_]rw.Write{
        write(at(24, .cpu0, 4), .cpu0, true),
        write(at(24, .cpu1, 2), .cpu1, true),
    };
    var m: Machine = .{ .writes = &writes };
    const list = cps(&.{ 0, 20 });
    const res = try rw.search(std.testing.allocator, m.port(), .{ .range = watched, .from = .{ .r = 25 } }, &list);
    const hit = res.outcome.hit;
    try std.testing.expectEqual(Initiator.cpu1, hit.initiator);
    try std.testing.expectEqual(ra8.session.history_trail.Core.cpu1, hit.source.core.core);
    try std.testing.expectEqual(@as(u32, 2), hit.position.o);
}

test "a board initiator's write lands after both cores in its round" {
    const writes = [_]rw.Write{
        write(at(24, .cpu0, 4), .cpu0, true),
        write(at(24, .cpu1, 6), .cpu1, true),
        write(at(24, .board, 1), .dmac, true),
    };
    var m: Machine = .{ .writes = &writes };
    const list = cps(&.{ 0, 20 });
    const res = try rw.search(std.testing.allocator, m.port(), .{ .range = watched, .from = .{ .r = 25 } }, &list);
    const hit = res.outcome.hit;
    try std.testing.expectEqual(Initiator.dmac, hit.initiator);
    try std.testing.expectEqual(Initiator.dmac, hit.source.board);
}

test "two writes in one slot report the later one" {
    const writes = [_]rw.Write{
        write(at(24, .cpu0, 4), .cpu0, true),
        write(at(24, .cpu0, 4), .cpu0, false),
    };
    var m: Machine = .{ .writes = &writes };
    const list = cps(&.{0});
    const res = try rw.search(std.testing.allocator, m.port(), .{ .range = watched, .from = .{ .r = 25 } }, &list);
    try std.testing.expect(!res.outcome.hit.changed);
}

test "no write at all runs every interval and ends at the start of the line" {
    var m: Machine = .{ .writes = &.{} };
    const list = cps(&.{ 0, 10, 20 });
    const res = try rw.search(std.testing.allocator, m.port(), .{ .range = watched, .from = .{ .r = 25 } }, &list);
    try std.testing.expect(res.outcome == .history_start);
    try std.testing.expectEqual(@as(u32, 3), res.replayed);
    try std.testing.expectEqual(@as(u32, 0), res.skipped);
}

test "a write to a different range is never a hit" {
    var other = write(at(24, .cpu0, 4), .cpu0, true);
    other.address = watched.address + 0x100;
    const writes = [_]rw.Write{other};
    var m: Machine = .{ .writes = &writes };
    const list = cps(&.{0});
    const res = try rw.search(std.testing.allocator, m.port(), .{ .range = watched, .from = .{ .r = 25 } }, &list);
    try std.testing.expect(res.outcome == .history_start);
}

test "a write that straddles the range edge is a hit" {
    var edge = write(at(24, .cpu0, 4), .cpu0, true);
    edge.address = watched.address - 2;
    edge.len = 4;
    const writes = [_]rw.Write{edge};
    var m: Machine = .{ .writes = &writes };
    const list = cps(&.{0});
    const res = try rw.search(std.testing.allocator, m.port(), .{ .range = watched, .from = .{ .r = 25 } }, &list);
    try std.testing.expect(res.outcome == .hit);
}

test "a search crosses checkpoint boundaries back to the interval that wrote" {
    const writes = [_]rw.Write{
        write(at(3, .cpu0, 7), .cpu0, true),
        write(at(12, .cpu1, 1), .cpu1, true),
    };
    var m: Machine = .{ .writes = &writes };
    const list = cps(&.{ 0, 10, 20, 30 });
    // From round 35: intervals [30,35) [20,30) [10,20) each replay empty,
    // then [10,20) holds the round-12 write.
    const res = try rw.search(std.testing.allocator, m.port(), .{ .range = watched, .from = .{ .r = 35 } }, &list);
    try std.testing.expectEqual(@as(u64, 12), res.outcome.hit.position.r);
    try std.testing.expectEqual(@as(u32, 3), res.replayed);
    // The older write is reachable once the newer one is behind the cursor.
    const res2 = try rw.search(std.testing.allocator, m.port(), .{ .range = watched, .from = .{ .r = 12 } }, &list);
    try std.testing.expectEqual(@as(u64, 3), res2.outcome.hit.position.r);
}

test "an interval's write after its end belongs to the next interval" {
    // The write at round 21 is after checkpoint 20 but the cursor is 25:
    // the newest interval [20,25) owns it, and [10,20) never sees it.
    const writes = [_]rw.Write{write(at(21, .cpu0, 1), .cpu0, true)};
    var m: Machine = .{ .writes = &writes };
    const list = cps(&.{ 0, 10, 20 });
    const res = try rw.search(std.testing.allocator, m.port(), .{ .range = watched, .from = .{ .r = 25 } }, &list);
    try std.testing.expectEqual(@as(u32, 1), res.replayed);
    try std.testing.expectEqual(@as(u64, 21), res.outcome.hit.position.r);
}

test "an unchanged write is a watch hit, and not a value change" {
    const writes = [_]rw.Write{
        write(at(5, .cpu0, 2), .cpu0, true),
        write(at(24, .cpu0, 4), .cpu0, false),
    };
    var m: Machine = .{ .writes = &writes };
    const list = cps(&.{ 0, 10, 20 });
    const watch = try rw.search(std.testing.allocator, m.port(), .{ .range = watched, .from = .{ .r = 25 } }, &list);
    try std.testing.expectEqual(@as(u64, 24), watch.outcome.hit.position.r);
    try std.testing.expect(!watch.outcome.hit.changed);

    m.replays = 0;
    const change = try rw.search(std.testing.allocator, m.port(), .{
        .range = watched,
        .from = .{ .r = 25 },
        .value_change_only = true,
    }, &list);
    try std.testing.expectEqual(@as(u64, 5), change.outcome.hit.position.r);
}

const key: rw.PageKey = .{ .space = .cpu0_sram, .page_index = 0 };
const Touched = ra8.session.history_touched_pages.Touched;

/// A record of the pages written across one interval: the watched page
/// when `wrote`, some other page otherwise.
fn record(since: u32, wrote: bool) !Touched {
    var dirty = try ra8.session.history_dirty_pages.DirtyPages.init(std.testing.allocator);
    defer dirty.deinit();
    dirty.markDirty(.cpu0_sram, if (wrote) 0 else 7);
    return Touched.fromDirty(std.testing.allocator, since, &dirty);
}

test "value bisection skips untouched intervals and replays the one written" {
    // Checkpoints 0,10,20,30 are ids 0..3. The page is written only in
    // [10,20), recorded on checkpoint 2 (since 1).
    var t1 = try record(0, false);
    defer t1.deinit();
    var t2 = try record(1, true);
    defer t2.deinit();
    var t3 = try record(2, false);
    defer t3.deinit();
    var cursor = try record(3, false);
    defer cursor.deinit();
    var list = cps(&.{ 0, 10, 20, 30 });
    list[1].touched = &t1;
    list[2].touched = &t2;
    list[3].touched = &t3;

    const writes = [_]rw.Write{write(at(14, .cpu0, 3), .cpu0, true)};
    var m: Machine = .{ .writes = &writes };
    const res = try rw.search(std.testing.allocator, m.port(), .{
        .range = watched,
        .from = .{ .r = 35 },
        .value_change_only = true,
        .pages = &.{key},
        .cursor_touched = &cursor,
    }, &list);
    try std.testing.expectEqual(@as(u64, 14), res.outcome.hit.position.r);
    // [30,35) and [20,30) were never written: skipped, not replayed.
    try std.testing.expectEqual(@as(u32, 2), res.skipped);
    try std.testing.expectEqual(@as(u32, 1), m.replays);
}

test "a change and change-back inside one interval is found" {
    // The page holds the same bytes at both ends of [10,20) (A to B to A),
    // so equal contents would skip it; the write record marks it touched,
    // and the change-back write is the last change.
    var t2 = try record(1, true);
    defer t2.deinit();
    var list = cps(&.{ 0, 10, 20 });
    list[2].touched = &t2;
    const writes = [_]rw.Write{
        write(at(12, .cpu0, 2), .cpu0, true), // A to B
        write(at(16, .cpu0, 5), .cpu0, true), // B back to A
    };
    var m: Machine = .{ .writes = &writes };
    var cursor = try record(2, false);
    defer cursor.deinit();
    const res = try rw.search(std.testing.allocator, m.port(), .{
        .range = watched,
        .from = .{ .r = 25 },
        .value_change_only = true,
        .pages = &.{key},
        .cursor_touched = &cursor,
    }, &list);
    try std.testing.expectEqual(@as(u64, 16), res.outcome.hit.position.r);
    try std.testing.expectEqual(@as(u32, 1), res.skipped);
}

test "a plain watch never skips an interval, whatever the record says" {
    var t1 = try record(0, false);
    defer t1.deinit();
    var cursor = try record(1, false);
    defer cursor.deinit();
    var list = cps(&.{ 0, 20 });
    list[1].touched = &t1;
    // An unchanged write inside an interval the record calls untouched.
    const writes = [_]rw.Write{write(at(5, .cpu0, 2), .cpu0, false)};
    var m: Machine = .{ .writes = &writes };
    const res = try rw.search(std.testing.allocator, m.port(), .{
        .range = watched,
        .from = .{ .r = 25 },
        .pages = &.{key},
        .cursor_touched = &cursor,
    }, &list);
    try std.testing.expectEqual(@as(u32, 0), res.skipped);
    try std.testing.expectEqual(@as(u64, 5), res.outcome.hit.position.r);
}

test "a missing dirty record replays the interval" {
    var m: Machine = .{ .writes = &.{} };
    const list = cps(&.{ 0, 20 });
    const res = try rw.search(std.testing.allocator, m.port(), .{
        .range = watched,
        .from = .{ .r = 25 },
        .value_change_only = true,
        .pages = &.{key},
    }, &list);
    try std.testing.expectEqual(@as(u32, 0), res.skipped);
    try std.testing.expectEqual(@as(u32, 2), res.replayed);
}

test "a record that starts at another checkpoint replays the interval" {
    // A checkpoint between was thinned: the record on the round-20
    // checkpoint says since 1, but its base is checkpoint 0.
    var t = try record(1, false);
    defer t.deinit();
    var list = cps(&.{ 0, 20 });
    list[1].id = 2;
    list[1].touched = &t;
    var m: Machine = .{ .writes = &.{} };
    const res = try rw.search(std.testing.allocator, m.port(), .{
        .range = watched,
        .from = .{ .r = 25 },
        .value_change_only = true,
        .pages = &.{key},
    }, &list);
    try std.testing.expectEqual(@as(u32, 0), res.skipped);
}

test "no checkpoint before the cursor is no base" {
    var m: Machine = .{ .writes = &.{} };
    const list = cps(&.{ 30, 40 });
    const res = try rw.search(std.testing.allocator, m.port(), .{ .range = watched, .from = .{ .r = 25 } }, &list);
    try std.testing.expect(res.outcome == .no_base);
    try std.testing.expectEqual(@as(u32, 0), m.replays);
}

test "checkpoints on another line are not candidates" {
    var other: [1]rw.Checkpoint = .{.{ .position = .{ .branch = 7, .r = 10 }, .id = 9 }};
    var m: Machine = .{ .writes = &.{} };
    const res = try rw.search(std.testing.allocator, m.port(), .{ .range = watched, .from = .{ .r = 25 } }, &other);
    try std.testing.expect(res.outcome == .no_base);
}

test "cancel between intervals stops the search" {
    var m: Machine = .{ .writes = &.{}, .cancel_after = 1 };
    const list = cps(&.{ 0, 10, 20 });
    try std.testing.expectError(rw.Error.Cancelled, rw.search(std.testing.allocator, m.port(), .{ .range = watched, .from = .{ .r = 25 } }, &list));
    try std.testing.expectEqual(@as(u32, 1), m.replays);
}

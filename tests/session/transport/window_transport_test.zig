//! Transport fast-base integration tests (Slice 21.4):
//! Forward motion inside the window is redo, backward step and reverse-continue
//! inside the window use undo, and latencies are measured.

const std = @import("std");
const ra8 = @import("ra8");
const rig_mod = @import("../history/window_rig.zig");
const transport = ra8.session.transport;
const engine = ra8.session.history_window_engine;
const rebuild = ra8.session.history_window_rebuild;
const seek_engine = ra8.session.history_seek_engine;
const api = ra8.session.api;

const slots: usize = 200;

const FakeWall = struct {
    now_ns: u64 = 0,
    fn now(context: *anyopaque) u64 {
        const self: *FakeWall = @ptrCast(@alignCast(context));
        self.now_ns += 1_000_000;
        return self.now_ns;
    }
    fn wall(self: *FakeWall) transport.Wall {
        return .{ .context = self, .nowFn = now };
    }
};

fn buildWindow(rig: *rig_mod.Rig, straight: *const rig_mod.Straight) !engine.ReverseWindow {
    try rig.port().restoreFull(straight.base);
    var w = rig.window(64 * 1024 * 1024);
    errdefer w.deinit();
    try rebuild.run(&w, .{ .base = .{ .bytes = straight.base }, .end = straight.positions[slots] });
    return w;
}

const BridgeCtx = struct {
    session: *api.Session,
    facts_storage: seek_engine.Facts = undefined,

    fn factsFn(context: *anyopaque) anyerror!seek_engine.Facts {
        const self: *BridgeCtx = @ptrCast(@alignCast(context));
        const grid = self.session.grid orelse return error.NoGrid;
        const win_facts: ?seek_engine.WindowFacts = if (self.session.window) |w| .{
            .start = w.start().?,
            .end = w.end().?,
            .at = w.at().?,
            .line = w.line,
            .slots = w.count(),
        } else null;
        self.facts_storage = .{
            .current = grid.at,
            .checkpoints = &.{},
            .window = win_facts,
        };
        return self.facts_storage;
    }

    fn restoreFn(context: *anyopaque, object: []const u8) anyerror!void {
        _ = context;
        _ = object;
    }
};

const Harness = struct {
    rig: rig_mod.Rig,
    straight: rig_mod.Straight,
    w: engine.ReverseWindow,
    bridge_ctx: BridgeCtx,
    t: transport.Transport,
    wall: FakeWall = .{},

    fn open(self: *Harness) !void {
        try self.rig.open(std.testing.allocator);
        errdefer self.rig.deinit();
        self.straight = try rig_mod.Straight.record(&self.rig, slots);
        errdefer self.straight.deinit();
        self.w = try buildWindow(&self.rig, &self.straight);
        const session = self.rig.opened.session();
        session.attachWindow(&self.w);
        self.bridge_ctx = .{ .session = session };
        self.t = .{
            .session = session,
            .history = .{
                .context = &self.bridge_ctx,
                .facts = BridgeCtx.factsFn,
                .restore = BridgeCtx.restoreFn,
            },
        };
        self.wall = .{};
    }

    fn deinit(self: *Harness) void {
        self.w.deinit();
        self.straight.deinit();
        self.rig.deinit();
    }
};

test "transport backward step inside window uses undo and measures latency" {
    var h: Harness = undefined;
    try h.open();
    defer h.deinit();

    const t0 = std.Io.Timestamp.now(std.testing.io, .awake);
    const ticket = try h.t.command(.{ .step = .{ .core = .cpu0, .count = 1, .dir = .back } });
    const ended = try h.t.finish(ticket, h.wall.wall(), null);
    const elapsed_ns: u64 = @intCast(@max(0, t0.untilNow(std.testing.io, .awake).nanoseconds));
    std.debug.print("\n[evidence] reverse-step latency: {d} ns ({d:.3} ms)\n", .{ elapsed_ns, @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0 });

    try std.testing.expectEqual(api.Ended{ .stop = .stepped }, ended);
    try std.testing.expectEqual(slots - 1, h.w.cursor());
    try std.testing.expectEqualSlices(u8, &h.straight.digests[slots - 1], &try h.rig.digest());
}

test "transport forward step inside window uses redo" {
    var h: Harness = undefined;
    try h.open();
    defer h.deinit();

    try h.w.walkTo(slots - 5);
    try std.testing.expectEqual(slots - 5, h.w.cursor());
    try std.testing.expectEqualSlices(u8, &h.straight.digests[slots - 5], &try h.rig.digest());

    const ticket = try h.t.command(.{ .step = .{ .core = .cpu0, .count = 2, .dir = .fwd } });
    const ended = try h.t.finish(ticket, h.wall.wall(), null);

    try std.testing.expectEqual(api.Ended{ .stop = .stepped }, ended);
    try std.testing.expectEqual(slots - 3, h.w.cursor());
    try std.testing.expectEqualSlices(u8, &h.straight.digests[slots - 3], &try h.rig.digest());
}

test "transport seek inside window uses window base and measures nearby seek latency" {
    var h: Harness = undefined;
    try h.open();
    defer h.deinit();

    // Seek backward 60 slots from 200 to 140
    const target_60 = h.straight.positions[140];
    var seek_buf: [64]u8 = undefined;
    const text_60 = try std.fmt.bufPrint(&seek_buf, "{d}:{d}:{s}:{d}:{s}", .{
        target_60.branch,
        target_60.r,
        @tagName(target_60.phase),
        target_60.o,
        @tagName(target_60.gap),
    });

    const t0 = std.Io.Timestamp.now(std.testing.io, .awake);
    const ticket_60 = try h.t.command(.{ .seek = .{ .target = text_60 } });
    _ = try h.t.finish(ticket_60, h.wall.wall(), null);
    const ns_60: u64 = @intCast(@max(0, t0.untilNow(std.testing.io, .awake).nanoseconds));
    std.debug.print("\n[evidence] nearby seek latency (60 slots): {d} ns ({d:.3} ms)\n", .{ ns_60, @as(f64, @floatFromInt(ns_60)) / 1_000_000.0 });
    try std.testing.expectEqual(@as(usize, 140), h.w.cursor());
    try std.testing.expectEqualSlices(u8, &h.straight.digests[140], &try h.rig.digest());

    // Seek backward 140 slots from 140 to 0 (large seek)
    const target_large = h.straight.positions[0];
    const text_large = try std.fmt.bufPrint(&seek_buf, "{d}:{d}:{s}:{d}:{s}", .{
        target_large.branch,
        target_large.r,
        @tagName(target_large.phase),
        target_large.o,
        @tagName(target_large.gap),
    });

    const t1 = std.Io.Timestamp.now(std.testing.io, .awake);
    const ticket_large = try h.t.command(.{ .seek = .{ .target = text_large } });
    _ = try h.t.finish(ticket_large, h.wall.wall(), null);
    const ns_large: u64 = @intCast(@max(0, t1.untilNow(std.testing.io, .awake).nanoseconds));
    std.debug.print("\n[evidence] large seek latency (140 slots): {d} ns ({d:.3} ms)\n", .{ ns_large, @as(f64, @floatFromInt(ns_large)) / 1_000_000.0 });
    try std.testing.expectEqual(@as(usize, 0), h.w.cursor());
    try std.testing.expectEqualSlices(u8, &h.straight.digests[0], &try h.rig.digest());
}

test "transport reverse-continue inside window uses undo and stops on armed breakpoint" {
    var h: Harness = undefined;
    try h.open();
    defer h.deinit();

    try h.w.walkTo(30);
    const session = h.rig.opened.session();
    const hit_pc = try session.register(.cpu0, .pc);
    const point = try session.setBreakpoint(.cpu0, .{ .address = hit_pc });

    try h.w.walkTo(33);

    const rc_ticket = try h.t.command(.rcont);
    const ended = try h.t.finish(rc_ticket, h.wall.wall(), null);

    try std.testing.expectEqual(api.Ended{ .stop = .{ .breakpoint = point } }, ended);
    try std.testing.expectEqual(@as(usize, 30), h.w.cursor());
    try std.testing.expectEqualSlices(u8, &h.straight.digests[30], &try h.rig.digest());
}

test "transport forward continue redo inside window stops on armed data watchpoint" {
    var h: Harness = undefined;
    try h.open();
    defer h.deinit();

    try h.w.walkTo(20);
    const session = h.rig.opened.session();
    const watch = try session.setWatchpoint(.cpu0, .{
        .first = rig_mod.counter_addr,
        .last = rig_mod.counter_addr + 3,
        .kind = .write,
    });

    const cont_ticket = try h.t.command(.cont);
    const ended = try h.t.finish(cont_ticket, h.wall.wall(), null);

    switch (ended) {
        .stop => |s| switch (s) {
            .watchpoint => |hit| try std.testing.expectEqual(watch, hit.id),
            else => return error.TestExpectedWatchpointStop,
        },
        else => return error.TestExpectedStop,
    }
    try std.testing.expect(h.w.cursor() > 20);
}

test "stepSlice propagates canonical stepForward errors and falls back on OutsideWindow" {
    var h: Harness = undefined;
    try h.open();
    defer h.deinit();

    try h.w.walkTo(30);
    h.w.slotAt(30).kind = .complex;
    h.w.slotAt(30).digest[0] ^= 0x5a;

    const ticket_err = try h.t.command(.{ .step = .{ .core = .cpu0, .count = 1, .dir = .fwd } });
    try std.testing.expectError(error.HistoryDivergence, h.t.finish(ticket_err, h.wall.wall(), null));

    var h2: Harness = undefined;
    try h2.open();
    defer h2.deinit();
    try h2.w.walkTo(slots - 2);
    for ((slots - 2)..slots) |i| {
        h2.w.slotAt(i).core = .cpu1;
    }
    try std.testing.expect(h2.w.cursor() < h2.w.count());
    const ticket_live = try h2.t.command(.{ .step = .{ .core = .cpu0, .count = 1, .dir = .fwd } });
    const ended_live = try h2.t.finish(ticket_live, h2.wall.wall(), null);
    try std.testing.expectEqual(api.Ended{ .stop = .stepped }, ended_live);
    try std.testing.expectEqual(slots, h2.w.cursor());
}

test "redo watchpoint check skips component part records and handles overflow safely" {
    var table = ra8.session.watch.table.Table{};
    const watch = try table.add(try ra8.session.watch.table.Watch.span(0x2000_1000, 4, .write));

    var dummy: [4]u8 = @splat(0);
    const records = [_]ra8.session.history_window_trail.ByteSwapRecord{
        .{ .base = 0x2000_0000, .offset = 0x1_0000_2000, .part = 1, .data = &dummy },
        .{ .base = 0xFFFF_FFF0, .offset = 0x20, .part = null, .data = &dummy },
        .{ .base = std.math.maxInt(u32), .offset = std.math.maxInt(u64), .part = null, .data = &dummy },
        .{ .base = 0x2000_0000, .offset = 0x1000, .part = null, .data = &dummy },
    };

    const hit = ra8.session.transport_play.checkWatchHit(&table, &records);
    try std.testing.expect(hit != null);
    try std.testing.expectEqual(watch, hit.?.id);
    try std.testing.expectEqual(@as(u32, 0x2000_1000), hit.?.address);
}

test "randomized interleavings of step and seek checked against straight digests" {
    var h: Harness = undefined;
    try h.open();
    defer h.deinit();

    var prng = std.Random.DefaultPrng.init(0xCAFE_BABE);
    const rand = prng.random();

    var oracle = ra8.session.history_shadow_oracle.ShadowOracle.init(std.testing.allocator);
    defer oracle.deinit();
    try oracle.trackStore(&h.rig.opened.state.cpu0.store.?);

    var cur: usize = slots;

    for (0..25) |_| {
        const prev_cur = cur;
        const op = rand.uintLessThan(u8, 3);
        switch (op) {
            0 => {
                if (cur > 0) {
                    const count = @min(cur, 1 + rand.uintLessThan(usize, 4));
                    const ticket = try h.t.command(.{ .step = .{ .core = .cpu0, .count = count, .dir = .back } });
                    _ = try h.t.finish(ticket, h.wall.wall(), null);
                    cur -= count;
                }
            },
            1 => {
                if (cur < slots) {
                    const count = @min(slots - cur, 1 + rand.uintLessThan(usize, 4));
                    const ticket = try h.t.command(.{ .step = .{ .core = .cpu0, .count = count, .dir = .fwd } });
                    _ = try h.t.finish(ticket, h.wall.wall(), null);
                    cur += count;
                }
            },
            2 => {
                const target_idx = rand.uintLessThan(usize, slots + 1);
                const target_pos = h.straight.positions[target_idx];
                var seek_buf: [64]u8 = undefined;
                const target_text = try std.fmt.bufPrint(&seek_buf, "{d}:{d}:{s}:{d}:{s}", .{
                    target_pos.branch,
                    target_pos.r,
                    @tagName(target_pos.phase),
                    target_pos.o,
                    @tagName(target_pos.gap),
                });
                const ticket = try h.t.command(.{ .seek = .{ .target = target_text } });
                _ = try h.t.finish(ticket, h.wall.wall(), null);
                cur = target_idx;
            },
            else => unreachable,
        }
        try std.testing.expectEqual(cur, h.w.cursor());
        try std.testing.expectEqualSlices(u8, &h.straight.digests[cur], &try h.rig.digest());

        const lo = @min(prev_cur, cur);
        const hi = @max(prev_cur, cur);
        var ranges: std.ArrayList(ra8.session.history_shadow_oracle.MemoryRange) = .empty;
        defer ranges.deinit(std.testing.allocator);
        var s = lo;
        while (s < hi) : (s += 1) {
            for (h.w.trail.slotAt(s).byte_records) |rec| {
                try ranges.append(std.testing.allocator, .{
                    .base = rec.base,
                    .offset = rec.offset,
                    .len = rec.data.len,
                });
            }
        }
        try oracle.verifySlot(ranges.items);
    }
}

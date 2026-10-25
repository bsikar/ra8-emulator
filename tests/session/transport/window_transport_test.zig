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

const slots: usize = 100;

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

test "transport backward step inside window uses undo and measures latency" {
    var rig: rig_mod.Rig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();

    var straight = try rig_mod.Straight.record(&rig, slots);
    defer straight.deinit();

    var w = try buildWindow(&rig, &straight);
    defer w.deinit();

    const session = rig.opened.session();
    session.attachWindow(&w);

    var bridge_ctx: BridgeCtx = .{ .session = session };
    var t = transport.Transport{
        .session = session,
        .history = .{
            .context = &bridge_ctx,
            .facts = BridgeCtx.factsFn,
            .restore = BridgeCtx.restoreFn,
        },
    };

    var wall = FakeWall{};
    const t0 = std.Io.Timestamp.now(std.testing.io, .awake);
    const ticket = try t.command(.{ .step = .{ .core = .cpu0, .count = 1, .dir = .back } });
    const ended = try t.finish(ticket, wall.wall(), null);
    const elapsed_ns: u64 = @intCast(@max(0, t0.untilNow(std.testing.io, .awake).nanoseconds));
    std.debug.print("\n[evidence] reverse-step latency: {d} ns ({d:.3} ms)\n", .{ elapsed_ns, @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0 });

    try std.testing.expectEqual(api.Ended{ .stop = .stepped }, ended);
    try std.testing.expectEqual(slots - 1, w.cursor());
    try std.testing.expectEqualSlices(u8, &straight.digests[slots - 1], &try rig.digest());
}

test "transport forward step inside window uses redo" {
    var rig: rig_mod.Rig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();

    var straight = try rig_mod.Straight.record(&rig, slots);
    defer straight.deinit();

    var w = try buildWindow(&rig, &straight);
    defer w.deinit();

    const session = rig.opened.session();
    session.attachWindow(&w);

    var bridge_ctx: BridgeCtx = .{ .session = session };
    var t = transport.Transport{
        .session = session,
        .history = .{
            .context = &bridge_ctx,
            .facts = BridgeCtx.factsFn,
            .restore = BridgeCtx.restoreFn,
        },
    };

    var wall = FakeWall{};
    // Walk back 5 slots
    try w.walkTo(slots - 5);
    try std.testing.expectEqual(slots - 5, w.cursor());
    try std.testing.expectEqualSlices(u8, &straight.digests[slots - 5], &try rig.digest());

    // Step forward 2 slots via transport
    const ticket = try t.command(.{ .step = .{ .core = .cpu0, .count = 2, .dir = .fwd } });
    const ended = try t.finish(ticket, wall.wall(), null);

    try std.testing.expectEqual(api.Ended{ .stop = .stepped }, ended);
    try std.testing.expectEqual(slots - 3, w.cursor());
    try std.testing.expectEqualSlices(u8, &straight.digests[slots - 3], &try rig.digest());
}

test "transport seek inside window uses window base and measures nearby seek latency" {
    var rig: rig_mod.Rig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();

    var straight = try rig_mod.Straight.record(&rig, slots);
    defer straight.deinit();

    var w = try buildWindow(&rig, &straight);
    defer w.deinit();

    const session = rig.opened.session();
    session.attachWindow(&w);

    var bridge_ctx: BridgeCtx = .{ .session = session };
    var t = transport.Transport{
        .session = session,
        .history = .{
            .context = &bridge_ctx,
            .facts = BridgeCtx.factsFn,
            .restore = BridgeCtx.restoreFn,
        },
    };

    var wall = FakeWall{};
    // Seek backward to slot 40
    const target_backward = straight.positions[40];
    var seek_buf: [64]u8 = undefined;
    const target_text = try std.fmt.bufPrint(&seek_buf, "{d}:{d}:{s}:{d}:{s}", .{
        target_backward.branch,
        target_backward.r,
        @tagName(target_backward.phase),
        target_backward.o,
        @tagName(target_backward.gap),
    });

    const t0 = std.Io.Timestamp.now(std.testing.io, .awake);
    const ticket = try t.command(.{ .seek = .{ .target = target_text } });
    const ended = try t.finish(ticket, wall.wall(), null);
    const elapsed_ns: u64 = @intCast(@max(0, t0.untilNow(std.testing.io, .awake).nanoseconds));
    std.debug.print("\n[evidence] nearby seek latency (60 slots): {d} ns ({d:.3} ms)\n", .{ elapsed_ns, @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0 });

    try std.testing.expectEqual(api.Ended.count, ended);
    try std.testing.expectEqual(@as(usize, 40), w.cursor());
    try std.testing.expectEqualSlices(u8, &straight.digests[40], &try rig.digest());

    // Now seek forward to slot 70 (uses redo)
    const target_forward = straight.positions[70];
    const forward_text = try std.fmt.bufPrint(&seek_buf, "{d}:{d}:{s}:{d}:{s}", .{
        target_forward.branch,
        target_forward.r,
        @tagName(target_forward.phase),
        target_forward.o,
        @tagName(target_forward.gap),
    });

    const fwd_ticket = try t.command(.{ .seek = .{ .target = forward_text } });
    const fwd_ended = try t.finish(fwd_ticket, wall.wall(), null);
    try std.testing.expectEqual(api.Ended.count, fwd_ended);
    try std.testing.expectEqual(@as(usize, 70), w.cursor());
    try std.testing.expectEqualSlices(u8, &straight.digests[70], &try rig.digest());
}

test "transport reverse-continue inside window uses undo and stops on armed breakpoint" {
    var rig: rig_mod.Rig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();

    var straight = try rig_mod.Straight.record(&rig, slots);
    defer straight.deinit();

    var w = try buildWindow(&rig, &straight);
    defer w.deinit();

    const session = rig.opened.session();
    session.attachWindow(&w);

    var bridge_ctx: BridgeCtx = .{ .session = session };
    var t = transport.Transport{
        .session = session,
        .history = .{
            .context = &bridge_ctx,
            .facts = BridgeCtx.factsFn,
            .restore = BridgeCtx.restoreFn,
        },
    };

    var wall = FakeWall{};
    // Walk to slot 30 to discover the PC at that slot
    try w.walkTo(30);
    const hit_pc = try session.register(.cpu0, .pc);
    const point = try session.setBreakpoint(.cpu0, .{ .address = hit_pc });

    // Move forward to slot 33 (within same 4-instruction iteration)
    try w.walkTo(33);

    // Reverse-continue: undoes backwards until hit_pc is reached at slot 30
    const rc_ticket = try t.command(.rcont);
    const ended = try t.finish(rc_ticket, wall.wall(), null);

    try std.testing.expectEqual(api.Ended{ .stop = .{ .breakpoint = point } }, ended);
    try std.testing.expectEqual(@as(usize, 30), w.cursor());
    try std.testing.expectEqualSlices(u8, &straight.digests[30], &try rig.digest());
}

test "randomized interleavings of step and seek checked against straight digests" {
    var rig: rig_mod.Rig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();

    var straight = try rig_mod.Straight.record(&rig, slots);
    defer straight.deinit();

    var w = try buildWindow(&rig, &straight);
    defer w.deinit();

    const session = rig.opened.session();
    session.attachWindow(&w);

    var bridge_ctx: BridgeCtx = .{ .session = session };
    var t = transport.Transport{
        .session = session,
        .history = .{
            .context = &bridge_ctx,
            .facts = BridgeCtx.factsFn,
            .restore = BridgeCtx.restoreFn,
        },
    };

    var wall = FakeWall{};
    var prng = std.Random.DefaultPrng.init(0xCAFE_BABE);
    const rand = prng.random();

    var cur: usize = slots;

    for (0..25) |_| {
        const op = rand.uintLessThan(u8, 3);
        switch (op) {
            0 => {
                if (cur > 0) {
                    const count = @min(cur, 1 + rand.uintLessThan(usize, 4));
                    const ticket = try t.command(.{ .step = .{ .core = .cpu0, .count = count, .dir = .back } });
                    _ = try t.finish(ticket, wall.wall(), null);
                    cur -= count;
                }
            },
            1 => {
                if (cur < slots) {
                    const count = @min(slots - cur, 1 + rand.uintLessThan(usize, 4));
                    const ticket = try t.command(.{ .step = .{ .core = .cpu0, .count = count, .dir = .fwd } });
                    _ = try t.finish(ticket, wall.wall(), null);
                    cur += count;
                }
            },
            2 => {
                const target_idx = rand.uintLessThan(usize, slots + 1);
                const target_pos = straight.positions[target_idx];
                var seek_buf: [64]u8 = undefined;
                const target_text = try std.fmt.bufPrint(&seek_buf, "{d}:{d}:{s}:{d}:{s}", .{
                    target_pos.branch,
                    target_pos.r,
                    @tagName(target_pos.phase),
                    target_pos.o,
                    @tagName(target_pos.gap),
                });
                const ticket = try t.command(.{ .seek = .{ .target = target_text } });
                _ = try t.finish(ticket, wall.wall(), null);
                cur = target_idx;
            },
            else => unreachable,
        }
        try std.testing.expectEqual(cur, w.cursor());
        try std.testing.expectEqualSlices(u8, &straight.digests[cur], &try rig.digest());
    }
}

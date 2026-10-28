//! Mirrored tests for Session reverse-watch and prefetch entry points.
const std = @import("std");
const ra8 = @import("ra8");
const prefetch_mod = ra8.session.history_prefetch;
const rw = ra8.session.history_reverse_watch;

const MockPort = struct {
    replays: usize = 0,
    should_cancel: bool = false,

    fn replay(
        ctx: *anyopaque,
        base: rw.Checkpoint,
        until: rw.Position,
        range: rw.Range,
        sink: *rw.Sink,
    ) rw.Error!void {
        _ = until;
        _ = range;
        const self: *MockPort = @ptrCast(@alignCast(ctx));
        self.replays += 1;
        sink.report(.{
            .position = .{ .branch = base.position.branch, .r = base.position.r, .phase = .cpu0, .o = 1, .gap = .retired },
            .address = 0x2000_0004,
            .len = 4,
            .initiator = .cpu0,
            .source = .{ .core = .{ .core = .cpu0, .slots = 1 } },
            .changed = true,
        });
    }

    fn cancelled(ctx: *anyopaque) bool {
        const self: *MockPort = @ptrCast(@alignCast(ctx));
        return self.should_cancel;
    }

    fn port(self: *MockPort) rw.Port {
        return .{ .context = self, .replay = replay, .cancelled = cancelled };
    }
};

test "session prefetch and prefetchCancel entry points" {
    const allocator = std.testing.allocator;
    const config = prefetch_mod.Config.forBudget(1024 * prefetch_mod.mib, prefetch_mod.default_share);
    var pool = prefetch_mod.Prefetch.init(allocator, config);
    defer pool.deinit();

    var sess: ra8.session.api.Session = undefined;
    sess.prefetch_pool = null;

    // Disabled when no pool attached
    try std.testing.expectError(error.Disabled, sess.prefetch(.{ .id = 1, .object = .{ .bytes = @splat(0x11) } }));
    sess.prefetchCancel(); // safe no-op

    // Attached pool queues and cancels requests
    sess.attachPrefetch(&pool);
    try sess.prefetch(.{ .id = 1, .object = .{ .bytes = @splat(0x11) } });
    try std.testing.expectEqual(@as(usize, 1), pool.queued());

    sess.prefetchCancel();
    try std.testing.expectEqual(@as(usize, 0), pool.queued());
}

test "session reverseWatch entry point delegates to engine and propagates cancellation" {
    const allocator = std.testing.allocator;
    var sess: ra8.session.api.Session = undefined;
    sess.fork_router = null;

    var mock: MockPort = .{};
    const checkpoints = [_]rw.Checkpoint{
        .{ .position = .{ .r = 10 }, .id = 1 },
        .{ .position = .{ .r = 20 }, .id = 2 },
    };
    const query: rw.Query = .{
        .range = .{ .address = 0x2000_0000, .size = 16 },
        .from = .{ .r = 25 },
    };

    const res = try sess.reverseWatch(allocator, mock.port(), query, &checkpoints);
    try std.testing.expect(res.outcome == .hit);
    try std.testing.expectEqual(@as(u32, 20), res.outcome.hit.position.r);

    mock.should_cancel = true;
    try std.testing.expectError(error.Cancelled, sess.reverseWatch(allocator, mock.port(), query, &checkpoints));
}

test "ReplayObserver computes .changed truthfully based on pre and new bytes" {
    var cpu: ra8.chip.core.cpu.cpu.Cpu = undefined;
    cpu.slots = 10;
    var machine: ra8.session.stop_machine.Machine = .{};
    var sess: ra8.session.api.Session = .{ .live = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 100 } };
    var grid_state: ra8.chip.core.scheduler.State = .{
        .at = .{ .branch = 0, .r = 5, .phase = .cpu0, .o = 1, .gap = .retired },
        .base = .{ 5, 0 },
    };
    sess.grid = &grid_state;

    var sink: rw.Sink = .{
        .range = .{ .address = 0x2000_0000, .size = 16 },
        .start = .{ .r = 0 },
        .until = .{ .r = 10 },
        .value_change_only = false,
    };
    var observer = ra8.session.search.ReplayObserver{
        .sink = &sink,
        .session = &sess,
    };
    const obs = observer.observer();

    // 1. Same bytes: pre == new -> changed should be false
    const pre_same = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    const new_same = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    obs.vtable.bytes(obs.ctx, .{
        .base = 0x2000_0000,
        .offset = 0,
        .initiator = .cpu0,
        .pre = &pre_same,
        .new = &new_same,
    });
    try std.testing.expect(sink.best != null);
    try std.testing.expectEqual(false, sink.best.?.changed);

    // 2. Differing bytes: pre != new -> changed should be true
    const new_diff = [_]u8{ 0x55, 0x66, 0x77, 0x88 };
    obs.vtable.bytes(obs.ctx, .{
        .base = 0x2000_0000,
        .offset = 4,
        .initiator = .cpu0,
        .pre = &pre_same,
        .new = &new_diff,
    });
    try std.testing.expect(sink.best != null);
    try std.testing.expectEqual(true, sink.best.?.changed);
}

test "ReplayObserver filters writes in gaps between disjoint watchpoints" {
    var cpu: ra8.chip.core.cpu.cpu.Cpu = undefined;
    cpu.slots = 10;
    var machine: ra8.session.stop_machine.Machine = .{};
    var sess: ra8.session.api.Session = .{ .live = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 100 } };
    var grid_state: ra8.chip.core.scheduler.State = .{
        .at = .{ .branch = 0, .r = 5, .phase = .cpu0, .o = 1, .gap = .retired },
        .base = .{ 5, 0 },
    };
    sess.grid = &grid_state;

    _ = try machine.watches.add(.{ .first = 0x2000_0000, .last = 0x2000_0003, .kind = .write });
    _ = try machine.watches.add(.{ .first = 0x2000_0100, .last = 0x2000_0103, .kind = .write });

    var sink: rw.Sink = .{
        .range = .{ .address = 0x2000_0000, .size = 0x200 },
        .start = .{ .r = 0 },
        .until = .{ .r = 10 },
        .value_change_only = false,
    };
    var observer = ra8.session.search.ReplayObserver{
        .sink = &sink,
        .session = &sess,
    };
    const obs = observer.observer();

    // Write in gap at 0x2000_0050: should be skipped
    const pre = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    const new = [_]u8{ 0x55, 0x66, 0x77, 0x88 };
    obs.vtable.bytes(obs.ctx, .{
        .base = 0x2000_0000,
        .offset = 0x50,
        .initiator = .cpu0,
        .pre = &pre,
        .new = &new,
    });
    try std.testing.expect(sink.best == null);

    // Write in watched slot at 0x2000_0100: should be reported
    obs.vtable.bytes(obs.ctx, .{
        .base = 0x2000_0000,
        .offset = 0x100,
        .initiator = .cpu0,
        .pre = &pre,
        .new = &new,
    });
    try std.testing.expect(sink.best != null);
    try std.testing.expectEqual(@as(u32, 0x2000_0100), sink.best.?.address);
}

test "reverseWatch on child branch resolves checkpoint on parent branch" {
    const allocator = std.testing.allocator;
    var sess: ra8.session.api.Session = undefined;
    sess.fork_router = null;

    var graph = try ra8.session.history_branch.BranchGraph.init(allocator);
    defer graph.deinit();
    try graph.insertNode(.{
        .id = 0,
        .parent = 0,
        .fork_at = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired },
        .reason = .base,
        .recorded_end = .{ .branch = 0, .r = 10, .phase = .cpu0, .o = 0, .gap = .retired },
    });
    try graph.insertNode(.{
        .id = 1,
        .parent = 0,
        .fork_at = .{ .branch = 0, .r = 5, .phase = .cpu0, .o = 0, .gap = .retired },
        .reason = .writes,
        .recorded_end = .{ .branch = 1, .r = 10, .phase = .cpu0, .o = 0, .gap = .retired },
    });
    var router = ra8.session.history_fork_router.ForkRouter.init(allocator, &graph);
    defer router.deinit();
    router.switchActiveLine(1);
    sess.fork_router = &router;

    var mock: MockPort = .{};
    const checkpoints = [_]rw.Checkpoint{
        .{ .position = .{ .branch = 0, .r = 2, .phase = .cpu0, .o = 0, .gap = .retired }, .id = 1 },
    };
    const query: rw.Query = .{
        .range = .{ .address = 0x2000_0000, .size = 16 },
        .from = .{ .branch = 1, .r = 7, .phase = .cpu0, .o = 0, .gap = .retired },
    };

    const res = try sess.reverseWatch(allocator, mock.port(), query, &checkpoints);
    try std.testing.expect(res.outcome == .hit);
    try std.testing.expectEqual(@as(usize, 1), mock.replays);
}

test "overflow-safe range arithmetic handles watchpoints near address space ceiling" {
    var cpu: ra8.chip.core.cpu.cpu.Cpu = undefined;
    var machine: ra8.session.stop_machine.Machine = .{};
    var sess: ra8.session.api.Session = .{ .live = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 100 } };
    _ = try machine.watches.add(.{ .first = 0xFFFF_FFF0, .last = 0xFFFF_FFFF, .kind = .write });

    try std.testing.expect(sess.hasArmedWriteWatch());
    try std.testing.expect(sess.matchingWatch(0xFFFF_FFF4, 4) != null);
    try std.testing.expect(sess.matchingWatch(0xFFFF_FFFC, 4) != null);
    try std.testing.expect(sess.matchingWatch(0xFFFF_FFE0, 4) == null);
}

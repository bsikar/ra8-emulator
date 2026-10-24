//! Tests for src/session/history/frame_queue.zig: bounded queue capacity,
//! FIFO order, blocking pop with condition variables, and overflow marking with regenerate_by_replay.
const std = @import("std");
const ra8 = @import("ra8");
const queue_mod = ra8.session.history_frame_queue;

const test_pos = queue_mod.Position{
    .branch = 1,
    .r = 10,
    .phase = .cpu0,
    .o = 5,
    .gap = .retired,
};

test "Queue maintains FIFO order" {
    const allocator = std.testing.allocator;
    var queue = queue_mod.Queue.init(std.testing.io, allocator, 1024 * 1024);
    defer queue.deinit();

    try queue.push(.{
        .kind = .keyframe,
        .position = test_pos,
        .virtual_ns = 100,
        .width = 100,
        .height = 100,
    });
    try queue.push(.{
        .kind = .delta,
        .position = test_pos,
        .virtual_ns = 200,
        .width = 100,
        .height = 100,
    });

    try std.testing.expectEqual(@as(usize, 2), queue.count());

    const t1 = queue.tryPop().?;
    try std.testing.expectEqual(@as(u64, 100), t1.virtual_ns);
    try std.testing.expectEqual(queue_mod.FrameKind.keyframe, t1.kind);

    const t2 = queue.tryPop().?;
    try std.testing.expectEqual(@as(u64, 200), t2.virtual_ns);
    try std.testing.expectEqual(queue_mod.FrameKind.delta, t2.kind);

    try std.testing.expect(queue.tryPop() == null);
}

test "Queue bound enforces capacity and marks overflow as regenerate_by_replay" {
    const allocator = std.testing.allocator;
    const task_overhead = @sizeOf(queue_mod.Task);
    const bound = 1000 + 2 * task_overhead;
    var queue = queue_mod.Queue.init(std.testing.io, allocator, bound);
    defer queue.deinit();

    // Task 1: 600 payload bytes
    const buf1 = try allocator.alloc(u8, 600);
    @memset(buf1, 1);
    try queue.push(.{
        .kind = .keyframe,
        .position = test_pos,
        .virtual_ns = 1000,
        .width = 10,
        .height = 10,
        .layer_bytes = buf1,
    });
    try std.testing.expectEqual(task_overhead + 600, queue.bytesUsed());
    try std.testing.expectEqual(@as(u64, 0), queue.overflows());

    // Task 2: 300 payload bytes (total 900 + 2 * overhead <= bound)
    const buf2 = try allocator.alloc(u8, 300);
    @memset(buf2, 2);
    try queue.push(.{
        .kind = .delta,
        .position = test_pos,
        .virtual_ns = 2000,
        .width = 10,
        .height = 10,
        .layer_bytes = buf2,
    });
    try std.testing.expectEqual(2 * task_overhead + 900, queue.bytesUsed());
    try std.testing.expectEqual(@as(u64, 0), queue.overflows());

    // Task 3: 200 payload bytes (overflows capacity)
    const buf3 = try allocator.alloc(u8, 200);
    @memset(buf3, 3);
    try queue.push(.{
        .kind = .delta,
        .position = test_pos,
        .virtual_ns = 3000,
        .width = 10,
        .height = 10,
        .layer_bytes = buf3,
    });
    // Task 3 marked regenerate_by_replay, payload freed, cost is only task_overhead
    try std.testing.expectEqual(@as(u64, 1), queue.overflows());
    try std.testing.expectEqual(@as(usize, 3), queue.count());

    var p1 = queue.tryPop().?;
    defer p1.deinit(allocator);
    try std.testing.expectEqual(queue_mod.FrameKind.keyframe, p1.kind);
    try std.testing.expect(p1.layer_bytes != null);

    var p2 = queue.tryPop().?;
    defer p2.deinit(allocator);
    try std.testing.expectEqual(queue_mod.FrameKind.delta, p2.kind);
    try std.testing.expect(p2.layer_bytes != null);

    var p3 = queue.tryPop().?;
    defer p3.deinit(allocator);
    try std.testing.expectEqual(queue_mod.FrameKind.regenerate_by_replay, p3.kind);
    try std.testing.expect(p3.layer_bytes == null);
    try std.testing.expectEqual(@as(u64, 3000), p3.virtual_ns);
}

test "Queue thread-safe blocking pop unblocks on push" {
    const allocator = std.testing.allocator;
    var queue = queue_mod.Queue.init(std.testing.io, allocator, 1024 * 1024);
    defer queue.deinit();

    const ThreadContext = struct {
        q: *queue_mod.Queue,
        received: ?queue_mod.Task = null,

        fn run(ctx: *@This()) void {
            ctx.received = ctx.q.pop();
        }
    };

    var ctx = ThreadContext{ .q = &queue };
    const thread = try std.Thread.spawn(.{}, ThreadContext.run, .{&ctx});

    try queue.push(.{
        .kind = .keyframe,
        .position = test_pos,
        .virtual_ns = 555,
        .width = 10,
        .height = 10,
    });

    thread.join();
    try std.testing.expect(ctx.received != null);
    try std.testing.expectEqual(@as(u64, 555), ctx.received.?.virtual_ns);
}

test "Queue blocking pop unblocks on close returning null" {
    const allocator = std.testing.allocator;
    var queue = queue_mod.Queue.init(std.testing.io, allocator, 1024 * 1024);
    defer queue.deinit();

    const ThreadContext = struct {
        q: *queue_mod.Queue,
        received: ?queue_mod.Task = null,
        done: bool = false,

        fn run(ctx: *@This()) void {
            ctx.received = ctx.q.pop();
            ctx.done = true;
        }
    };

    var ctx = ThreadContext{ .q = &queue };
    const thread = try std.Thread.spawn(.{}, ThreadContext.run, .{&ctx});

    queue.close();
    thread.join();

    try std.testing.expect(ctx.done);
    try std.testing.expect(ctx.received == null);
}

test "Queue reset and reopen allow reuse" {
    const allocator = std.testing.allocator;
    var queue = queue_mod.Queue.init(std.testing.io, allocator, 1024 * 1024);
    defer queue.deinit();

    try queue.push(.{
        .kind = .keyframe,
        .position = test_pos,
        .virtual_ns = 1,
        .width = 10,
        .height = 10,
    });
    queue.close();
    try std.testing.expectError(error.Closed, queue.push(.{
        .kind = .delta,
        .position = test_pos,
        .virtual_ns = 2,
        .width = 10,
        .height = 10,
    }));

    queue.reopen();
    try queue.push(.{
        .kind = .delta,
        .position = test_pos,
        .virtual_ns = 2,
        .width = 10,
        .height = 10,
    });
    try std.testing.expectEqual(@as(usize, 2), queue.count());

    queue.reset();
    try std.testing.expectEqual(@as(usize, 0), queue.count());
    try std.testing.expectEqual(@as(usize, 0), queue.bytesUsed());

    try queue.push(.{
        .kind = .keyframe,
        .position = test_pos,
        .virtual_ns = 3,
        .width = 10,
        .height = 10,
    });
    try std.testing.expectEqual(@as(usize, 1), queue.count());
}

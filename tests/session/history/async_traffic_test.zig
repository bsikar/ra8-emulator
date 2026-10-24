//! Tests for asynchronous host traffic isolation, queueing in past,
//! draining at recorded end, overflow telemetry, and discard on fork (Slice 20.3).
const std = @import("std");
const ra8 = @import("ra8");

const session_api = ra8.session.api;
const session_fork = ra8.session.fork;
const fork_router_mod = ra8.session.history_fork_router;
const branch_mod = ra8.session.history_branch;
const position_mod = ra8.session.history_position;
const async_queue = ra8.session.history_async_queue;
const async_traffic = ra8.session.history_async_traffic;

const Session = session_api.Session;
const BranchGraph = branch_mod.BranchGraph;
const ForkRouter = fork_router_mod.ForkRouter;

const DeliveryRecorder = struct {
    c6_bytes_seen: std.ArrayList([]const u8),
    c6_answers_seen: std.ArrayList([]const u8),
    usbip_seen: std.ArrayList([]const u8),
    camera_seen: std.ArrayList([]const u8),

    fn init(_: std.mem.Allocator) DeliveryRecorder {
        return .{
            .c6_bytes_seen = std.ArrayList([]const u8).empty,
            .c6_answers_seen = std.ArrayList([]const u8).empty,
            .usbip_seen = std.ArrayList([]const u8).empty,
            .camera_seen = std.ArrayList([]const u8).empty,
        };
    }

    fn deinit(self: *DeliveryRecorder, allocator: std.mem.Allocator) void {
        for (self.c6_bytes_seen.items) |b| allocator.free(b);
        self.c6_bytes_seen.deinit(allocator);
        for (self.c6_answers_seen.items) |b| allocator.free(b);
        self.c6_answers_seen.deinit(allocator);
        for (self.usbip_seen.items) |b| allocator.free(b);
        self.usbip_seen.deinit(allocator);
        for (self.camera_seen.items) |b| allocator.free(b);
        self.camera_seen.deinit(allocator);
    }

    fn onC6Bytes(ctx: *anyopaque, data: []const u8) anyerror!void {
        const self: *DeliveryRecorder = @ptrCast(@alignCast(ctx));
        try self.c6_bytes_seen.append(std.testing.allocator, try std.testing.allocator.dupe(u8, data));
    }

    fn onC6Answer(ctx: *anyopaque, data: []const u8) anyerror!void {
        const self: *DeliveryRecorder = @ptrCast(@alignCast(ctx));
        try self.c6_answers_seen.append(std.testing.allocator, try std.testing.allocator.dupe(u8, data));
    }

    fn onUsbip(ctx: *anyopaque, data: []const u8) anyerror!void {
        const self: *DeliveryRecorder = @ptrCast(@alignCast(ctx));
        try self.usbip_seen.append(std.testing.allocator, try std.testing.allocator.dupe(u8, data));
    }

    fn onCamera(ctx: *anyopaque, data: []const u8) anyerror!void {
        const self: *DeliveryRecorder = @ptrCast(@alignCast(ctx));
        try self.camera_seen.append(std.testing.allocator, try std.testing.allocator.dupe(u8, data));
    }
};

const Harness = struct {
    gpa: std.mem.Allocator,
    session: Session,
    graph: BranchGraph,
    router: ForkRouter,
    grid_state: ra8.chip.core.scheduler.State,
    rec: DeliveryRecorder,

    fn init(allocator: std.mem.Allocator, queue_capacity: usize) !*Harness {
        const h = try allocator.create(Harness);
        h.gpa = allocator;
        h.graph = try BranchGraph.init(allocator);
        h.router = ForkRouter.init(allocator, &h.graph);
        h.grid_state = .{
            .at = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired },
            .stretch = .{ .full = 64, .carry = 0, .dirty = false },
            .base = .{ 0, 0 },
            .cut = false,
            .cut_pending = .{},
        };
        h.rec = DeliveryRecorder.init(allocator);

        h.session = .{
            .live = undefined,
            .grid = &h.grid_state,
            .fork_router = &h.router,
        };
        h.session.attachAsyncQueue(async_queue.AsyncQueue.init(allocator, queue_capacity));
        h.session.async_traffic.c6_bytes_hook = .{ .context = &h.rec, .deliverFn = DeliveryRecorder.onC6Bytes };
        h.session.async_traffic.c6_answer_hook = .{ .context = &h.rec, .deliverFn = DeliveryRecorder.onC6Answer };
        h.session.async_traffic.usbip_hook = .{ .context = &h.rec, .deliverFn = DeliveryRecorder.onUsbip };
        h.session.async_traffic.camera_frame_hook = .{ .context = &h.rec, .deliverFn = DeliveryRecorder.onCamera };
        return h;
    }

    fn deinit(self: *Harness) void {
        self.rec.deinit(self.gpa);
        if (self.session.async_traffic.queue) |*q| q.deinit();
        self.router.deinit();
        self.graph.deinit();
        self.gpa.destroy(self);
    }
};

test "async traffic is queued while in past, delivers nothing immediately, and never forks" {
    const gpa = std.testing.allocator;
    const h = try Harness.init(gpa, 1024 * 1024);
    defer h.deinit();

    // Set recorded_end of line 0 to round 100, while grid sits at round 20 (in past)
    var end = h.graph.get(0).?.recorded_end;
    end.r = 100;
    try h.graph.insertNode(.{
        .id = 0,
        .parent = 0,
        .fork_at = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired },
        .reason = .base,
        .recorded_end = end,
    });
    h.grid_state.at.r = 20;

    try std.testing.expect(async_traffic.isCursorInPast(&h.session));

    // Ingest all 4 sources: none should deliver to hooks; all should be accepted
    try h.session.injectAsync(.c6_bytes, 1000, "c6-pkt-1");
    try h.session.injectAsync(.c6_answer, 2000, "c6-ans-1");
    try h.session.injectAsync(.usbip, 3000, "usb-urb-1");
    try h.session.injectAsync(.camera, 4000, "cam-frame-1");

    // Zero deliveries while in the past
    try std.testing.expectEqual(@as(usize, 0), h.rec.c6_bytes_seen.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.rec.c6_answers_seen.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.rec.usbip_seen.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.rec.camera_seen.items.len);

    // Queue holds 4 items
    try std.testing.expectEqual(@as(usize, 4), h.session.async_traffic.queue.?.count());
    // No forks created, router pending is null
    try std.testing.expect(h.session.forkPending() == null);
    try std.testing.expectEqual(@as(usize, 1), h.graph.nodes.count());
}

test "async traffic drains in order when cursor reaches recorded end" {
    const gpa = std.testing.allocator;
    const h = try Harness.init(gpa, 1024 * 1024);
    defer h.deinit();

    var end = h.graph.get(0).?.recorded_end;
    end.r = 50;
    try h.graph.insertNode(.{
        .id = 0,
        .parent = 0,
        .fork_at = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired },
        .reason = .base,
        .recorded_end = end,
    });
    h.grid_state.at.r = 10;

    // Queue 2 items in past
    try h.session.injectAsync(.c6_bytes, 10, "first-c6");
    try h.session.injectAsync(.camera, 20, "first-cam");

    // Still in past: drain returns 0
    try std.testing.expectEqual(@as(usize, 0), try async_traffic.drainIfNeeded(&h.session));

    // Advance cursor to recorded_end (round 50)
    h.grid_state.at.r = 50;
    try std.testing.expect(!async_traffic.isCursorInPast(&h.session));

    // Drain delivers all queued items in arrival order
    const drained = try async_traffic.drainIfNeeded(&h.session);
    try std.testing.expectEqual(@as(usize, 2), drained);
    try std.testing.expect(h.session.async_traffic.queue.?.isEmpty());

    try std.testing.expectEqual(@as(usize, 1), h.rec.c6_bytes_seen.items.len);
    try std.testing.expectEqualStrings("first-c6", h.rec.c6_bytes_seen.items[0]);
    try std.testing.expectEqual(@as(usize, 1), h.rec.camera_seen.items.len);
    try std.testing.expectEqualStrings("first-cam", h.rec.camera_seen.items[0]);
}

test "queue overflow is surfaced through the session" {
    const gpa = std.testing.allocator;
    // Small queue cap: 1 item (32 overhead + 10 data = 42 bytes)
    const h = try Harness.init(gpa, 64);
    defer h.deinit();

    var end = h.graph.get(0).?.recorded_end;
    end.r = 100;
    try h.graph.insertNode(.{
        .id = 0,
        .parent = 0,
        .fork_at = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired },
        .reason = .base,
        .recorded_end = end,
    });
    h.grid_state.at.r = 5;

    // First item fits (32 + 10 = 42 <= 64)
    try h.session.injectAsync(.c6_bytes, 100, "0123456789");
    try std.testing.expect(!h.session.asyncOverflow().?.hasDropped());

    // Second item exceeds capacity -> dropped, telemetry latched
    try h.session.injectAsync(.c6_bytes, 200, "0123456789");
    const of = h.session.asyncOverflow().?;
    try std.testing.expect(of.hasDropped());
    try std.testing.expectEqual(@as(u64, 1), of.totalDroppedItems());
    try std.testing.expectEqual(@as(u64, 10), of.totalDroppedBytes());
    try std.testing.expectEqual(@as(u64, 200), of.first_drop_ns.?);
}

test "queue is cleared with DiscardReport on past fork" {
    const gpa = std.testing.allocator;
    const h = try Harness.init(gpa, 1024 * 1024);
    defer h.deinit();

    var end = h.graph.get(0).?.recorded_end;
    end.r = 100;
    try h.graph.insertNode(.{
        .id = 0,
        .parent = 0,
        .fork_at = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired },
        .reason = .base,
        .recorded_end = end,
    });
    h.grid_state.at.r = 10;

    // Queue 3 items in past
    try h.session.injectAsync(.c6_bytes, 10, "data-1");
    try h.session.injectAsync(.c6_answer, 20, "data-2");
    try h.session.injectAsync(.usbip, 30, "data-3");
    try std.testing.expectEqual(@as(usize, 3), h.session.async_traffic.queue.?.count());

    // Disconnect on fork
    const report = async_traffic.clearOnFork(&h.session).?;
    try std.testing.expectEqual(@as(usize, 3), report.items);
    try std.testing.expectEqual(@as(usize, 18), report.bytes);
    try std.testing.expectEqual(@as(usize, 1), report.itemsFor(.c6_bytes));
    try std.testing.expectEqual(@as(usize, 1), report.itemsFor(.c6_answer));
    try std.testing.expectEqual(@as(usize, 1), report.itemsFor(.usbip));
    try std.testing.expect(h.session.async_traffic.queue.?.isEmpty());
    try std.testing.expectEqual(report, h.session.lastDiscardReport().?);
}

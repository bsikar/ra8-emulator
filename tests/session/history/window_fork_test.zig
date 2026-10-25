//! Fork routing and branch line tests for the reverse window (Slice 21.4).
//!
//! Verifies:
//! - Reverse window belongs to one canonical line.
//! - Intervention inside the window routes through Row 20 fork router.
//! - First intervention in past returns ForkNeedsConfirmation.
//! - Confirmation forks a new child branch, preserving parent's future.
//! - On fork, window is cut at fork point (future slots discarded, line updated).
//! - On branch switch, window updates line and reinitializes.

const std = @import("std");
const ra8 = @import("ra8");
const rig_mod = @import("window_rig.zig");

const api = ra8.session.api;
const engine = ra8.session.history_window_engine;
const rebuild = ra8.session.history_window_rebuild;
const window_fork = ra8.session.history_window_fork;
const branch_mod = ra8.session.history_branch;
const fork_router_mod = ra8.session.history_fork_router;
const recorder_mod = ra8.session.history_recorder;
const record_mod = ra8.session.history_record;
const position_mod = ra8.session.history_position;

const BranchGraph = branch_mod.BranchGraph;
const ForkRouter = fork_router_mod.ForkRouter;
const Position = position_mod.Position;

const MockStorage = struct {
    bytes: std.ArrayList(u8),
    active_branch: u32 = 0,

    fn init(allocator: std.mem.Allocator) MockStorage {
        return .{
            .bytes = std.ArrayList(u8).initCapacity(allocator, 1024) catch unreachable,
        };
    }
    fn deinit(self: *MockStorage, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
    }
    fn append(context: *anyopaque, b: []const u8) anyerror!void {
        const self: *MockStorage = @ptrCast(@alignCast(context));
        try self.bytes.appendSlice(std.testing.allocator, b);
    }
    fn flush(_: *anyopaque) anyerror!void {}
    fn truncate(context: *anyopaque, len: u64) anyerror!void {
        const self: *MockStorage = @ptrCast(@alignCast(context));
        self.bytes.shrinkRetainingCapacity(@intCast(len));
    }
    fn switchSegment(context: *anyopaque, branch: u32, _: u32) anyerror!u64 {
        const self: *MockStorage = @ptrCast(@alignCast(context));
        self.active_branch = branch;
        return 0;
    }
    fn storage(self: *MockStorage) recorder_mod.Storage {
        return .{
            .context = self,
            .append = &append,
            .flush = &flush,
            .truncate = &truncate,
            .switchSegment = &switchSegment,
        };
    }
};

const total_slots: usize = 50;

fn buildWindow(rig: *rig_mod.Rig, straight: *const rig_mod.Straight) !engine.ReverseWindow {
    try rig.port().restoreFull(straight.base);
    var w = rig.window(64 * 1024 * 1024);
    errdefer w.deinit();
    try rebuild.run(&w, .{ .base = .{ .bytes = straight.base }, .end = straight.positions[total_slots] });
    return w;
}

test "intervention inside window creates fork and cuts window future" {
    const gpa = std.testing.allocator;
    var rig: rig_mod.Rig = undefined;
    try rig.open(gpa);
    defer rig.deinit();

    var straight = try rig_mod.Straight.record(&rig, total_slots);
    defer straight.deinit();

    var w = try buildWindow(&rig, &straight);
    defer w.deinit();

    const session = rig.opened.session();
    session.attachWindow(&w);

    var graph = try BranchGraph.init(gpa);
    defer graph.deinit();

    var router = ForkRouter.init(gpa, &graph);
    defer router.deinit();

    var mock_storage = MockStorage.init(gpa);
    defer mock_storage.deinit(gpa);

    var rec = try recorder_mod.Recorder.init(gpa, mock_storage.storage(), .{});
    defer rec.deinit();

    session.attachForkRouter(&router);
    session.attachPersistentRecorder(&rec);

    const root_end = straight.positions[total_slots];
    try graph.insertNode(.{
        .id = 0,
        .parent = 0,
        .fork_at = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired },
        .reason = .base,
        .recorded_end = root_end,
    });
    router.active_line = 0;
    w.line = 0;

    // Walk window back to slot 20
    const fork_slot: usize = 20;
    try w.walkTo(fork_slot);
    @constCast(session.grid.?).at = straight.positions[fork_slot];

    try std.testing.expectEqual(@as(usize, 20), w.cursor());
    try std.testing.expectEqual(@as(usize, 50), w.count());

    // Intervention in the past requires confirmation
    try std.testing.expectError(error.ForkNeedsConfirmation, session.consoleInput(.cpu0, "fork-test-input"));
    try std.testing.expect(session.forkPending() != null);

    // Prior to confirmation, window future is intact
    try std.testing.expectEqual(@as(usize, 50), w.count());
    try std.testing.expectEqual(@as(?u32, 0), w.line);

    // Confirm fork: executes fork, cuts window future, and moves to branch 1
    try session.confirmFork();
    try std.testing.expect(session.forkPending() == null);
    try std.testing.expectEqual(@as(u32, 1), router.active_line);

    // Verify window state after fork
    try std.testing.expectEqual(@as(usize, 20), w.cursor());
    try std.testing.expectEqual(@as(usize, 20), w.count());
    try std.testing.expectEqual(@as(?u32, 1), w.line);
    try std.testing.expectEqual(straight.positions[fork_slot], w.end().?);

    // Verify parent branch 0 future is preserved in graph
    const parent_node = graph.get(0).?;
    try std.testing.expectEqual(root_end.r, parent_node.recorded_end.r);

    // Verify child branch 1 in graph
    const child_node = graph.get(1).?;
    try std.testing.expectEqual(@as(u32, 0), child_node.parent);
    try std.testing.expectEqual(straight.positions[fork_slot].r, child_node.fork_at.r);
}

test "branch switch notes switch and updates window line" {
    const gpa = std.testing.allocator;
    var rig: rig_mod.Rig = undefined;
    try rig.open(gpa);
    defer rig.deinit();

    var straight = try rig_mod.Straight.record(&rig, total_slots);
    defer straight.deinit();

    var w = try buildWindow(&rig, &straight);
    defer w.deinit();

    const session = rig.opened.session();
    session.attachWindow(&w);

    var graph = try BranchGraph.init(gpa);
    defer graph.deinit();

    var router = ForkRouter.init(gpa, &graph);
    defer router.deinit();

    session.attachForkRouter(&router);
    w.line = 1;

    // Note switch to branch 0
    try window_fork.noteBranchSwitch(session, 0);
    try std.testing.expectEqual(@as(?u32, 0), w.line);

    // Note switch to same branch is a no-op
    try window_fork.noteBranchSwitch(session, 0);
    try std.testing.expectEqual(@as(?u32, 0), w.line);
}

test "cutWindowAtFork cuts window future and reassigns branch" {
    const gpa = std.testing.allocator;
    var rig: rig_mod.Rig = undefined;
    try rig.open(gpa);
    defer rig.deinit();

    var straight = try rig_mod.Straight.record(&rig, total_slots);
    defer straight.deinit();

    var w = try buildWindow(&rig, &straight);
    defer w.deinit();

    w.line = 0;
    try w.walkTo(15);
    try std.testing.expectEqual(@as(usize, 15), w.cursor());
    try std.testing.expectEqual(@as(usize, 50), w.count());

    window_fork.cutWindowAtFork(&w, 42);

    try std.testing.expectEqual(@as(usize, 15), w.cursor());
    try std.testing.expectEqual(@as(usize, 15), w.count());
    try std.testing.expectEqual(@as(?u32, 42), w.line);
}

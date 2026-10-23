//! Tests for Session intervention routing, fork choke point, confirmation flow,
//! C6 disconnect, graph persistence, and multi-segment recording (Slice 20.2).
const std = @import("std");
const ra8 = @import("ra8");

const session_api = ra8.session.api;
const session_fork = ra8.session.fork;
const fork_router_mod = ra8.session.history_fork_router;
const branch_mod = ra8.session.history_branch;
const branches_codec = ra8.session.history_branches_codec;
const position_mod = ra8.session.history_position;
const record_mod = ra8.session.history_record;
const format_mod = ra8.session.history_format;
const root_mod = ra8.session.history_root;
const recorder_mod = ra8.session.history_recorder;

const Session = session_api.Session;
const Position = position_mod.Position;
const ForkReason = record_mod.ForkReason;
const BranchGraph = branch_mod.BranchGraph;
const ForkRouter = fork_router_mod.ForkRouter;

const MockStorage = struct {
    bytes: std.ArrayList(u8),
    seg_bytes: std.ArrayList(u8),
    active_branch: u32 = 0,

    fn init(allocator: std.mem.Allocator) MockStorage {
        return .{
            .bytes = std.ArrayList(u8).initCapacity(allocator, 1024) catch unreachable,
            .seg_bytes = std.ArrayList(u8).initCapacity(allocator, 1024) catch unreachable,
        };
    }

    fn deinit(self: *MockStorage) void {
        self.bytes.deinit(std.testing.allocator);
        self.seg_bytes.deinit(std.testing.allocator);
    }

    fn append(context: *anyopaque, b: []const u8) anyerror!void {
        const self: *MockStorage = @ptrCast(@alignCast(context));
        try self.bytes.appendSlice(std.testing.allocator, b);
        try self.seg_bytes.appendSlice(std.testing.allocator, b);
    }

    fn flush(_: *anyopaque) anyerror!void {}

    fn truncate(context: *anyopaque, len: u64) anyerror!void {
        const self: *MockStorage = @ptrCast(@alignCast(context));
        self.bytes.shrinkRetainingCapacity(@intCast(len));
        self.seg_bytes.shrinkRetainingCapacity(@intCast(len));
    }

    fn switchSegment(context: *anyopaque, branch: u32, _: u32) anyerror!void {
        const self: *MockStorage = @ptrCast(@alignCast(context));
        self.active_branch = branch;
        self.seg_bytes.clearRetainingCapacity();
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

const FakeSink = struct {
    called: usize = 0,
    fail: bool = false,
    last_bytes: std.ArrayList(u8),

    fn init(allocator: std.mem.Allocator) FakeSink {
        return .{ .last_bytes = std.ArrayList(u8).initCapacity(allocator, 1024) catch unreachable };
    }
    fn deinit(self: *FakeSink) void {
        self.last_bytes.deinit(std.testing.allocator);
    }
    fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *FakeSink = @ptrCast(@alignCast(context));
        self.called += 1;
        if (self.fail) return error.DiskFull;
        self.last_bytes.clearRetainingCapacity();
        try self.last_bytes.appendSlice(std.testing.allocator, bytes);
    }
    fn sink(self: *FakeSink) session_api.GraphSink {
        return .{ .context = self, .writeFn = &write };
    }
};

const MockHarness = struct {
    gpa: std.mem.Allocator,
    session: Session,
    graph: BranchGraph,
    router: ForkRouter,
    mock_storage: MockStorage,
    recorder: recorder_mod.Recorder,
    net_closed: bool = false,
    console_fed: ?[]const u8 = null,
    camera_spec: ?[]const u8 = null,
    plug_endpoint: ?session_api.Endpoint = null,
    plug_name: ?[]const u8 = null,
    loaded_image: ?[]const u8 = null,
    grid_state: ra8.chip.core.scheduler.State,

    fn init(allocator: std.mem.Allocator) !*MockHarness {
        const h = try allocator.create(MockHarness);
        h.gpa = allocator;
        h.graph = try BranchGraph.init(allocator);
        h.router = ForkRouter.init(allocator, &h.graph);
        h.mock_storage = MockStorage.init(allocator);
        h.recorder = try recorder_mod.Recorder.init(allocator, h.mock_storage.storage(), .{});
        h.net_closed = false;
        h.console_fed = null;
        h.camera_spec = null;
        h.plug_endpoint = null;
        h.plug_name = null;
        h.loaded_image = null;
        h.grid_state = .{
            .at = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired },
        };
        h.session = .{
            .live = .{ .core = undefined, .machine = undefined, .index = 0, .boundary = null, .budget = 1000 },
            .grid = &h.grid_state,
        };
        h.session.attachForkRouter(&h.router);
        h.session.attachPersistentRecorder(&h.recorder);
        h.session.attachNet(.{ .context = h, .closeFlowsFn = closeFlows });
        h.session.attachConsole(.{ .context = h, .feedFn = feedConsole });
        h.session.attachCamera(.{ .context = h, .changeFn = setCamera });
        h.session.attachPlugs(.{ .context = h, .plugFn = plugHook });
        h.session.loader = .{ .context = h, .loadFn = loadHook };
        return h;
    }

    fn deinit(self: *MockHarness) void {
        self.router.deinit();
        self.recorder.deinit();
        self.mock_storage.deinit();
        self.graph.deinit();
        self.gpa.destroy(self);
    }

    fn closeFlows(ctx: *anyopaque) void {
        const self: *MockHarness = @ptrCast(@alignCast(ctx));
        self.net_closed = true;
    }
    fn feedConsole(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *MockHarness = @ptrCast(@alignCast(ctx));
        self.console_fed = bytes;
    }
    fn setCamera(ctx: *anyopaque, spec: []const u8) anyerror!void {
        const self: *MockHarness = @ptrCast(@alignCast(ctx));
        self.camera_spec = spec;
    }
    fn plugHook(ctx: *anyopaque, at: session_api.Endpoint, name: ?[]const u8) anyerror!void {
        const self: *MockHarness = @ptrCast(@alignCast(ctx));
        self.plug_endpoint = at;
        self.plug_name = name;
    }
    fn loadHook(ctx: *anyopaque, _: session_api.Core, img: []const u8) anyerror!void {
        const self: *MockHarness = @ptrCast(@alignCast(ctx));
        self.loaded_image = img;
    }
};

test "confirmation flow and record ordering: branch record then intervention record" {
    const gpa = std.testing.allocator;
    const h = try MockHarness.init(gpa);
    defer h.deinit();

    var end = h.graph.get(0).?.recorded_end;
    end.r = 10;
    try h.graph.insertNode(.{
        .id = 0,
        .parent = 0,
        .fork_at = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired },
        .reason = .base,
        .recorded_end = end,
    });
    h.grid_state.at = Position{ .branch = 0, .r = 4, .phase = .cpu0, .o = 2, .gap = .polled };

    // Past intervention refuses with ForkNeedsConfirmation
    try std.testing.expectError(error.ForkNeedsConfirmation, h.session.consoleInput(.cpu0, "test-input-2"));
    try std.testing.expect(h.session.forkPending() != null);

    // Confirm fork: executes fork, switches segment, records branch then intervention
    try h.session.confirmFork();
    try std.testing.expect(h.session.forkPending() == null);
    try std.testing.expect(h.net_closed);
    try std.testing.expectEqualStrings("test-input-2", h.console_fed.?);
    try std.testing.expectEqual(@as(u32, 1), h.router.active_line);

    // Commit pending bytes on new segment
    try h.recorder.commit(100);

    // Verify ordering in new segment: branch record first, then intervention record
    const seg_data = h.mock_storage.seg_bytes.items;
    const f1 = try format_mod.decode(seg_data);
    try std.testing.expectEqual(@backingInt(record_mod.Kind.branch), f1.kind);
    const branch_rec = try record_mod.decodeBranch(f1.payload);
    try std.testing.expectEqual(@as(u64, 4), branch_rec.branch.fork_at.r);

    const f2 = try format_mod.decode(seg_data[f1.frame_len..]);
    try std.testing.expectEqual(@backingInt(record_mod.Kind.intervention), f2.kind);
    const interv = try record_mod.decodeIntervention(f2.payload);
    try std.testing.expectEqual(record_mod.Intervention.What.keystroke, interv.intervention.what);
    try std.testing.expectEqualStrings("test-input-2", interv.intervention.body);
    try std.testing.expectEqual(@as(u64, 4), interv.header.position.r);
}

test "graph sink persistence and failure rollback" {
    const gpa = std.testing.allocator;
    const h = try MockHarness.init(gpa);
    defer h.deinit();

    var fake = FakeSink.init(gpa);
    defer fake.deinit();
    h.session.attachGraphSink(fake.sink());

    var end = h.graph.get(0).?.recorded_end;
    end.r = 10;
    try h.graph.insertNode(.{
        .id = 0,
        .parent = 0,
        .fork_at = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired },
        .reason = .base,
        .recorded_end = end,
    });
    h.grid_state.at.r = 5;

    // First attempt fails at sink
    fake.fail = true;
    try std.testing.expectError(error.ForkNeedsConfirmation, h.session.consoleInput(.cpu0, "retry-msg"));
    try std.testing.expectError(error.DiskFull, h.session.confirmFork());
    try std.testing.expectEqual(@as(u32, 0), h.router.active_line);
    try std.testing.expect(h.graph.get(1) == null);

    // Second attempt with sink working
    fake.fail = false;
    try std.testing.expectError(error.ForkNeedsConfirmation, h.session.consoleInput(.cpu0, "retry-msg"));
    try h.session.confirmFork();
    try std.testing.expectEqual(@as(u32, 1), h.router.active_line);
    var decoded = try branches_codec.decode(gpa, fake.last_bytes.items);
    defer decoded.deinit();
    try std.testing.expect(decoded.get(1) != null);
}

test "recorder budget accounting retains parent bytes across fork" {
    const gpa = std.testing.allocator;
    const h = try MockHarness.init(gpa);
    defer h.deinit();

    const FreeFn = struct {
        fn free(_: *anyopaque) anyerror!u64 {
            return 1_000_000;
        }
    };
    h.recorder.disk = .{
        .context = h,
        .free = &FreeFn.free,
        .cap = 150, // budget cap of 150 bytes across whole history
        .floor = 0,
    };

    // Stage and commit 90 bytes on parent branch 0
    try h.session.consoleInput(.cpu0, "forty-bytes-of-data-to-commit-onto-parent-0");
    try h.recorder.commit(10);
    const parent_bytes = h.recorder.history_bytes;
    try std.testing.expect(parent_bytes > 0);

    // Advance recorded end and fork
    var end = h.graph.get(0).?.recorded_end;
    end.r = 10;
    try h.graph.insertNode(.{
        .id = 0,
        .parent = 0,
        .fork_at = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired },
        .reason = .base,
        .recorded_end = end,
    });
    h.grid_state.at.r = 5;

    try std.testing.expectError(error.ForkNeedsConfirmation, h.session.consoleInput(.cpu0, "forking-input"));
    try h.session.confirmFork();

    // After fork, committed_bytes on child segment reset, but history_bytes retained parent
    try std.testing.expectEqual(@as(u64, 0), h.recorder.committed_bytes);
    try std.testing.expectEqual(parent_bytes, h.recorder.history_bytes);

    // Staging bytes that exceed 150 total cap refuses with HistoryFull
    h.recorder.log.pending_bytes = 150;
    try std.testing.expectError(error.HistoryFull, h.recorder.commit(20));
}

test "root image identity and notePosition canonicalization" {
    const gpa = std.testing.allocator;
    const h = try MockHarness.init(gpa);
    defer h.deinit();

    const root_img = "ROOT-IMAGE-ELF0";
    var root: root_mod.Root = .{
        .snapshot_version = 1,
        .elf0 = .{ .identity = root_mod.identity(root_img), .bytes = root_img },
    };
    h.session.attachRoot(&root);

    // Mismatched load image refuses
    try std.testing.expectError(error.DifferentImage, h.session.load(.cpu0, "DIFFERENT-IMAGE"));
    // Matching image succeeds
    try h.session.load(.cpu0, root_img);
    try std.testing.expect(h.loaded_image != null);

    // notePosition respects replaying and canonicalizes
    h.session.setReplaying(true);
    h.session.notePosition(.{ .branch = 0, .r = 999, .phase = .cpu0, .o = 0, .gap = .retired });
    try std.testing.expect(h.graph.get(0).?.recorded_end.r < 999);

    h.session.setReplaying(false);
    h.session.notePosition(.{ .branch = 0, .r = 12, .phase = .cpu0, .o = 0, .gap = .retired });
    try std.testing.expectEqual(@as(u64, 12), h.graph.get(0).?.recorded_end.r);
}

test "replaying keeps persistent log byte-identical across replay passes" {
    const gpa = std.testing.allocator;
    const h = try MockHarness.init(gpa);
    defer h.deinit();

    // Live intervention writes to log
    try h.session.consoleInput(.cpu0, "initial-live-data");
    try h.recorder.commit(10);
    const initial_len = h.mock_storage.bytes.items.len;

    // Simulate replay pass: setReplaying suppresses all logging
    h.session.setReplaying(true);
    try h.session.consoleInput(.cpu0, "replayed-data-pass");
    try h.recorder.commit(20);
    h.session.setReplaying(false);

    try std.testing.expectEqual(initial_len, h.mock_storage.bytes.items.len);
}

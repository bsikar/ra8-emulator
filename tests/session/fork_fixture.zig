//! The mock harness the fork tests share: a Session with a fork router, a
//! persistent recorder over an in-memory storage, and hooks that note what
//! the intervention reached.
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

pub const MockStorage = struct {
    bytes: std.ArrayList(u8),
    seg_bytes: std.ArrayList(u8),
    active_branch: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) MockStorage {
        return .{
            .bytes = std.ArrayList(u8).initCapacity(allocator, 1024) catch unreachable,
            .seg_bytes = std.ArrayList(u8).initCapacity(allocator, 1024) catch unreachable,
        };
    }

    pub fn deinit(self: *MockStorage) void {
        self.bytes.deinit(std.testing.allocator);
        self.seg_bytes.deinit(std.testing.allocator);
    }

    pub fn append(context: *anyopaque, b: []const u8) anyerror!void {
        const self: *MockStorage = @ptrCast(@alignCast(context));
        try self.bytes.appendSlice(std.testing.allocator, b);
        try self.seg_bytes.appendSlice(std.testing.allocator, b);
    }

    pub fn flush(_: *anyopaque) anyerror!void {}

    pub fn truncate(context: *anyopaque, len: u64) anyerror!void {
        const self: *MockStorage = @ptrCast(@alignCast(context));
        self.bytes.shrinkRetainingCapacity(@intCast(len));
        self.seg_bytes.shrinkRetainingCapacity(@intCast(len));
    }

    pub fn switchSegment(context: *anyopaque, branch: u32, _: u32) anyerror!u64 {
        const self: *MockStorage = @ptrCast(@alignCast(context));
        self.active_branch = branch;
        self.seg_bytes.clearRetainingCapacity();
        return 0;
    }

    pub fn storage(self: *MockStorage) recorder_mod.Storage {
        return .{
            .context = self,
            .append = &append,
            .flush = &flush,
            .truncate = &truncate,
            .switchSegment = &switchSegment,
        };
    }
};

pub const FakeSink = struct {
    called: usize = 0,
    fail: bool = false,
    last_bytes: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) FakeSink {
        return .{ .last_bytes = std.ArrayList(u8).initCapacity(allocator, 1024) catch unreachable };
    }
    pub fn deinit(self: *FakeSink) void {
        self.last_bytes.deinit(std.testing.allocator);
    }
    pub fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *FakeSink = @ptrCast(@alignCast(context));
        self.called += 1;
        if (self.fail) return error.DiskFull;
        self.last_bytes.clearRetainingCapacity();
        try self.last_bytes.appendSlice(std.testing.allocator, bytes);
    }
    pub fn sink(self: *FakeSink) session_api.GraphSink {
        return .{ .context = self, .writeFn = &write };
    }
};

pub const MockHarness = struct {
    gpa: std.mem.Allocator,
    session: Session,
    graph: BranchGraph,
    router: ForkRouter,
    mock_storage: MockStorage,
    recorder: recorder_mod.Recorder,
    net_closed: bool = false,
    console_buf: [256]u8 = undefined,
    console_fed: ?[]const u8 = null,
    camera_spec: ?[]const u8 = null,
    plug_endpoint: ?session_api.Endpoint = null,
    plug_name: ?[]const u8 = null,
    loaded_image: ?[]const u8 = null,
    grid_state: ra8.chip.core.scheduler.State,

    pub fn init(allocator: std.mem.Allocator) !*MockHarness {
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

    pub fn deinit(self: *MockHarness) void {
        self.router.deinit();
        self.recorder.deinit();
        self.mock_storage.deinit();
        self.graph.deinit();
        self.gpa.destroy(self);
    }

    pub fn closeFlows(ctx: *anyopaque) void {
        const self: *MockHarness = @ptrCast(@alignCast(ctx));
        self.net_closed = true;
    }
    pub fn feedConsole(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *MockHarness = @ptrCast(@alignCast(ctx));
        const len = @min(bytes.len, self.console_buf.len);
        @memcpy(self.console_buf[0..len], bytes[0..len]);
        self.console_fed = self.console_buf[0..len];
    }
    pub fn setCamera(ctx: *anyopaque, spec: []const u8) anyerror!void {
        const self: *MockHarness = @ptrCast(@alignCast(ctx));
        self.camera_spec = spec;
    }
    pub fn plugHook(ctx: *anyopaque, at: session_api.Endpoint, name: ?[]const u8) anyerror!void {
        const self: *MockHarness = @ptrCast(@alignCast(ctx));
        self.plug_endpoint = at;
        self.plug_name = name;
    }
    pub fn loadHook(ctx: *anyopaque, _: session_api.Core, img: []const u8) anyerror!void {
        const self: *MockHarness = @ptrCast(@alignCast(ctx));
        self.loaded_image = img;
    }
};

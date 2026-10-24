//! Tests for ReplayFeeder, action encoding/decoding, line replay without forking,
//! and cross-line seek execution (Slice 20.3).
const std = @import("std");
const ra8 = @import("ra8");

const branch_mod = ra8.session.history_branch;
const position_mod = ra8.session.history_position;
const record_mod = ra8.session.history_record;
const format_mod = ra8.session.history_format;
const recorder_mod = ra8.session.history_recorder;
const replay_feeder = ra8.session.history_replay_feeder;
const fork_router_mod = ra8.session.history_fork_router;
const session_api = ra8.session.api;
const session_fork = ra8.session.fork;
const input_script = ra8.components.input_script;

const Position = position_mod.Position;
const BranchGraph = branch_mod.BranchGraph;
const ForkRouter = fork_router_mod.ForkRouter;
const ReplayFeeder = replay_feeder.ReplayFeeder;
const Session = session_api.Session;

fn pos(branch: u32, r: u64, o: u32) Position {
    return .{ .branch = branch, .r = r, .phase = .cpu0, .o = o, .gap = .retired };
}

test "action encoding and decoding round-trip preserves all fields including memory address" {
    const gpa = std.testing.allocator;

    // 1. Register write
    const reg_act: fork_router_mod.Action = .{ .register = .{ .core = .cpu0, .which = .r0, .value = 0x12345678 } };
    var enc_reg = try replay_feeder.encodeAction(gpa, reg_act);
    defer replay_feeder.freeEncodedAction(gpa, &enc_reg);
    const dec_reg = try replay_feeder.decodeAction(gpa, enc_reg.what, enc_reg.body);
    try std.testing.expectEqual(@as(u32, 0x12345678), dec_reg.register.value);
    try std.testing.expectEqual(session_api.Register.r0, dec_reg.register.which);

    // 2. Memory write with 4-byte address and payload
    const mem_data = "Hello, time travel memory!";
    const mem_act: fork_router_mod.Action = .{ .memory = .{ .core = .cpu0, .address = 0x20001000, .bytes = mem_data } };
    var enc_mem = try replay_feeder.encodeAction(gpa, mem_act);
    defer replay_feeder.freeEncodedAction(gpa, &enc_mem);
    var dec_mem = try replay_feeder.decodeAction(gpa, enc_mem.what, enc_mem.body);
    defer fork_router_mod.freeAction(gpa, &dec_mem);
    try std.testing.expectEqual(@as(u32, 0x20001000), dec_mem.memory.address);
    try std.testing.expectEqualStrings(mem_data, dec_mem.memory.bytes);

    // 3. Input tap
    const tap_act: fork_router_mod.Action = .{ .input = .{ .core = .cpu0, .at_ns = 50, .event = .{ .tap = .{ .x = 100, .y = 200 } } } };
    var enc_tap = try replay_feeder.encodeAction(gpa, tap_act);
    defer replay_feeder.freeEncodedAction(gpa, &enc_tap);
    const dec_tap = try replay_feeder.decodeAction(gpa, enc_tap.what, enc_tap.body);
    try std.testing.expectEqual(@as(u16, 100), dec_tap.input.event.tap.x);
    try std.testing.expectEqual(@as(u16, 200), dec_tap.input.event.tap.y);

    // 4. Input button
    const btn_act: fork_router_mod.Action = .{ .input = .{ .core = .cpu0, .at_ns = 50, .event = .{ .button = .{ .down = true, .button_id = .sw1 } } } };
    var enc_btn = try replay_feeder.encodeAction(gpa, btn_act);
    defer replay_feeder.freeEncodedAction(gpa, &enc_btn);
    const dec_btn = try replay_feeder.decodeAction(gpa, enc_btn.what, enc_btn.body);
    try std.testing.expectEqual(true, dec_btn.input.event.button.down);
    try std.testing.expectEqual(input_script.Button.sw1, dec_btn.input.event.button.button_id);
}

const MemSink = struct {
    bytes: std.ArrayList(u8),
    fn init(allocator: std.mem.Allocator) MemSink {
        return .{ .bytes = std.ArrayList(u8).initCapacity(allocator, 1024) catch unreachable };
    }
    fn deinit(self: *MemSink, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
    }
    fn storage(self: *MemSink) recorder_mod.Storage {
        return .{
            .context = self,
            .append = &append,
            .flush = &flush,
            .truncate = &truncate,
        };
    }
    fn append(ctx: *anyopaque, b: []const u8) anyerror!void {
        const self: *MemSink = @ptrCast(@alignCast(ctx));
        try self.bytes.appendSlice(std.testing.allocator, b);
    }
    fn flush(_: *anyopaque) anyerror!void {
        return;
    }
    fn truncate(_: *anyopaque, _: u64) anyerror!void {
        return;
    }
};

test "ReplayFeeder filters by active line and canonicalizes ancestor interventions" {
    const gpa = std.testing.allocator;
    var sink = MemSink.init(gpa);
    defer sink.deinit(gpa);

    var rec = try recorder_mod.Recorder.init(gpa, sink.storage(), .{});
    defer rec.deinit();

    // Line 0: root. Line 1 forks at r=100. Line 2 forks at r=150.
    var graph = try BranchGraph.init(gpa);
    defer graph.deinit();
    try graph.insertNode(.{ .id = 1, .parent = 0, .fork_at = pos(0, 100, 0), .reason = .taps, .recorded_end = pos(1, 200, 0) });
    try graph.insertNode(.{ .id = 2, .parent = 0, .fork_at = pos(0, 150, 0), .reason = .buttons, .recorded_end = pos(2, 200, 0) });

    // Record an intervention on branch 0 before fork point 100 (part of line 1's prefix)
    const mem_act: fork_router_mod.Action = .{ .memory = .{ .core = .cpu0, .address = 0x1000, .bytes = "prefix-write" } };
    var enc_mem = try replay_feeder.encodeAction(gpa, mem_act);
    defer replay_feeder.freeEncodedAction(gpa, &enc_mem);
    try rec.recordIntervention(.{ .position = pos(0, 40, 0), .seq = 1 }, .{ .what = enc_mem.what, .body = enc_mem.body });

    // Record an intervention on branch 0 after fork point 100 (not on line 1!)
    try rec.recordIntervention(.{ .position = pos(0, 120, 0), .seq = 2 }, .{ .what = enc_mem.what, .body = enc_mem.body });

    // Record an intervention on branch 1 (on line 1)
    const tap_act: fork_router_mod.Action = .{ .input = .{ .core = .cpu0, .at_ns = 0, .event = .{ .tap = .{ .x = 10, .y = 20 } } } };
    var enc_tap = try replay_feeder.encodeAction(gpa, tap_act);
    defer replay_feeder.freeEncodedAction(gpa, &enc_tap);
    try rec.recordIntervention(.{ .position = pos(1, 110, 0), .seq = 3 }, .{ .what = enc_tap.what, .body = enc_tap.body });

    // Record an intervention on branch 2 (sibling line 2, not on line 1)
    try rec.recordIntervention(.{ .position = pos(2, 160, 0), .seq = 4 }, .{ .what = enc_tap.what, .body = enc_tap.body });

    try rec.commit(100);

    // Load into feeder for line 1
    var feeder = ReplayFeeder.init(gpa);
    defer feeder.deinit();

    try feeder.loadFromLog(&graph, 1, sink.bytes.items);

    // Line 1 should only see pos(0, 40) (ancestor prefix) and pos(1, 110) (own segment) -> 2 items
    try std.testing.expectEqual(@as(usize, 2), feeder.count());

    // First item is pos(0, 40)
    const it1 = feeder.peekDue(pos(0, 40, 0)).?;
    try std.testing.expectEqual(@as(u32, 0x1000), it1.action.memory.address);
    feeder.advance();

    // Second item is pos(1, 110)
    const it2 = feeder.peekDue(pos(1, 110, 0)).?;
    try std.testing.expectEqual(@as(u16, 10), it2.action.input.event.tap.x);
    feeder.advance();

    try std.testing.expect(feeder.nextPosition() == null);
}

const MockStateHarness = struct {
    gpa: std.mem.Allocator,
    session: Session,
    graph: BranchGraph,
    router: ForkRouter,
    grid_state: ra8.chip.core.scheduler.State,
    memory_map: [4096]u8 = @splat(0),
    last_tap: ?input_script.Event = null,
    sink: MemSink,
    recorder: recorder_mod.Recorder,

    fn init(allocator: std.mem.Allocator) !*MockStateHarness {
        const h = try allocator.create(MockStateHarness);
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
        h.sink = MemSink.init(allocator);
        h.recorder = try recorder_mod.Recorder.init(allocator, h.sink.storage(), .{});
        h.memory_map = @splat(0);
        h.last_tap = null;

        h.session = .{
            .live = undefined,
            .grid = &h.grid_state,
            .fork_router = &h.router,
            .persistent_recorder = &h.recorder,
        };
        return h;
    }

    fn deinit(self: *MockStateHarness) void {
        if (self.session.replay_feeder) |*f| f.deinit();
        self.recorder.deinit();
        self.sink.deinit(self.gpa);
        self.router.deinit();
        self.graph.deinit();
        self.gpa.destroy(self);
    }
};

fn playForwardSteps(h: *MockStateHarness, target_r: u64) void {
    while (h.grid_state.at.r < target_r) {
        h.grid_state.at.r += 1;
        const cur = h.grid_state.at;
        if (h.session.replay_feeder.?.peekDue(cur)) |item| {
            switch (item.action) {
                .memory => |m| @memcpy(h.memory_map[m.address..][0..m.bytes.len], m.bytes),
                .input => |inp| h.last_tap = inp.event,
                else => {},
            }
            h.session.replay_feeder.?.advance();
        }
    }
}

test "rewind then play follows recorded line: re-applies memory write and tap without forking or mutating log" {
    const gpa = std.testing.allocator;
    const h = try MockStateHarness.init(gpa);
    defer h.deinit();

    // 1. Initial run: record memory write at round 5, tap at round 10
    h.grid_state.at.r = 5;
    const mem_payload = "intervened-data";
    const mem_act: fork_router_mod.Action = .{ .memory = .{ .core = .cpu0, .address = 0x200, .bytes = mem_payload } };
    var enc_mem = try replay_feeder.encodeAction(gpa, mem_act);
    defer replay_feeder.freeEncodedAction(gpa, &enc_mem);
    try h.recorder.recordIntervention(.{ .position = pos(0, 5, 0), .seq = 1 }, .{ .what = enc_mem.what, .body = enc_mem.body });
    @memcpy(h.memory_map[0x200..][0..mem_payload.len], mem_payload);

    h.grid_state.at.r = 10;
    const tap_act: fork_router_mod.Action = .{ .input = .{ .core = .cpu0, .at_ns = 0, .event = .{ .tap = .{ .x = 42, .y = 84 } } } };
    var enc_tap = try replay_feeder.encodeAction(gpa, tap_act);
    defer replay_feeder.freeEncodedAction(gpa, &enc_tap);
    try h.recorder.recordIntervention(.{ .position = pos(0, 10, 0), .seq = 2 }, .{ .what = enc_tap.what, .body = enc_tap.body });
    h.last_tap = tap_act.input.event;

    // Run reaches round 20 (recorded end = 20)
    h.grid_state.at.r = 20;
    try h.recorder.commit(100);
    const recorded_log_len = h.sink.bytes.items.len;
    try std.testing.expect(recorded_log_len > 0);

    var end = h.graph.get(0).?.recorded_end;
    end.r = 20;
    try h.graph.insertNode(.{
        .id = 0,
        .parent = 0,
        .fork_at = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired },
        .reason = .base,
        .recorded_end = end,
    });

    // Capture original digest (memory state + tap state)
    var original_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&h.memory_map, &original_digest, .{});

    // 2. Rewind before them: reset memory and tap state, set position back to r=0
    @memset(&h.memory_map, 0);
    h.last_tap = null;
    h.grid_state.at.r = 0;

    // Load replay interventions from the committed log
    try h.session.loadReplayInterventions(h.sink.bytes.items);
    try std.testing.expectEqual(@as(usize, 2), h.session.replay_feeder.?.count());

    // 3. Play forward: simulate step progression through r=5 and r=10 to r=20
    playForwardSteps(h, 20);

    // 4. Verify post-replay invariants:
    var replayed_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&h.memory_map, &replayed_digest, .{});
    try std.testing.expectEqual(original_digest, replayed_digest);
    try std.testing.expectEqual(@as(u16, 42), h.last_tap.?.tap.x);
    try std.testing.expectEqual(@as(u16, 84), h.last_tap.?.tap.y);

    // No branch was created
    try std.testing.expectEqual(@as(usize, 1), h.graph.nodes.count());
    // Log bytes unchanged
    try std.testing.expectEqual(recorded_log_len, h.sink.bytes.items.len);
}

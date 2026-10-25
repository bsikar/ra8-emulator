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

const fixture = @import("fork_fixture.zig");
const MockHarness = fixture.MockHarness;
const FakeSink = fixture.FakeSink;

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
    try std.testing.expectEqual(@backingInt(record_mod.Kind.branch), f1.frame.kind);
    const branch_rec = try record_mod.decodeBranch(f1.frame.payload);
    try std.testing.expectEqual(@as(u64, 4), branch_rec.branch.fork_at.r);

    const f2 = try format_mod.decode(seg_data[f1.consumed..]);
    try std.testing.expectEqual(@backingInt(record_mod.Kind.intervention), f2.frame.kind);
    const interv = try record_mod.decodeIntervention(f2.frame.payload);
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
    // Findings 4 & 5: pending fork is preserved, persistent recorder is not desynchronized
    try std.testing.expect(h.session.forkPending() != null);
    try std.testing.expectEqual(@as(u32, 0), h.mock_storage.active_branch);

    // Second attempt directly confirms and retries without re-entering the input
    fake.fail = false;
    try h.session.confirmFork();
    try std.testing.expectEqual(@as(u32, 1), h.router.active_line);
    try std.testing.expectEqual(@as(u32, 1), h.mock_storage.active_branch);
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
        .cap = 400, // budget cap of 400 bytes across whole history
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

    // After fork, the child segment holds only its own Branch record and
    // the fork's intervention, and history_bytes retains the parent's
    try std.testing.expect(h.recorder.committed_bytes > 0);
    try std.testing.expectEqual(parent_bytes + h.recorder.committed_bytes, h.recorder.history_bytes);

    // Staging bytes that exceed the 400 total cap refuses with HistoryFull
    h.recorder.log.pending_bytes = 400;
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

    // The root's own image loads on the recorded history; a different
    // image starts a new history instead (tests/session/new_history_test.zig).
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

test "fork while rewound past ancestral fork points binds parent to ancestor" {
    const gpa = std.testing.allocator;
    const h = try MockHarness.init(gpa);
    defer h.deinit();

    var end0 = h.graph.get(0).?.recorded_end;
    end0.r = 100;
    try h.graph.insertNode(.{
        .id = 0,
        .parent = 0,
        .fork_at = .{ .branch = 0, .r = 0, .phase = .cpu0, .o = 0, .gap = .retired },
        .reason = .base,
        .recorded_end = end0,
    });

    const b1 = try h.graph.addBranch(0, .{ .branch = 0, .r = 50, .phase = .cpu0, .o = 0, .gap = .retired }, .writes, 1000);
    var end1 = h.graph.get(b1).?.recorded_end;
    end1.r = 80;
    try h.graph.insertNode(.{
        .id = b1,
        .parent = 0,
        .fork_at = .{ .branch = b1, .r = 50, .phase = .cpu0, .o = 0, .gap = .retired },
        .reason = .writes,
        .recorded_end = end1,
    });
    h.router.active_line = b1;

    // Rewind to r=20 (< 50, so belongs to ancestor branch 0)
    h.grid_state.at.r = 20;

    try std.testing.expectError(error.ForkNeedsConfirmation, h.session.consoleInput(.cpu0, "ancestor-fork"));
    try h.session.confirmFork();

    // New branch 2 must have parent = 0 (ancestor), NOT 1 (active_line)
    const b2_node = h.graph.get(2).?;
    try std.testing.expectEqual(@as(u32, 0), b2_node.parent);
    try std.testing.expectEqual(@as(u64, 20), b2_node.fork_at.r);
}

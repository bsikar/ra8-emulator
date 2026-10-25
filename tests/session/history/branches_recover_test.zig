//! Covers src/session/history/branches_recover.zig: pure recovery decision
//! between candidate files, favoring valid temp over current file, and fallback
//! to base line or log reconstruction.
const std = @import("std");
const ra8 = @import("ra8");
const branch_mod = ra8.session.history_branch;
const codec = ra8.session.history_branches_codec;
const recover_mod = ra8.session.history_branches_recover;
const record = ra8.session.history_record;
const format = ra8.session.history_format;
const scheduler = ra8.chip.core.scheduler;

const Position = scheduler.Position;
const BranchGraph = branch_mod.BranchGraph;

fn makePos(branch: u32, r: u64, o: u32) Position {
    return .{
        .branch = branch,
        .r = r,
        .phase = .cpu0,
        .o = o,
        .gap = .retired,
    };
}

test "valid temp + valid file where temp has FEWER branches (temp wins)" {
    const gpa = std.testing.allocator;

    // Current file has 3 branches (0, 1, 2)
    var current_graph = try BranchGraph.init(gpa);
    defer current_graph.deinit();
    const b1 = try current_graph.addBranch(0, makePos(0, 30, 0), .writes, 100);
    _ = try current_graph.addBranch(b1, makePos(b1, 60, 0), .taps, 200);
    const current_bytes = try codec.encodeAlloc(&current_graph, gpa);
    defer gpa.free(current_bytes);

    // Temp file has only 1 branch (0), representing a deletion committed to temp
    var temp_graph = try BranchGraph.init(gpa);
    defer temp_graph.deinit();
    const temp_bytes = try codec.encodeAlloc(&temp_graph, gpa);
    defer gpa.free(temp_bytes);

    // Temp is the newest completed commit before rename: temp MUST win!
    var res = try recover_mod.recover(gpa, current_bytes, temp_bytes, null);
    defer res.graph.deinit();

    try std.testing.expectEqual(recover_mod.Action.use_temp, res.action);
    try std.testing.expectEqual(@as(usize, 1), res.graph.nodes.count());
    try std.testing.expect(res.graph.get(0) != null);
    try std.testing.expect(res.graph.get(b1) == null);
}

test "torn temp + valid file (file wins)" {
    const gpa = std.testing.allocator;

    var current_graph = try BranchGraph.init(gpa);
    defer current_graph.deinit();
    const b1 = try current_graph.addBranch(0, makePos(0, 30, 0), .writes, 100);
    const current_bytes = try codec.encodeAlloc(&current_graph, gpa);
    defer gpa.free(current_bytes);

    // Torn/corrupt temp
    const torn_temp = current_bytes[0 .. current_bytes.len / 2];

    var res = try recover_mod.recover(gpa, current_bytes, torn_temp, null);
    defer res.graph.deinit();

    try std.testing.expectEqual(recover_mod.Action.use_current, res.action);
    try std.testing.expectEqual(@as(usize, 2), res.graph.nodes.count());
    try std.testing.expect(res.graph.get(b1) != null);
}

test "both invalid (base line)" {
    const gpa = std.testing.allocator;

    const garbage_current = "garbage file data";
    const garbage_temp = "garbage temp data";

    var res = try recover_mod.recover(gpa, garbage_current, garbage_temp, null);
    defer res.graph.deinit();

    try std.testing.expectEqual(recover_mod.Action.use_base, res.action);
    try std.testing.expectEqual(@as(usize, 1), res.graph.nodes.count());
    try std.testing.expect(res.graph.get(0) != null);
}

test "missing both (base line)" {
    const gpa = std.testing.allocator;

    var res = try recover_mod.recover(gpa, null, null, null);
    defer res.graph.deinit();

    try std.testing.expectEqual(recover_mod.Action.use_base, res.action);
    try std.testing.expectEqual(@as(usize, 1), res.graph.nodes.count());
    try std.testing.expect(res.graph.get(0) != null);
}

test "missing both with log frames (log rebuild)" {
    const gpa = std.testing.allocator;

    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try record.encodeBranch(&buf.writer, .{ .position = makePos(0, 45, 0), .seq = 1 }, .{
        .id = 1,
        .parent = 0,
        .fork_at = makePos(0, 45, 0),
        .reason = .plug_unplug_fault,
    });
    const f_bytes = try gpa.dupe(u8, buf.written());
    defer gpa.free(f_bytes);

    const frames = [_]format.Frame{
        .{ .kind = @backingInt(record.Kind.branch), .payload = f_bytes },
    };

    var res = try recover_mod.recover(gpa, null, null, &frames);
    defer res.graph.deinit();

    try std.testing.expectEqual(recover_mod.Action.use_base, res.action);
    try std.testing.expectEqual(@as(usize, 2), res.graph.nodes.count());
    const b1 = res.graph.get(1).?;
    try std.testing.expectEqual(record.ForkReason.plug_unplug_fault, b1.reason);
}

fn frame(gpa: std.mem.Allocator, out: *std.Io.Writer, kind: record.Kind, encode: anytype) !void {
    var payload: std.Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try encode(&payload.writer);
    try format.encode(out, @backingInt(kind), payload.written());
}

test "recovery with the log rebuilds the lines and raises each recorded end from it" {
    const gpa = std.testing.allocator;
    var log: std.Io.Writer.Allocating = .init(gpa);
    defer log.deinit();
    const Enc = struct {
        fn branch(w: *std.Io.Writer) !void {
            try record.encodeBranch(w, .{ .position = makePos(1, 45, 0), .seq = 1 }, .{
                .id = 1,
                .parent = 0,
                .fork_at = makePos(1, 45, 0),
                .reason = .writes,
            });
        }
        fn child(w: *std.Io.Writer) !void {
            try record.encodeIntervention(w, .{ .position = makePos(1, 70, 3), .seq = 2 }, .{ .what = .keystroke, .body = "k" });
        }
        fn root(w: *std.Io.Writer) !void {
            try record.encodeIntervention(w, .{ .position = makePos(0, 30, 0), .seq = 3 }, .{ .what = .keystroke, .body = "k" });
        }
    };
    try frame(gpa, &log.writer, .branch, Enc.branch);
    try frame(gpa, &log.writer, .intervention, Enc.child);
    try frame(gpa, &log.writer, .intervention, Enc.root);

    // No branches.bin at all: the log's own records are the graph, and the
    // ends branches.bin would have carried come from the newest record each
    // line's segment holds.
    var res = try recover_mod.recoverWithLog(gpa, null, null, log.written());
    defer res.graph.deinit();
    try std.testing.expectEqual(@as(usize, 2), res.graph.nodes.count());
    try std.testing.expectEqual(@as(u64, 70), res.graph.get(1).?.recorded_end.r);
    try std.testing.expectEqual(@as(u32, 3), res.graph.get(1).?.recorded_end.o);
    try std.testing.expectEqual(@as(u64, 30), res.graph.get(0).?.recorded_end.r);

    // A stale branches.bin keeps its lines and is raised the same way.
    var stale = try BranchGraph.init(gpa);
    defer stale.deinit();
    _ = try stale.addBranch(0, makePos(0, 45, 0), .writes, 0);
    const bytes = try codec.encodeAlloc(&stale, gpa);
    defer gpa.free(bytes);
    var raised = try recover_mod.recoverWithLog(gpa, bytes, null, log.written());
    defer raised.graph.deinit();
    try std.testing.expectEqual(recover_mod.Action.use_current, raised.action);
    try std.testing.expectEqual(@as(u64, 70), raised.graph.get(1).?.recorded_end.r);
}

//! Covers src/session/history/branches_codec.zig: serialization, deserialization,
//! CRC-32C verification, error detection, cycle/missing-parent refusal,
//! and log frame reconstruction.
const std = @import("std");
const ra8 = @import("ra8");
const branch_mod = ra8.session.history_branch;
const codec = ra8.session.history_branches_codec;
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

test "branches.bin round trip serialization with CRC-32C" {
    const gpa = std.testing.allocator;
    var graph = try BranchGraph.init(gpa);
    defer graph.deinit();

    // Add branch 1 and branch 2
    const b1 = try graph.addBranch(0, makePos(0, 50, 0), .writes, 12345);
    var n1 = graph.get(b1).?;
    n1.pins = 3;
    n1.kept = true;
    n1.recorded_end = makePos(b1, 95, 2);
    try graph.insertNode(n1);

    const b2 = try graph.addBranch(b1, makePos(b1, 80, 0), .camera_change, 67890);
    var n2 = graph.get(b2).?;
    n2.pruned_tail = true;
    n2.recorded_end = makePos(b2, 120, 1);
    try graph.insertNode(n2);

    graph.active_branch = b2;

    const encoded = try codec.encodeAlloc(&graph, gpa);
    defer gpa.free(encoded);

    try std.testing.expect(codec.validate(encoded));

    var decoded = try codec.decode(gpa, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(graph.active_branch, decoded.active_branch);
    try std.testing.expectEqual(graph.next_branch_id, decoded.next_branch_id);
    try std.testing.expectEqual(@as(usize, 3), decoded.nodes.count());

    const dec_n1 = decoded.get(b1).?;
    try std.testing.expectEqual(n1.id, dec_n1.id);
    try std.testing.expectEqual(n1.parent, dec_n1.parent);
    try std.testing.expectEqual(n1.reason, dec_n1.reason);
    try std.testing.expectEqual(n1.pins, dec_n1.pins);
    try std.testing.expectEqual(n1.kept, dec_n1.kept);
    try std.testing.expectEqual(n1.recorded_end.r, dec_n1.recorded_end.r);

    const dec_n2 = decoded.get(b2).?;
    try std.testing.expectEqual(n2.id, dec_n2.id);
    try std.testing.expectEqual(n2.reason, dec_n2.reason);
    try std.testing.expectEqual(n2.pruned_tail, dec_n2.pruned_tail);
    try std.testing.expectEqual(n2.recorded_end.r, dec_n2.recorded_end.r);
}

test "corrupt CRC-32C and bad magic are rejected" {
    const gpa = std.testing.allocator;
    var graph = try BranchGraph.init(gpa);
    defer graph.deinit();

    _ = try graph.addBranch(0, makePos(0, 10, 0), .writes, 100);

    const encoded = try codec.encodeAlloc(&graph, gpa);
    defer gpa.free(encoded);

    // Bit-flip inside payload
    var flipped = try gpa.dupe(u8, encoded);
    defer gpa.free(flipped);
    flipped[25] ^= 0x55;

    try std.testing.expect(!codec.validate(flipped));
    try std.testing.expectError(error.BadCrc, codec.decode(gpa, flipped));

    // Bad magic in header
    var bad_magic = try gpa.dupe(u8, encoded);
    defer gpa.free(bad_magic);
    bad_magic[0] = 'X';
    try std.testing.expectError(error.BadMagic, codec.decode(gpa, bad_magic));

    // Bad magic in trailer
    var bad_trailer = try gpa.dupe(u8, encoded);
    defer gpa.free(bad_trailer);
    bad_trailer[bad_trailer.len - 1] = 'X';
    try std.testing.expectError(error.BadMagic, codec.decode(gpa, bad_trailer));
}

test "truncated buffer is rejected" {
    const gpa = std.testing.allocator;
    var graph = try BranchGraph.init(gpa);
    defer graph.deinit();

    const encoded = try codec.encodeAlloc(&graph, gpa);
    defer gpa.free(encoded);

    const truncated = encoded[0 .. encoded.len - 5];
    try std.testing.expect(!codec.validate(truncated));
    try std.testing.expectError(error.Truncated, codec.decode(gpa, truncated));
}

test "decode refuses missing parent or cycles in branch hierarchy" {
    const gpa = std.testing.allocator;

    // 1. Missing parent: node 1 claims parent 99 which does not exist
    {
        var graph = try BranchGraph.init(gpa);
        defer graph.deinit();
        try graph.nodes.put(1, .{
            .id = 1,
            .parent = 99,
            .fork_at = makePos(99, 10, 0),
            .reason = .writes,
            .created_ns = 0,
            .recorded_end = makePos(1, 10, 0),
        });
        const encoded = try codec.encodeAlloc(&graph, gpa);
        defer gpa.free(encoded);
        try std.testing.expectError(error.BadValue, codec.decode(gpa, encoded));
    }

    // 2. Self-referencing node: node 1 has parent 1
    {
        var graph = try BranchGraph.init(gpa);
        defer graph.deinit();
        try graph.nodes.put(1, .{
            .id = 1,
            .parent = 1,
            .fork_at = makePos(1, 10, 0),
            .reason = .writes,
            .created_ns = 0,
            .recorded_end = makePos(1, 10, 0),
        });
        const encoded = try codec.encodeAlloc(&graph, gpa);
        defer gpa.free(encoded);
        try std.testing.expectError(error.BadValue, codec.decode(gpa, encoded));
    }

    // 3. Cyclic parent references: node 1's parent is 2, and node 2's parent is 1
    {
        var graph = try BranchGraph.init(gpa);
        defer graph.deinit();
        try graph.nodes.put(1, .{
            .id = 1,
            .parent = 2,
            .fork_at = makePos(2, 10, 0),
            .reason = .writes,
            .created_ns = 0,
            .recorded_end = makePos(1, 10, 0),
        });
        try graph.nodes.put(2, .{
            .id = 2,
            .parent = 1,
            .fork_at = makePos(1, 10, 0),
            .reason = .taps,
            .created_ns = 0,
            .recorded_end = makePos(2, 10, 0),
        });
        const encoded = try codec.encodeAlloc(&graph, gpa);
        defer gpa.free(encoded);
        try std.testing.expectError(error.BadValue, codec.decode(gpa, encoded));
    }
}

test "rebuilding branch graph from log frames" {
    const gpa = std.testing.allocator;

    // 1. Empty frames returns base line
    var empty_graph = try codec.rebuildFromLogFrames(gpa, &.{});
    defer empty_graph.deinit();
    try std.testing.expectEqual(@as(usize, 1), empty_graph.nodes.count());
    try std.testing.expect(empty_graph.get(0) != null);

    // 2. Synthesize branch records encoded into frames using Allocating writer
    var buf1: std.Io.Writer.Allocating = .init(gpa);
    defer buf1.deinit();
    try record.encodeBranch(&buf1.writer, .{ .position = makePos(0, 50, 0), .seq = 1 }, .{
        .id = 1,
        .parent = 0,
        .fork_at = makePos(0, 50, 0),
        .reason = .writes,
    });
    const f1_bytes = try gpa.dupe(u8, buf1.written());
    defer gpa.free(f1_bytes);

    var buf2: std.Io.Writer.Allocating = .init(gpa);
    defer buf2.deinit();
    try record.encodeBranch(&buf2.writer, .{ .position = makePos(1, 80, 0), .seq = 2 }, .{
        .id = 2,
        .parent = 1,
        .fork_at = makePos(1, 80, 0),
        .reason = .camera_change,
    });
    const f2_bytes = try gpa.dupe(u8, buf2.written());
    defer gpa.free(f2_bytes);

    const frames = [_]format.Frame{
        .{ .kind = @backingInt(record.Kind.branch), .payload = f1_bytes },
        .{ .kind = @backingInt(record.Kind.branch), .payload = f2_bytes },
    };

    var rebuilt = try codec.rebuildFromLogFrames(gpa, &frames);
    defer rebuilt.deinit();

    try std.testing.expectEqual(@as(usize, 3), rebuilt.nodes.count());
    const r1 = rebuilt.get(1).?;
    try std.testing.expectEqual(@as(u32, 0), r1.parent);
    try std.testing.expectEqual(record.ForkReason.writes, r1.reason);
    try std.testing.expectEqual(@as(u64, 50), r1.fork_at.r);

    const r2 = rebuilt.get(2).?;
    try std.testing.expectEqual(@as(u32, 1), r2.parent);
    try std.testing.expectEqual(record.ForkReason.camera_change, r2.reason);
    try std.testing.expectEqual(@as(u64, 80), r2.fork_at.r);
}

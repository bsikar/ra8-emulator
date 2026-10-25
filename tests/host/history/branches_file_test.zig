//! Covers src/host/history/branches_file.zig: format-agnostic crash-safe atomic write,
//! candidate buffer reading, temp settling, and temp cleanup.
const std = @import("std");
const ra8 = @import("ra8");
const branches_file = ra8.host.history.branches_file;
const codec = ra8.session.history_branches_codec;
const branch_mod = ra8.session.history_branch;
const recover_mod = ra8.session.history_branches_recover;
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

test "atomic write creates branches.bin and leaves no temp" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data = "test-payload-bytes";
    try branches_file.writeAtomic(io, tmp.dir, data);

    var candidates = try branches_file.readCandidates(io, tmp.dir, gpa);
    defer candidates.deinit(gpa);

    try std.testing.expect(candidates.current != null);
    try std.testing.expectEqualStrings(data, candidates.current.?);
    try std.testing.expect(candidates.temp == null);
}

test "readCandidates returns both files when temp exists" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try branches_file.writeAtomic(io, tmp.dir, "current-data");

    // Manually create a temp file simulating an unrenamed write
    const temp_file = try tmp.dir.createFile(io, branches_file.temp_name, .{});
    try temp_file.writeStreamingAll(io, "temp-data");
    temp_file.close(io);

    var candidates = try branches_file.readCandidates(io, tmp.dir, gpa);
    defer candidates.deinit(gpa);

    try std.testing.expect(candidates.current != null);
    try std.testing.expectEqualStrings("current-data", candidates.current.?);

    try std.testing.expect(candidates.temp != null);
    try std.testing.expectEqualStrings("temp-data", candidates.temp.?);
}

test "settle renames temp over current file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try branches_file.writeAtomic(io, tmp.dir, "old-data");

    const temp_file = try tmp.dir.createFile(io, branches_file.temp_name, .{});
    try temp_file.writeStreamingAll(io, "new-data");
    temp_file.close(io);

    try branches_file.settle(io, tmp.dir);

    var candidates = try branches_file.readCandidates(io, tmp.dir, gpa);
    defer candidates.deinit(gpa);

    try std.testing.expect(candidates.current != null);
    try std.testing.expectEqualStrings("new-data", candidates.current.?);
    try std.testing.expect(candidates.temp == null);
}

test "cleanupTemp removes leftover temp file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const temp_file = try tmp.dir.createFile(io, branches_file.temp_name, .{});
    try temp_file.writeStreamingAll(io, "broken-temp");
    temp_file.close(io);

    branches_file.cleanupTemp(io, tmp.dir);

    var candidates = try branches_file.readCandidates(io, tmp.dir, gpa);
    defer candidates.deinit(gpa);
    try std.testing.expect(candidates.temp == null);
}

test "end-to-end host storage and session recovery integration" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 1. Initial valid file
    var graph1 = try BranchGraph.init(gpa);
    defer graph1.deinit();
    _ = try graph1.addBranch(0, makePos(0, 30, 0), .writes, 100);
    const bytes1 = try codec.encodeAlloc(&graph1, gpa);
    defer gpa.free(bytes1);
    try branches_file.writeAtomic(io, tmp.dir, bytes1);

    // 2. Unsettled temp with a newer branch
    var graph2 = try BranchGraph.init(gpa);
    defer graph2.deinit();
    _ = try graph2.addBranch(0, makePos(0, 30, 0), .writes, 100);
    _ = try graph2.addBranch(1, makePos(1, 60, 0), .taps, 200);
    const bytes2 = try codec.encodeAlloc(&graph2, gpa);
    defer gpa.free(bytes2);

    const temp_file = try tmp.dir.createFile(io, branches_file.temp_name, .{});
    try temp_file.writeStreamingAll(io, bytes2);
    temp_file.close(io);

    // 3. Host reads candidates, session chooses temp, host settles
    var candidates = try branches_file.readCandidates(io, tmp.dir, gpa);
    defer candidates.deinit(gpa);

    var res = try recover_mod.recover(gpa, candidates.current, candidates.temp, null);
    defer res.graph.deinit();

    try std.testing.expectEqual(recover_mod.Action.use_temp, res.action);
    try std.testing.expectEqual(@as(usize, 3), res.graph.nodes.count());

    // Host settles
    try branches_file.settle(io, tmp.dir);

    // Verify settled
    var final_candidates = try branches_file.readCandidates(io, tmp.dir, gpa);
    defer final_candidates.deinit(gpa);
    try std.testing.expectEqualStrings(bytes2, final_candidates.current.?);
    try std.testing.expect(final_candidates.temp == null);
}

//! Tests for src/interfaces/cli/history_branch_cli.zig (Slice 20.4 offline history branch operations).
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const history = ra8.host.history;
const branches_file = history.branches_file;
const mod = cli_app.history_cli;
const branch_cli = cli_app.history_branch_cli;
const branch_mod = ra8.session.history_branch;
const codec = ra8.session.history_branches_codec;
const Position = ra8.session.history_position.Position;

fn pos(b: u32, r: u64) Position {
    return .{ .branch = b, .r = r, .phase = .cpu0, .o = 0, .gap = .retired };
}

test "history branch ls and rm operate offline on session branches.bin" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var base = try history.base.Base.open(allocator, io, root, .cache);
    defer base.close();

    var session = try history.session.Session.create(&base, .{});
    const id = session.id;

    // Build initial branch graph: root 0 and child 1
    var graph = try branch_mod.BranchGraph.init(allocator);
    defer graph.deinit();

    var n0 = graph.get(0).?;
    n0.recorded_end = pos(0, 100);
    try graph.insertNode(n0);

    try graph.insertNode(.{
        .id = 1,
        .parent = 0,
        .fork_at = pos(0, 40),
        .reason = .writes,
        .recorded_end = pos(1, 80),
    });

    const encoded = try codec.encodeAlloc(&graph, allocator);
    defer allocator.free(encoded);
    try branches_file.writeAtomic(io, session.dir, encoded);

    // Close session handles so lock and directory can be reopened offline
    session.dir.close(io);
    session.lock.close(io);

    const session_name = try std.fmt.allocPrint(allocator, "{s}", .{&id});
    defer allocator.free(session_name);

    // 1. List branches
    var list_buf: [4096]u8 = undefined;
    var list_stream: std.Io.Writer = .fixed(&list_buf);
    try std.testing.expectEqual(@as(u8, 0), try branch_cli.listBranches(allocator, &base, session_name, &list_stream));
    const list_out = list_buf[0..list_stream.end];
    try std.testing.expect(std.mem.indexOf(u8, list_out, "branch 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_out, "branch 1") != null);

    // 2. Remove branch without confirm -> error
    var rm_buf: [4096]u8 = undefined;
    var rm_stream: std.Io.Writer = .fixed(&rm_buf);
    try std.testing.expectError(error.ConfirmRequired, branch_cli.removeBranch(allocator, &base, session_name, 1, false, &rm_stream));

    // 3. Remove branch with confirm -> success
    try std.testing.expectEqual(@as(u8, 0), try branch_cli.removeBranch(allocator, &base, session_name, 1, true, &rm_stream));
    const rm_out = rm_buf[0..rm_stream.end];
    try std.testing.expect(std.mem.indexOf(u8, rm_out, "removed branch 1") != null);

    // 4. Verify branch 1 is gone from branches.bin
    var list_buf2: [4096]u8 = undefined;
    var list_stream2: std.Io.Writer = .fixed(&list_buf2);
    try std.testing.expectEqual(@as(u8, 0), try branch_cli.listBranches(allocator, &base, session_name, &list_stream2));
    const list_out2 = list_buf2[0..list_stream2.end];
    try std.testing.expect(std.mem.indexOf(u8, list_out2, "branch 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_out2, "branch 1") == null);
}

//! Tests for diff RPC handler (Slice 23.5).
const std = @import("std");
const ra8 = @import("ra8");
const Rig = @import("advance_rig.zig").Rig;
const session_diff = ra8.rpc.session.diff;
const diff_wire = ra8.rpc.session.diff_wire;
const handlers = ra8.rpc.session.handlers;
const branch_rpc = ra8.rpc.session.branch;

fn driveFinish(served: *ra8.rpc.served_setup.Served, ticket: ra8.session.transport.Ticket) !void {
    _ = try served.context.transport.?.finish(ticket, served.context.wall.?, null);
}

test "diff RPC handler returns refuse when unconfigured" {
    var rig = Rig{};
    try rig.open();
    defer rig.close();

    var scratch: [1024]u8 = undefined;
    rig.context.scratch = &scratch;
    rig.context.gpa = std.testing.allocator;

    const outcome = session_diff.diff(&rig.context, .{ .a = "0", .b = "1" });
    try std.testing.expect(outcome == .err);
}

test "diff between two checkpoints of a served history names their positions, registers and pages" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    var served: ra8.rpc.served_setup.Served = undefined;
    try served.open(gpa, std.testing.io, "tests/fixtures/threadx/threadx_stkof.elf", null, .{ .root = root, .checkpoint_every = 1 });
    defer served.deinit();
    _ = try served.owner.session().run(.cpu0, .run);

    const outcome = session_diff.diff(&served.context, .{ .a = "0", .b = "latest" });
    try std.testing.expect(outcome == .ok);
    var decoded = try diff_wire.decode(gpa, outcome.ok.bytes);
    defer decoded.deinit(gpa);
    try std.testing.expect(decoded.frames >= 2);
    try std.testing.expect(decoded.a.r < decoded.b.r);
    try std.testing.expectEqual(diff_wire.LineOrder.lt, decoded.order);
    try std.testing.expect(decoded.regs.len > 0);
    try std.testing.expect(decoded.pages.len > 0);

    // The cursor is at the newest checkpoint's end, so it resolves there.
    const same = session_diff.diff(&served.context, .{ .a = "cursor", .b = "latest" });
    try std.testing.expect(same == .ok);
    var same_dec = try diff_wire.decode(gpa, same.ok.bytes);
    defer same_dec.deinit(gpa);
    try std.testing.expectEqual(diff_wire.LineOrder.eq, same_dec.order);
    // A checkpoint that does not exist is refused.
    try std.testing.expect(session_diff.diff(&served.context, .{ .a = "chk:9999", .b = "latest" }) == .err);
}

test "diff walks ancestor-prefix checkpoints on child line and excludes sibling or post-fork checkpoints" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    var served: ra8.rpc.served_setup.Served = undefined;
    try served.open(gpa, std.testing.io, "tests/fixtures/gpio/blink.elf", null, .{ .root = root, .checkpoint_every = 1 });
    defer served.deinit();

    // Advance 3 quanta on branch 0 with checkpoint_every=1 so branch 0 records >= 3 checkpoints.
    const session = served.owner.session();
    try session.setRunBudget(.cpu0, 40_000);
    _ = try session.run(.cpu0, .run);
    _ = try session.run(.cpu0, .cont);
    _ = try session.run(.cpu0, .cont);
    const root_diff = session_diff.diff(&served.context, .{ .a = "0", .b = "1" });
    try std.testing.expect(root_diff == .ok);
    var root_dec = try diff_wire.decode(gpa, root_diff.ok.bytes);
    defer root_dec.deinit(gpa);
    try std.testing.expect(root_dec.frames >= 3);
    const cp1_r = root_dec.b.r;

    // Seek back to checkpoint 1 on branch 0 and fork sibling branch 1 via writeRegister.
    var target_buf: [64]u8 = undefined;
    const seek_cp1 = try std.fmt.bufPrint(&target_buf, "0:{d}:{s}:{d}:{s}", .{
        root_dec.b.r,
        @tagName(root_dec.b.phase),
        root_dec.b.o,
        @tagName(root_dec.b.gap),
    });
    const t1 = try served.context.transport.?.command(.{ .seek = .{ .target = seek_cp1 } });
    try driveFinish(&served, t1);
    session.fork_router.?.first_fork_confirmed = true;
    try std.testing.expect(handlers.writeRegister(&served.context, .{ .core = .cpu0, .register = .r0, .value = 0x1111_2222 }) == .ok);
    try std.testing.expectEqual(@as(u32, 1), session.currentPosition().branch);
    // Advance branch 1 so sibling branch 1 records its own checkpoints past cp1_r.
    _ = try session.run(.cpu0, .cont);
    _ = try session.run(.cpu0, .cont);

    // Switch back to branch 0, seek to CP1, and fork branch 2 with ZERO own checkpoints.
    try std.testing.expect(branch_rpc.branchSwitch(&served.context, .{ .branch = 0 }) == .ok);
    const t2 = try served.context.transport.?.command(.{ .seek = .{ .target = seek_cp1 } });
    try driveFinish(&served, t2);
    try std.testing.expect(handlers.writeRegister(&served.context, .{ .core = .cpu0, .register = .r0, .value = 0x3333_4444 }) == .ok);
    try std.testing.expectEqual(@as(u32, 2), session.currentPosition().branch);

    // On branch 2 (0 own checkpoints), line checkpoints must be strictly [CP0, CP1] from ancestor 0 (<= cp1_r),
    // excluding branch 0's post-fork checkpoints (> cp1_r) and excluding sibling branch 1's checkpoints!
    const child_diff = session_diff.diff(&served.context, .{ .a = "0", .b = "latest" });
    try std.testing.expect(child_diff == .ok);
    var child_dec = try diff_wire.decode(gpa, child_diff.ok.bytes);
    defer child_dec.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 2), child_dec.frames);
    try std.testing.expectEqual(@as(u32, 0), child_dec.a.branch);
    try std.testing.expectEqual(@as(u64, 0), child_dec.a.r);
    try std.testing.expectEqual(@as(u32, 0), child_dec.b.branch);
    try std.testing.expectEqual(cp1_r, child_dec.b.r);
    try std.testing.expectEqual(diff_wire.LineOrder.lt, child_dec.order);
}

test "diff at arbitrary non-checkpoint positions reports full positions and leaves live Session untouched" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    var served: ra8.rpc.served_setup.Served = undefined;
    try served.open(gpa, std.testing.io, "tests/fixtures/threadx/threadx_stkof.elf", null, .{ .root = root, .checkpoint_every = 8 });
    defer served.deinit();

    const session = served.owner.session();
    // Step 5 instructions so live session stands at a distinct non-checkpoint position.
    for (0..5) |_| _ = try session.run(.cpu0, .step);

    const pos_before = session.currentPosition();
    const pc_before = try session.register(.cpu0, .pc);
    const sp_before = try session.register(.cpu0, .sp);
    const r0_before = try session.register(.cpu0, .r0);
    const bp_id = try session.setBreakpoint(.cpu0, .{ .address = pc_before });
    defer session.clearBreakpoint(.cpu0, bp_id) catch {};
    const win_count_before = if (session.window) |w| w.count() else 0;
    const win_cursor_before = if (session.window) |w| w.cursor() else 0;

    // Diff two arbitrary intra-round positions (polled vs retired at offset 2) before live cursor.
    const outcome = session_diff.diff(&served.context, .{
        .a = "0:0:cpu0:1:retired",
        .b = "0:0:cpu0:2:polled",
    });
    try std.testing.expect(outcome == .ok);
    var decoded = try diff_wire.decode(gpa, outcome.ok.bytes);
    defer decoded.deinit(gpa);

    try std.testing.expectEqual(@as(u32, 0), decoded.a.branch);
    try std.testing.expectEqual(@as(u64, 0), decoded.a.r);
    try std.testing.expectEqual(diff_wire.Phase.cpu0, decoded.a.phase);
    try std.testing.expectEqual(@as(u32, 1), decoded.a.o);
    try std.testing.expectEqual(diff_wire.Gap.retired, decoded.a.gap);

    try std.testing.expectEqual(@as(u32, 0), decoded.b.branch);
    try std.testing.expectEqual(@as(u64, 0), decoded.b.r);
    try std.testing.expectEqual(diff_wire.Phase.cpu0, decoded.b.phase);
    try std.testing.expectEqual(@as(u32, 2), decoded.b.o);
    try std.testing.expectEqual(diff_wire.Gap.polled, decoded.b.gap);
    try std.testing.expectEqual(diff_wire.LineOrder.lt, decoded.order);

    // Live session position, registers, window, and armed breakpoints must be 100% unchanged.
    try std.testing.expectEqual(pos_before, session.currentPosition());
    try std.testing.expectEqual(pc_before, try session.register(.cpu0, .pc));
    try std.testing.expectEqual(sp_before, try session.register(.cpu0, .sp));
    try std.testing.expectEqual(r0_before, try session.register(.cpu0, .r0));
    if (session.window) |w| {
        try std.testing.expectEqual(win_count_before, w.count());
        try std.testing.expectEqual(win_cursor_before, w.cursor());
    }
}

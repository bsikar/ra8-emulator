//! Tests for diff RPC handler (Slice 23.5).
const std = @import("std");
const ra8 = @import("ra8");
const Rig = @import("advance_rig.zig").Rig;
const session_diff = ra8.rpc.session.diff;

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
    var decoded = try ra8.rpc.session.diff_wire.decode(gpa, outcome.ok.bytes);
    defer decoded.deinit(gpa);
    try std.testing.expect(decoded.frames >= 2);
    try std.testing.expect(decoded.a.r < decoded.b.r);
    try std.testing.expect(decoded.regs.len > 0);
    try std.testing.expect(decoded.pages.len > 0);

    // The cursor is at the newest checkpoint's end, so it resolves there.
    const same = session_diff.diff(&served.context, .{ .a = "cursor", .b = "latest" });
    try std.testing.expect(same == .ok);
    // A checkpoint that does not exist is refused.
    try std.testing.expect(session_diff.diff(&served.context, .{ .a = "chk:9999", .b = "latest" }) == .err);
}

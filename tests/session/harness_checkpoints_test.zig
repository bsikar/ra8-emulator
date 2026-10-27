//! Covers src/session/harness/checkpoints.zig: arming binds the
//! controller to the session's boundary with the harness's save stream
//! and the application's host side, and disarm releases the recorder.
const std = @import("std");
const ra8 = @import("ra8");

const checkpoints_mod = ra8.session.harness.checkpoints;
const scheduler = ra8.chip.core.scheduler;

/// Stand-in host side: the arming never fires the hook here, so the
/// functions only need to exist.
const Stub = struct {
    fn append(_: *anyopaque, _: []const u8) anyerror!void {}
    fn flush(_: *anyopaque) anyerror!void {}
    fn truncate(_: *anyopaque, _: u64) anyerror!void {}
    fn put(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {}
    fn sync(_: *anyopaque) anyerror!void {}
    fn tick(_: *anyopaque, _: u32) anyerror!void {}
    fn free(_: *anyopaque) anyerror!u64 {
        return 1_000;
    }
};

test "arming binds the controller to the session's boundary" {
    const gpa = std.testing.allocator;
    var context: u8 = 0;
    var session: ra8.session.zig.session.ZigSession = .{ .core = undefined, .machine = undefined, .budget = 1 };
    session.boundary = .{ .context = &context, .tickFn = Stub.tick };
    var files: ra8.session.board.state.Files = undefined;
    var saved: scheduler.State = .{};

    const armed = try checkpoints_mod.arm(
        gpa,
        &session,
        &files,
        &saved,
        .{ .context = &context, .append = Stub.append, .flush = Stub.flush, .truncate = Stub.truncate },
        .{ .context = &context, .put = Stub.put, .sync = Stub.sync },
        .{ .context = &context, .free = Stub.free, .cap = 100, .floor = 10 },
        600,
        64,
    );
    defer checkpoints_mod.disarm(gpa, armed);

    try std.testing.expect(session.checkpoints == &armed.checkpoints);
    try std.testing.expect(session.boundary.?.checkpointFn != null);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&armed.checkpoints)), session.boundary.?.checkpoint_context);
    try std.testing.expect(armed.recorder.objects != null);
    try std.testing.expectEqual(@as(u64, 100), armed.recorder.disk.?.cap);
    try std.testing.expectEqual(@as(u64, 10), armed.recorder.disk.?.floor);
    try std.testing.expectEqual(@as(u64, 600), armed.checkpoints.object_cap);
    try std.testing.expectEqual(@as(u32, 64), armed.checkpoints.every);
    // Every armed checkpoint pins the panel's picture.
    try std.testing.expect(armed.checkpoints.picture != null);
}

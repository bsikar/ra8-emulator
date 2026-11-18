const std = @import("std");

const target_lease = @import("ra8").host.target_lease;

test "host target lease excludes concurrent holders and advances fencing tokens" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);

    var first = try target_lease.Lease.acquire(std.testing.io, dir, "jlink-001083322193");
    try std.testing.expectEqual(@as(u64, 1), first.token);
    try std.testing.expectError(
        error.TargetBusy,
        target_lease.Lease.acquire(std.testing.io, dir, "jlink-001083322193"),
    );
    var other = try target_lease.Lease.acquire(std.testing.io, dir, "jlink-001088957027");
    defer other.close(std.testing.io);
    try std.testing.expectEqual(@as(u64, 1), other.token);

    first.close(std.testing.io);
    var second = try target_lease.Lease.acquire(std.testing.io, dir, "jlink-001083322193");
    defer second.close(std.testing.io);
    try std.testing.expectEqual(@as(u64, 2), second.token);

    var fence: target_lease.Fence = .{};
    try std.testing.expectError(error.StaleLease, fence.admit(0));
    try fence.admit(second.token);
    try fence.admit(second.token);
    try std.testing.expectError(error.StaleLease, fence.admit(first.token));
    try std.testing.expectError(
        error.BadLeaseKey,
        target_lease.Lease.acquire(std.testing.io, dir, "../escape"),
    );
}

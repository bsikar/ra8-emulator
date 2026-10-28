//! Covers src/session/history/frame_cache_types.zig: the hot tier's
//! ram-budget table at and around each step, and the limit defaults.
const std = @import("std");
const ra8 = @import("ra8");
const types = ra8.session.history_frame_cache_types;

const mib: u64 = 1024 * 1024;

test "the hot tier steps at each budget boundary" {
    try std.testing.expectEqual(@as(u64, 256 * mib), types.hotBytesFor(1024 * mib));
    try std.testing.expectEqual(@as(u64, 128 * mib), types.hotBytesFor(1024 * mib - 1));
    try std.testing.expectEqual(@as(u64, 128 * mib), types.hotBytesFor(512 * mib));
    try std.testing.expectEqual(@as(u64, 48 * mib), types.hotBytesFor(512 * mib - 1));
    try std.testing.expectEqual(@as(u64, 48 * mib), types.hotBytesFor(256 * mib));
    try std.testing.expectEqual(@as(u64, 0), types.hotBytesFor(256 * mib - 1));
    try std.testing.expectEqual(@as(u64, 0), types.hotBytesFor(0));
}

test "a limit keeps no cold tier and a bounded marker count by default" {
    const limits: types.Limits = .{ .ram_bytes = 5 };
    try std.testing.expectEqual(@as(u64, 0), limits.disk_bytes);
    try std.testing.expect(limits.max_markers > 0);
}

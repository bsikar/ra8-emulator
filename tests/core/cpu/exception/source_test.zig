//! Covers src/core/cpu/exception/source.zig.
const std = @import("std");
const fixture = @import("ram.zig");
const Fake = @import("fake_source.zig").Fake;

test "a source forwards each question to what it wraps" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{ .pending = .{ .number = 14, .priority = 0xFF } };
    const source = fake.source();
    try std.testing.expectEqual(@as(u9, 14), (try source.winner(ram.view())).?.number);
    try source.taken(ram.view(), 14);
    try source.returned(ram.view(), 14);
    try std.testing.expectEqual(@as(u32, 1), fake.taken);
    try std.testing.expectEqual(@as(?u9, 14), fake.last_returned);
    try std.testing.expect((try source.winner(ram.view())) == null);
}

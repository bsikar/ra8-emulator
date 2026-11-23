const ra8 = @import("ra8");
const std = @import("std");

const labels = ra8.session.labels;

test "address labels replace, resolve by name, and clear per core" {
    var map: labels.Map = .{};
    const key: labels.Key = .{ .core = .cpu0, .address = 0x20000000 };
    const other: labels.Key = .{ .core = .cpu1, .address = key.address };
    try map.set(key, "counter", 4);
    try map.set(other, "counter", 2);
    try std.testing.expectError(error.DuplicateLabel, map.set(.{ .core = .cpu0, .address = 4 }, "counter", 4));
    try std.testing.expectError(error.InvalidLabelWidth, map.set(key, "bad_width", 3));
    try std.testing.expectEqual(@as(u8, 4), map.byName(.cpu0, null, "counter").?.width);
    try map.set(key, "total", 8);
    try std.testing.expect(map.byName(.cpu0, null, "counter") == null);
    try std.testing.expectEqualStrings("total", map.at(key).?.name());
    try map.set(key, "", 0);
    try std.testing.expect(map.at(key) == null);
    try std.testing.expectEqual(@as(u8, 2), map.at(other).?.width);
}

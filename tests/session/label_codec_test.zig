const ra8 = @import("ra8");
const std = @import("std");

const codec = ra8.session.label_codec;
const labels = ra8.session.labels;

test "session label encoding preserves core, address, frame storage and names" {
    var map: labels.Map = .{};
    const global: labels.Key = .{ .core = .cpu0, .address = 0x20000000 };
    const local: labels.Key = .{
        .core = .cpu1,
        .address = 12,
        .frame = .{ .entry = 0x8000040, .storage = .register_offset, .register = 7 },
    };
    try map.set(global, "counter", 4);
    try map.set(local, "cursor", 2);
    var buffer: [codec.text_cap]u8 = undefined;
    const decoded = try codec.decode(codec.encode(&map, &buffer));
    try std.testing.expectEqualStrings("counter", decoded.at(global).?.name());
    try std.testing.expectEqualStrings("cursor", decoded.at(local).?.name());
    try std.testing.expectEqual(@as(u8, 2), decoded.at(local).?.width);
    try std.testing.expectEqual(@as(usize, 0), (try codec.decode(null)).len);
    try std.testing.expectError(error.InvalidLabels, codec.decode("AA=="));
}

//! Partial commands survive; malformed lengths and tails never alter a target.
const std = @import("std");
const ra8 = @import("ra8");
const codec = ra8.components.catalog_snapshot;
const Modem = ra8.components.modem_at.Modem;
const fields = ra8.snapshot.fields;

test "attachment strict modem snapshot canonical tail and next reply" {
    var source: Modem = .{};
    _ = source.feed('A');
    _ = source.feed('T');
    @memset(source.line[source.len..], 0xa5);
    var saved = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer saved.deinit();
    try codec.writePayload(&saved.writer, .modem, &source);
    var target: Modem = .{};
    var pins: ra8.chip.periph.gpio.Gpio = .{};
    var cursor: fields.Cursor = .{ .bytes = saved.written() };
    try codec.readPayload(.modem, &target, &pins, &cursor);
    for (target.line[target.len..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectEqual(@as(u8, 0xa5), source.line[source.len]);
    try std.testing.expectEqualSlices(u8, source.feed(13), target.feed(13));
}

test "attachment strict modem invalid count and trailing byte preserve target" {
    var target: Modem = .{ .line = @splat(0x55), .len = 2, .answered = 7 };
    const before = target;
    var pins: ra8.chip.periph.gpio.Gpio = .{};
    for ([_]usize{ 1, 65 }) |count| {
        const source: Modem = .{ .line = @splat(0), .len = count };
        var saved = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer saved.deinit();
        try fields.write(&saved.writer, source);
        if (count == 1) try saved.writer.writeByte(0);
        var cursor: fields.Cursor = .{ .bytes = saved.written() };
        try std.testing.expectError(error.BadValue, codec.readPayload(.modem, &target, &pins, &cursor));
        try std.testing.expectEqualDeep(before, target);
    }
}

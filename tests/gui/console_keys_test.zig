//! Covers src/gui/console_keys.zig: control keys map to the bytes they type,
//! queued bytes reach their channels oldest first, and past capacity the
//! newest are dropped and counted.
const std = @import("std");
const ra8 = @import("ra8");
const console_keys = ra8.gui.console_keys;

const Sink = struct {
    bytes: [8]u8 = undefined,
    channels: [8]usize = undefined,
    count: usize = 0,

    pub fn feed(self: *Sink, channel: usize, data: []const u8) void {
        for (data) |byte| {
            self.bytes[self.count] = byte;
            self.channels[self.count] = channel;
            self.count += 1;
        }
    }
};

test "control keys map to the bytes they type" {
    try std.testing.expectEqual(@as(?u8, '\r'), console_keys.byteOf(0x0D));
    try std.testing.expectEqual(@as(?u8, 0x08), console_keys.byteOf(0x08));
    try std.testing.expectEqual(@as(?u8, 0x7F), console_keys.byteOf(0x7F));
    // Printable characters come as text events, so their key codes type nothing.
    try std.testing.expectEqual(@as(?u8, null), console_keys.byteOf('a'));
    // SDL3's arrow and function keys carry the scancode mask: they type nothing.
    try std.testing.expectEqual(@as(?u8, null), console_keys.byteOf(0x4000_004F));
    try std.testing.expectEqual(@as(?u8, null), console_keys.byteOf(0x80));
}

test "queued bytes reach their channels oldest first" {
    var typed = console_keys.Typed{ .io = std.testing.io };
    typed.post(8, 'h');
    typed.post(8, 'i');
    typed.post(3, '\r');
    var sink = Sink{};
    try std.testing.expectEqual(@as(usize, 3), typed.take(&sink));
    try std.testing.expectEqualStrings("hi\r", sink.bytes[0..3]);
    try std.testing.expectEqualSlices(usize, &.{ 8, 8, 3 }, sink.channels[0..3]);
    try std.testing.expectEqual(@as(usize, 0), typed.take(&sink));
}

test "past capacity the newest bytes are dropped and counted" {
    var typed = console_keys.Typed{ .io = std.testing.io };
    for (0..console_keys.capacity + 2) |_| typed.post(0, 'x');
    try std.testing.expectEqual(@as(u64, 2), typed.lost);
    try std.testing.expectEqual(console_keys.capacity, typed.len);
}

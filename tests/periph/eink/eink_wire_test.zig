//! The wire vocabulary: what a data word carries at each pixel format, what
//! the device-info block answers, and the burst the host clocks a value out
//! of.
const std = @import("std");
const ra8 = @import("ra8");
const proto = ra8.periph.eink_wire;

test "a data word carries pixels by the mode word's format field" {
    try std.testing.expectEqual(@as(u16, 8), proto.pixelsPerWord(0));
    try std.testing.expectEqual(@as(u16, 5), proto.pixelsPerWord(1));
    try std.testing.expectEqual(@as(u16, 4), proto.pixelsPerWord(2));
    try std.testing.expectEqual(@as(u16, 2), proto.pixelsPerWord(3));
}

test "the format field is two bits, so anything above them is ignored" {
    try std.testing.expectEqual(proto.pixelsPerWord(2), proto.pixelsPerWord(0xFE));
}

test "the device-info block reports the panel geometry and then zeros" {
    try std.testing.expectEqual(proto.panel.width, proto.info.word(0));
    try std.testing.expectEqual(proto.panel.height, proto.info.word(1));
    try std.testing.expectEqual(@as(u16, 0), proto.info.word(2));
    try std.testing.expectEqual(@as(u16, 0), proto.info.word(proto.info.words - 1));
}

test "a staged burst is the dummy word and then the value, MSB first" {
    var burst = proto.Burst{};
    try std.testing.expect(!burst.pending());
    burst.stage(0xBEEF);
    try std.testing.expect(burst.pending());
    try std.testing.expectEqual(@as(u8, 0), burst.next());
    try std.testing.expectEqual(@as(u8, 0), burst.next());
    try std.testing.expectEqual(@as(u8, 0xBE), burst.next());
    try std.testing.expectEqual(@as(u8, 0xEF), burst.next());
    try std.testing.expect(!burst.pending());
}

test "staging again restarts the burst" {
    var burst = proto.Burst{};
    burst.stage(0x1234);
    _ = burst.next();
    burst.stage(0x5678);
    try std.testing.expectEqual(@as(u8, 0), burst.next());
    _ = burst.next();
    try std.testing.expectEqual(@as(u8, 0x56), burst.next());
}

test "the preamble words are the three the datasheet names" {
    try std.testing.expectEqual(@as(u16, 0x6000), proto.preamble.command);
    try std.testing.expectEqual(@as(u16, 0x0000), proto.preamble.write);
    try std.testing.expectEqual(@as(u16, 0x1000), proto.preamble.read);
}

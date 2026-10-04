//! The e-ink planes: allocated at the panel geometry on first use and
//! clipping writes outside it.
const std = @import("std");
const ra8 = @import("ra8");
const eink = ra8.periph.eink;
const proto = ra8.periph.eink_wire;

test "the image plane clips writes outside the default 1072x1448 panel" {
    var panel = eink.Panel.init();
    panel.planes.allocator = std.testing.allocator;
    defer panel.deinit();
    try std.testing.expect(panel.planes.ready());
    panel.planes.image.set(1071, 1447, 0x55);
    panel.planes.image.set(1072, 0, 0xAA);
    panel.planes.image.set(0, 1448, 0xAA);
    try std.testing.expectEqual(@as(u8, 0x55), panel.planes.image.pixel(1071, 1447));
    try std.testing.expectEqual(@as(u8, 0), panel.planes.image.pixel(1072, 0));
    try std.testing.expectEqual(@as(usize, 1072 * 1448), panel.planes.glass.pixels.len);
}

test "a resized panel allocates and clips at its own geometry" {
    var panel = eink.Panel.init();
    panel.planes.allocator = std.testing.allocator;
    defer panel.deinit();
    panel.planes.resize(try proto.Geometry.parse("16x8"));
    try std.testing.expect(panel.planes.ready());
    panel.planes.image.set(15, 7, 9);
    panel.planes.image.set(16, 0, 9);
    try std.testing.expectEqual(@as(u8, 9), panel.planes.image.pixel(15, 7));
    try std.testing.expectEqual(@as(usize, 128), panel.planes.image.pixels.len);
    panel.planes.resize(.{});
    try std.testing.expectEqual(@as(usize, 0), panel.planes.image.pixels.len);
}

test "planes that cannot be allocated drop the write and count it" {
    var panel = eink.Panel.init();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    panel.planes.allocator = failing.allocator();
    defer panel.deinit();
    try std.testing.expect(!panel.planes.ready());
    try std.testing.expectEqual(@as(u32, 1), panel.planes.unplaced);
    try std.testing.expectEqual(@as(usize, 0), panel.planes.image.pixels.len);
}

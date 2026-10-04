//! The e-ink image plane clips writes outside the panel geometry.
const std = @import("std");
const eink = @import("ra8").periph.eink;

test "the image plane clips writes outside the panel" {
    var panel = eink.Panel.init();
    panel.image_buffer.set(0, 0, 0x55);
    panel.image_buffer.set(128, 0, 0xAA);
    try std.testing.expectEqual(@as(u8, 0x55), panel.image_buffer.pixel(0, 0));
    try std.testing.expectEqual(@as(u8, 0), panel.image_buffer.pixel(128, 0));
}

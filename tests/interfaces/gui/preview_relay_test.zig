//! Tests for src/interfaces/gui/preview_relay.zig: the session's thread
//! keeps a frame only when the shell asked, and the shell reads its own copy.
const std = @import("std");
const gui_app = @import("gui_app");

const Relay = gui_app.preview_relay.Relay;

fn relay() Relay {
    return .{ .io = std.testing.io, .allocator = std.testing.allocator };
}

test "nothing is kept until the shell asks" {
    var held = relay();
    defer held.deinit();
    const pixels = [_]u8{ 1, 2, 3 };
    held.offer(.{ .width = 1, .height = 1, .pixels = &pixels });
    try std.testing.expect(held.latest() == null);
}

test "an asked-for frame is kept and handed over as the shell's own copy" {
    var held = relay();
    defer held.deinit();
    try std.testing.expect(held.latest() == null);
    var pixels = [_]u8{ 1, 2, 3, 4, 5, 6 };
    held.offer(.{ .width = 2, .height = 1, .pixels = &pixels });
    const frame = held.latest() orelse return error.NoFrame;
    try std.testing.expectEqual(@as(u32, 2), frame.width);
    try std.testing.expectEqual(@as(u32, 1), frame.height);
    try std.testing.expectEqualSlices(u8, &pixels, frame.pixels);
    // The source moves on; the copy the shell holds does not.
    pixels[0] = 9;
    try std.testing.expectEqual(@as(u8, 1), frame.pixels[0]);
}

test "each ask takes one fresh frame, and a source with none keeps the last" {
    var held = relay();
    defer held.deinit();
    _ = held.latest();
    held.offer(.{ .width = 1, .height = 1, .pixels = &.{ 1, 2, 3 } });
    // Not asked again yet: the offer is passed over.
    held.wanted.store(false, .release);
    held.offer(.{ .width = 1, .height = 1, .pixels = &.{ 7, 8, 9 } });
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, (held.latest() orelse return error.NoFrame).pixels);
    held.offer(null);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, (held.latest() orelse return error.NoFrame).pixels);
    held.offer(.{ .width = 1, .height = 1, .pixels = &.{ 7, 8, 9 } });
    try std.testing.expectEqualSlices(u8, &.{ 7, 8, 9 }, (held.latest() orelse return error.NoFrame).pixels);
}

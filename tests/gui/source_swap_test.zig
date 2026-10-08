//! Covers src/gui/source_swap.zig: a posted pick is installed only when
//! the engine takes it, the old source is closed then, a second post
//! closes the pick still waiting, and deinit closes one never taken.
const std = @import("std");
const ra8 = @import("ra8");
const SourceSwap = ra8.gui.source_swap.SourceSwap;
const FrameSource = ra8.gui.camera_switch.FrameSource;
const Shape = ra8.periph.ceu.camera.frame_source.Shape;

const Held = struct {
    closed: u32 = 0,

    fn source(self: *Held, label: []const u8) FrameSource {
        return .{ .context = self, .vtable = &.{ .frame = frame, .fill = fill, .close = close }, .label = label };
    }

    fn frame(_: *anyopaque, _: u64, _: Shape) void {}

    fn fill(_: *anyopaque, _: u32, _: u32, out: []u8) void {
        @memset(out, 0);
    }

    fn close(context: *anyopaque) void {
        const self: *Held = @ptrCast(@alignCast(context));
        self.closed += 1;
    }
};

test "a post waits for the engine, which closes the old source as it installs" {
    var old = Held{};
    var new = Held{};
    var running = old.source("old");
    var swap = SourceSwap{ .io = std.testing.io };
    defer swap.deinit();
    try std.testing.expect(!swap.take(&running));
    swap.post(new.source("new"));
    try std.testing.expectEqualStrings("old", running.label);
    try std.testing.expect(swap.take(&running));
    try std.testing.expectEqualStrings("new", running.label);
    try std.testing.expectEqual(@as(u32, 1), old.closed);
    try std.testing.expectEqual(@as(u32, 0), new.closed);
    try std.testing.expect(!swap.take(&running));
}

test "the newest post wins and a pick never taken is closed with the swap" {
    var first = Held{};
    var second = Held{};
    var swap = SourceSwap{ .io = std.testing.io };
    swap.post(first.source("first"));
    swap.post(second.source("second"));
    try std.testing.expectEqual(@as(u32, 1), first.closed);
    swap.deinit();
    try std.testing.expectEqual(@as(u32, 1), second.closed);
}

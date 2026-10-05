//! Covers src/gui/camera_pane.zig: window events drive the camera panel,
//! and the CEU's source follows its pick between steps.
const std = @import("std");
const ra8 = @import("ra8");
const camera_pane = ra8.gui.camera_pane;
const FrameSource = ra8.gui.camera_switch.FrameSource;
const Rect = ra8.gui.draw_list.Rect;

const Fake = struct {
    closed: u32 = 0,

    fn source(self: *Fake) FrameSource {
        return .{ .context = self, .vtable = &vtable, .label = "fake" };
    }

    const vtable = FrameSource.VTable{ .frame = frame, .fill = fill, .close = close };

    fn frame(_: *anyopaque, _: u64, _: ra8.periph.ceu.camera.frame_source.Shape) void {}

    fn fill(_: *anyopaque, _: u32, _: u32, out: []u8) void {
        @memset(out, 0);
    }

    fn close(context: *anyopaque) void {
        const self: *Fake = @ptrCast(@alignCast(context));
        self.closed += 1;
    }
};

fn press(at: Rect, button: u8, down: bool) ra8.gui.platform.Event {
    return .{ .button = .{ .button = button, .down = down, .x = at.x + 1, .y = at.y + 1 } };
}

test "a primary press on a source picks it; release, other buttons and motion do not" {
    var pane = camera_pane.Pane{ .layout = .{ .x = 0, .y = 0 } };
    const video = pane.layout.source(.video);
    try std.testing.expect(!pane.handle(press(video, 3, true)));
    try std.testing.expect(!pane.handle(press(video, camera_pane.primary_button, false)));
    try std.testing.expect(!pane.handle(.{ .pointer = .{ .x = video.x + 1, .y = video.y + 1 } }));
    try std.testing.expectEqual(.gradient, pane.panel.active);
    try std.testing.expect(pane.handle(press(video, camera_pane.primary_button, true)));
    try std.testing.expectEqual(.video, pane.panel.active);
}

test "a press away from the pane is left for the board" {
    var pane = camera_pane.Pane{ .layout = .{ .x = 0, .y = 0 } };
    const far = Rect{ .x = 900, .y = 500, .w = 1, .h = 1 };
    try std.testing.expect(!pane.handle(press(far, camera_pane.primary_button, true)));
}

test "settle keeps the running source until the panel switches" {
    var pane = camera_pane.Pane{ .layout = .{ .x = 0, .y = 0 } };
    var fake = Fake{};
    var source = fake.source();
    const format: u8 = 0;
    pane.settle(std.testing.allocator, &source, &format);
    try std.testing.expectEqual(@as(u32, 0), fake.closed);
    try std.testing.expectEqualStrings("fake", source.label);
}

test "a pick that will not open leaves the source; the next pick that opens replaces it" {
    var pane = camera_pane.Pane{ .layout = .{ .x = 0, .y = 0 }, .args = .{ .image = "/nonexistent/ra8-pane.png" } };
    var fake = Fake{};
    var source = fake.source();
    const format: u8 = 0;
    _ = pane.handle(press(pane.layout.source(.image), camera_pane.primary_button, true));
    pane.settle(std.testing.allocator, &source, &format);
    try std.testing.expectEqual(@as(u32, 0), fake.closed);
    try std.testing.expectEqualStrings("fake", source.label);
    pane.settle(std.testing.allocator, &source, &format);
    try std.testing.expectEqual(@as(u32, 0), fake.closed);
    _ = pane.handle(press(pane.layout.source(.gradient), camera_pane.primary_button, true));
    pane.settle(std.testing.allocator, &source, &format);
    defer source.close();
    try std.testing.expectEqual(@as(u32, 1), fake.closed);
    try std.testing.expectEqualStrings("synthetic gradient", source.label);
}

test "draw puts the panel into the frame's list" {
    const pane = camera_pane.Pane{ .layout = .{ .x = 4, .y = 4 } };
    var list = ra8.gui.draw_list.DrawList.init(std.testing.allocator, 256, 128);
    defer list.deinit();
    try pane.draw(&list);
    try std.testing.expect(list.commands.items.len > 0);
}

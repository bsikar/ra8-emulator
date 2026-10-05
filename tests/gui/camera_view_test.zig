//! Covers src/gui/camera_view.zig: what the camera panel draws through the
//! CPU rasterizer, and how clicks on it pick sources and answer the webcam
//! dialog.
const std = @import("std");
const ra8 = @import("ra8");
const draw_list = ra8.gui.draw_list;
const raster = ra8.gui.raster;
const view = ra8.gui.camera_view;
const Panel = ra8.gui.camera_panel.Panel;
const Rect = draw_list.Rect;

const layout = view.Layout{ .x = 10, .y = 20 };

fn centre(at: Rect) [2]i32 {
    return .{ at.x + @divTrunc(at.w, 2), at.y + @divTrunc(at.h, 2) };
}

fn render(panel: Panel) !raster.Framebuffer {
    var list = draw_list.DrawList.init(std.testing.allocator, 256, 128);
    defer list.deinit();
    try view.draw(&list, layout, panel);
    var frame = try raster.Framebuffer.init(std.testing.allocator, 256, 128);
    raster.draw(&frame, &list, null);
    return frame;
}

fn pixel(frame: *const raster.Framebuffer, at: Rect) draw_list.Color {
    const c = centre(at);
    return frame.at(@intCast(c[0]), @intCast(c[1]));
}

test "every source has its button and the active one is ringed" {
    var frame = try render(.{});
    defer frame.deinit(std.testing.allocator);
    for (std.enums.values(ra8.gui.camera_panel.Kind)) |kind| {
        try std.testing.expectEqual(view.colorOf(kind), pixel(&frame, layout.source(kind)));
    }
    const gradient = layout.source(.gradient);
    try std.testing.expectEqual(view.ring, frame.at(@intCast(gradient.x - 1), @intCast(gradient.y)));
    const image = layout.source(.image);
    try std.testing.expectEqual(view.background, frame.at(@intCast(image.x - 1), @intCast(image.y)));
}

test "the dot is red only while the webcam is the source" {
    var panel = Panel{};
    var off = try render(panel);
    defer off.deinit(std.testing.allocator);
    try std.testing.expectEqual(view.camera_off, pixel(&off, layout.indicator()));
    panel.pick(.webcam);
    panel.answer(.allow_once);
    var on = try render(panel);
    defer on.deinit(std.testing.allocator);
    try std.testing.expectEqual(view.camera_on, pixel(&on, layout.indicator()));
}

test "the dialog shows only while the webcam is being asked" {
    var panel = Panel{};
    var closed = try render(panel);
    defer closed.deinit(std.testing.allocator);
    try std.testing.expectEqual(view.background, pixel(&closed, layout.dialog(.always)));
    panel.pick(.webcam);
    var open = try render(panel);
    defer open.deinit(std.testing.allocator);
    try std.testing.expectEqual(view.answerColor(.always), pixel(&open, layout.dialog(.always)));
}

test "clicking a source picks it" {
    var panel = Panel{};
    const c = centre(layout.source(.video));
    try std.testing.expect(view.click(&panel, layout, c[0], c[1]));
    try std.testing.expectEqual(.video, panel.active);
}

test "the webcam goes live only through the dialog" {
    var panel = Panel{};
    const cam = centre(layout.source(.webcam));
    try std.testing.expect(view.click(&panel, layout, cam[0], cam[1]));
    try std.testing.expect(panel.asking);
    try std.testing.expect(!panel.cameraOn());
    const cancel = centre(layout.dialog(.cancel));
    try std.testing.expect(view.click(&panel, layout, cancel[0], cancel[1]));
    try std.testing.expect(!panel.cameraOn());
    _ = view.click(&panel, layout, cam[0], cam[1]);
    const once = centre(layout.dialog(.allow_once));
    try std.testing.expect(view.click(&panel, layout, once[0], once[1]));
    try std.testing.expect(panel.cameraOn());
}

test "the dialog row does nothing while closed and clicks outside are not taken" {
    var panel = Panel{};
    const once = centre(layout.dialog(.allow_once));
    try std.testing.expect(view.click(&panel, layout, once[0], once[1]));
    try std.testing.expectEqual(.gradient, panel.active);
    try std.testing.expect(!view.click(&panel, layout, 0, 0));
    try std.testing.expect(!view.click(&panel, layout, 250, 120));
}

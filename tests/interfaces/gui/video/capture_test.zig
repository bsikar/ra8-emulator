//! Tests for src/interfaces/gui/video/capture.zig: the decorator passes
//! every window call through, a frame the window draws itself counts as a
//! frame for the script, and a recording rasterizes every frame instead.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const stub_window = @import("../stub_window.zig");

const Capture = gui_app.video.capture.Capture;
const draw_list = ra8.render.draw_list;

test "every window call reaches the window behind the capture" {
    var stub: stub_window.Stub = .{};
    var cap = Capture.init(std.testing.allocator, stub.platform());
    defer cap.deinit();
    try stub_window.expectPassesThrough(cap.platform(), &stub);
}

test "a frame the window draws itself counts, and the script polls again after it" {
    var stub: stub_window.Stub = .{};
    var cap = Capture.init(std.testing.allocator, stub.platform());
    defer cap.deinit();
    const shown = cap.platform();
    var list = draw_list.DrawList.init(std.testing.allocator, 4, 4);
    defer list.deinit();
    _ = shown.poll();
    try std.testing.expect(cap.polled_this_frame);
    try std.testing.expect(try shown.show(&list, null));
    try std.testing.expectEqual(@as(u32, 1), stub.shows);
    try std.testing.expectEqual(@as(u32, 1), cap.frame_counter);
    try std.testing.expect(!cap.polled_this_frame);
}

test "a window that does not draw the list leaves the frame to present" {
    var stub: stub_window.Stub = .{ .draws = false };
    var cap = Capture.init(std.testing.allocator, stub.platform());
    defer cap.deinit();
    var list = draw_list.DrawList.init(std.testing.allocator, 4, 4);
    defer list.deinit();
    try std.testing.expect(!try cap.platform().show(&list, null));
    try std.testing.expectEqual(@as(u32, 0), cap.frame_counter);
}

test "while recording, every frame is rasterized so it can be kept" {
    var stub: stub_window.Stub = .{};
    var cap = Capture.init(std.testing.allocator, stub.platform());
    defer cap.deinit();
    // Only whether a writer is set is read here.
    var writer: gui_app.video.writer.Writer = undefined;
    cap.writer = &writer;
    var list = draw_list.DrawList.init(std.testing.allocator, 4, 4);
    defer list.deinit();
    try std.testing.expect(!try cap.platform().show(&list, null));
    try std.testing.expectEqual(@as(u32, 0), stub.shows);
    try std.testing.expectEqual(@as(u32, 0), cap.frame_counter);
}

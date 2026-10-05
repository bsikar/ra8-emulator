//! Tests for src/interfaces/cli/window_stills.zig: the recorder passes the
//! window through untouched and keeps every n-th frame as a numbered PNG.
const std = @import("std");
const ra8 = @import("ra8");
const stills = ra8.board.report.window_stills;
const png = ra8.board.report.png;
const raster = ra8.gui.raster;
const Headless = ra8.gui.headless.Headless;
const Color = ra8.gui.draw_list.Color;

fn frameOf(shade: u8) !raster.Framebuffer {
    const frame = try raster.Framebuffer.init(std.testing.allocator, 4, 3);
    @memset(frame.pixels, Color.rgb(shade, shade, shade));
    return frame;
}

test "the recorder passes events, size, scale and frames through" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var window = Headless.init(std.testing.allocator, 640, 480);
    defer window.deinit();
    window.dpi = 2.0;
    try window.feed(.quit);
    var recorder = stills.Recorder{ .allocator = std.testing.allocator, .inner = window.platform(), .dir = tmp.dir, .stem = "w" };
    const shown = recorder.platform();
    try std.testing.expectEqual(@as(u32, 640), shown.size().width);
    try std.testing.expectEqual(@as(f32, 2.0), shown.scale());
    try std.testing.expect(shown.poll().? == .quit);
    try std.testing.expect(shown.poll() == null);
    var frame = try frameOf(5);
    defer frame.deinit(std.testing.allocator);
    try shown.present(&frame);
    try std.testing.expectEqual(@as(u32, 1), window.presents);
    try std.testing.expectEqual(Color.rgb(5, 5, 5), window.last.?.pixels[0]);
}

test "every n-th frame is kept, numbered from zero" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var window = Headless.init(std.testing.allocator, 4, 3);
    defer window.deinit();
    var recorder = stills.Recorder{ .allocator = std.testing.allocator, .inner = window.platform(), .dir = tmp.dir, .stem = "pane", .every = 2 };
    const shown = recorder.platform();
    for (0..5) |shade| {
        var frame = try frameOf(@intCast(shade));
        defer frame.deinit(std.testing.allocator);
        try shown.present(&frame);
    }
    try std.testing.expectEqual(@as(u32, 5), recorder.frames);
    try std.testing.expectEqual(@as(u32, 3), recorder.saved);
    for ([_][]const u8{ "pane-0000.png", "pane-0001.png", "pane-0002.png" }) |file_name| {
        const bytes = try tmp.dir.readFileAlloc(std.testing.allocator, file_name, 1 << 16);
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualSlices(u8, &png.signature, bytes[0..8]);
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("pane-0003.png", .{}));
}

test "an every of zero keeps each frame" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var window = Headless.init(std.testing.allocator, 4, 3);
    defer window.deinit();
    const recorder = stills.Recorder{ .allocator = std.testing.allocator, .inner = window.platform(), .dir = tmp.dir, .stem = "w", .every = 0 };
    try std.testing.expect(recorder.keeps(0));
    try std.testing.expect(recorder.keeps(7));
}

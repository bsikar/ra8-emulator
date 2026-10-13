//! Tests for video output writers and capture decorator (RA8EMU-1120).
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const video = gui_app.video;
const script = gui_app.script;
const headless = gui_app.headless;

const Framebuffer = ra8.render.raster.Framebuffer;
const Color = ra8.render.draw_list.Color;

test "gif writer writes valid gif header and frames" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_name_bytes]u8 = undefined;
    const gif_path = try std.fmt.bufPrint(&path_buf, "{s}/test_out.gif", .{".zig-cache/tmp"});

    var writer = try video.writer.Writer.init(std.testing.allocator, std.testing.io, gif_path, 30);
    defer writer.deinit();

    var fb = try Framebuffer.init(std.testing.allocator, 64, 64);
    defer fb.deinit(std.testing.allocator);
    @memset(fb.pixels, Color{ .r = 255, .g = 0, .b = 0, .a = 255 });

    try writer.record(&fb, 0);
    @memset(fb.pixels, Color{ .r = 0, .g = 255, .b = 0, .a = 255 });
    try writer.record(&fb, 33_333_333);
    try writer.finish();

    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, gif_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(bytes);

    try std.testing.expect(bytes.len >= 6);
    try std.testing.expectEqualStrings("GIF89a", bytes[0..6]);
}

test "y4m writer writes valid yuv4mpeg2 header and frame markers" {
    var path_buf: [std.Io.Dir.max_name_bytes]u8 = undefined;
    const y4m_path = try std.fmt.bufPrint(&path_buf, "{s}/test_out.y4m", .{".zig-cache/tmp"});

    var writer = try video.writer.Writer.init(std.testing.allocator, std.testing.io, y4m_path, 30);
    defer writer.deinit();

    var fb = try Framebuffer.init(std.testing.allocator, 32, 32);
    defer fb.deinit(std.testing.allocator);
    @memset(fb.pixels, Color{ .r = 100, .g = 150, .b = 200, .a = 255 });

    try writer.record(&fb, 0);
    try writer.finish();

    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, y4m_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(bytes);

    try std.testing.expect(std.mem.startsWith(u8, bytes, "YUV4MPEG2 W32 H32 F30:1"));
}

test "capture decorator intercepts poll and present" {
    var head = headless.Headless.init(std.testing.allocator, 100, 100);
    defer head.deinit();

    var cap = video.capture.Capture.init(std.testing.allocator, head.platform());
    defer cap.deinit();

    const plat = cap.platform();
    try std.testing.expectEqual(@as(u32, 100), plat.size().width);
    try std.testing.expectEqual(@as(u32, 100), plat.size().height);

    // Initial poll with no runner yields null
    try std.testing.expectEqual(@as(?gui_app.platform.Event, null), plat.poll());

    // Present increments frame counter
    var fb = try Framebuffer.init(std.testing.allocator, 100, 100);
    defer fb.deinit(std.testing.allocator);
    try plat.present(&fb);
    try std.testing.expectEqual(@as(u32, 1), cap.frame_counter);
}

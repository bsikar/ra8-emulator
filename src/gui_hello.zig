//! `zig build gui-hello -Dgui`: the SDL3 window drawing a fixed draw list
//! (RA8EMU-616). It proves the platform seam, the CPU rasterizer and the
//! SDL texture path on a real window before any widget exists.
//!
//!   gui-hello              run until the window is closed or Escape
//!   gui-hello --frames N   present N frames and exit (a smoke run; with
//!                          SDL_VIDEO_DRIVER=offscreen it needs no display)
//!
//! Frames draw through SDL geometry; RA8_GUI_CPU=1 forces the CPU path.
const std = @import("std");
const ra8 = @import("ra8");
const sdl = @import("gui_sdl");

const gui = ra8.gui;
const Color = gui.draw_list.Color;
const escape_key: u32 = 0x1b;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const frames = try frameLimit(allocator);
    var backend = try sdl.Sdl.init("ra8 gui-hello", 640, 400);
    defer backend.deinit();
    const window = backend.platform();

    var size = window.size();
    var frame = try gui.raster.Framebuffer.init(allocator, size.width, size.height);
    defer frame.deinit(allocator);
    var list = gui.draw_list.DrawList.init(allocator, size.width, size.height);
    defer list.deinit();

    var shown: u64 = 0;
    while (frames == null or shown < frames.?) : (shown += 1) {
        while (window.poll()) |event| switch (event) {
            .quit => return,
            .key => |k| if (k.down and k.code == escape_key) return,
            else => {},
        };
        const now = window.size();
        if (now.width != size.width or now.height != size.height) {
            size = now;
            frame.deinit(allocator);
            frame = try gui.raster.Framebuffer.init(allocator, size.width, size.height);
            list.deinit();
            list = gui.draw_list.DrawList.init(allocator, size.width, size.height);
        }
        list.clear();
        try scene(&list, size);
        if (try window.show(&list, null)) continue;
        gui.raster.draw(&frame, &list, null);
        try window.present(&frame);
    }
    const path = if (backend.presenter != null) "geometry" else "cpu";
    std.debug.print("gui-hello: {d} frames at {d}x{d} through {s}\n", .{ shown, size.width, size.height, path });
}

/// --frames N, or null to run until closed.
fn frameLimit(allocator: std.mem.Allocator) !?u64 {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--frames") and i + 1 < args.len) {
            return try std.fmt.parseInt(u64, args[i + 1], 10);
        }
    }
    return null;
}

/// The fixed list: the dark theme background, a panel, a clipped bar that
/// runs past its panel, a diagonal and a translucent overlay.
fn scene(list: *gui.draw_list.DrawList, size: gui.platform.Size) !void {
    const w: i32 = @intCast(size.width);
    const h: i32 = @intCast(size.height);
    try list.fill(.{ .x = 0, .y = 0, .w = w, .h = h }, Color.rgb(0x28, 0x2c, 0x34));
    const panel: gui.draw_list.Rect = .{ .x = 24, .y = 24, .w = @divTrunc(w, 2), .h = @divTrunc(h, 2) };
    try list.fill(panel, Color.rgb(0x3b, 0x42, 0x52));
    try list.pushClip(panel);
    try list.fill(.{ .x = 40, .y = 60, .w = w, .h = 24 }, Color.rgb(0x88, 0xc0, 0xd0));
    list.popClip();
    try list.line(0, h - 1, w - 1, 0, Color.rgb(0xd8, 0xde, 0xe9));
    try list.fill(.{ .x = @divTrunc(w, 3), .y = @divTrunc(h, 3), .w = @divTrunc(w, 3), .h = @divTrunc(h, 3) }, .{ .r = 0xbf, .g = 0x61, .b = 0x6a, .a = 128 });
}

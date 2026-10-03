//! `--frame-out PATH`: what the panel shows when the run ends, as a PNG
//! (RA8EMU-73). It scans the GLCDC once more with a capture armed on the
//! output stage, after the report has printed, so the report is unchanged.
//! The PNG is the board view: the panel inside the EK-RA8D2 outline with
//! the user LEDs as the pins left them (board_view.zig).
const std = @import("std");
const Board = @import("../../board/board.zig").Board;
const gpio = @import("../../periph/gpio/gpio.zig");
const png = @import("png.zig");
pub const board_view = @import("board_view.zig");

pub const Error = error{NoFrame};

/// The panel's size and the size of the view that was written.
pub const Saved = struct { width: u32, height: u32, view: board_view.Size };

/// A panel has no transparency: what reaches the glass is the colour, so
/// every pixel goes out opaque. `rgba` holds four bytes per pixel.
pub fn opaqueRgba(pixels: []const u32, rgba: []u8) png.Error!void {
    try png.fromArgb(pixels, rgba);
    var at: usize = 3;
    while (at < rgba.len) : (at += png.bytes_per_pixel) rgba[at] = 0xFF;
}

/// Scan the panel into a buffer and write it to `path` as a PNG.
pub fn save(allocator: std.mem.Allocator, board: *Board, path: []const u8) !Saved {
    const unit = &board.display;
    const width = unit.panelWidth();
    const height = unit.panelHeight();
    if (width == 0 or height == 0) return Error.NoFrame;
    const pixels = try allocator.alloc(u32, @as(usize, width) * height);
    defer allocator.free(pixels);
    @memset(pixels, 0);
    unit.output.capture = .{ .pixels = pixels, .width = width, .height = height };
    defer unit.output.capture = null;
    _ = unit.scanOut() orelse return Error.NoFrame;
    const view = board_view.size(width, height);
    const canvas = try allocator.alloc(u32, @as(usize, view.width) * view.height);
    defer allocator.free(canvas);
    board_view.compose(canvas, pixels, width, height, &ledsOf(board));
    try write(allocator, canvas, view, path);
    return .{ .width = width, .height = height, .view = view };
}

/// The user LEDs as the pins left them at the end of the run.
pub fn ledsOf(board: *Board) [gpio.led_count]board_view.Led {
    var lit: [gpio.led_count]board_view.Led = undefined;
    for (gpio.leds, 0..) |led, i| lit[i] = .{ .rgb565 = led.rgb565, .on = board.pins.ledLevel(i) == 1 };
    return lit;
}

fn write(allocator: std.mem.Allocator, canvas: []const u32, view: board_view.Size, path: []const u8) !void {
    const rgba = try allocator.alloc(u8, canvas.len * png.bytes_per_pixel);
    defer allocator.free(rgba);
    try opaqueRgba(canvas, rgba);
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var buffered = std.io.bufferedWriter(file.writer());
    try png.encode(allocator, buffered.writer(), view.width, view.height, rgba);
    try buffered.flush();
}

/// One line for the end of the run: where the frame went, or why none did.
pub fn report(out: anytype, board: *Board, path: ?[]const u8) !void {
    const target = path orelse return;
    const saved = save(std.heap.page_allocator, board, target) catch |err| switch (err) {
        Error.NoFrame => return out.print("frame-out: the panel showed no frame, {s} not written\n", .{target}),
        else => return err,
    };
    try out.print("frame-out: {d}x{d} panel on a {d}x{d} board view written to {s}\n", .{
        saved.width, saved.height, saved.view.width, saved.view.height, target,
    });
}

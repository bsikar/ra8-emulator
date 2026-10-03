//! `--frame-out PATH`: what the panel shows when the run ends, as a PNG
//! (RA8EMU-73). It scans the GLCDC once more with a capture armed on the
//! output stage, after the report has printed, so the report is unchanged.
const std = @import("std");
const Board = @import("../../board/board.zig").Board;
const png = @import("png.zig");

pub const Error = error{NoFrame};

/// The size of the frame that was written.
pub const Saved = struct { width: u32, height: u32 };

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
    const rgba = try allocator.alloc(u8, pixels.len * png.bytes_per_pixel);
    defer allocator.free(rgba);
    try opaqueRgba(pixels, rgba);
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var buffered = std.io.bufferedWriter(file.writer());
    try png.encode(allocator, buffered.writer(), width, height, rgba);
    try buffered.flush();
    return .{ .width = width, .height = height };
}

/// One line for the end of the run: where the frame went, or why none did.
pub fn report(out: anytype, board: *Board, path: ?[]const u8) !void {
    const target = path orelse return;
    const saved = save(std.heap.page_allocator, board, target) catch |err| switch (err) {
        Error.NoFrame => return out.print("frame-out: the panel showed no frame, {s} not written\n", .{target}),
        else => return err,
    };
    try out.print("frame-out: {d}x{d} panel written to {s}\n", .{ saved.width, saved.height, target });
}

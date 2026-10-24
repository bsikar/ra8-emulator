//! Grayscale conversion, diff.box delta cropping, and flate-1 compression (milestone M7).
//!
//! Stored frames use 8-bit grayscale up to 1024x600 pixels (~614 KB full frame).
//! An intra-segment frame stores only the minimal bounding box of differing pixels
//! against the segment keyframe, compressed with std.compress.flate level 1.
const std = @import("std");
const frame_types = @import("frame_types.zig");

pub const Rect = frame_types.Rect;

pub const Error = error{
    BadFrameShape,
    BadCropShape,
    Truncated,
    Corrupt,
    OutOfMemory,
};

/// Convert an ARGB8888 word to 8-bit grayscale using standard CCIR 601 luma.
pub fn argbToGray(argb: u32) u8 {
    const red = (argb >> 16) & 0xFF;
    const green = (argb >> 8) & 0xFF;
    const blue = argb & 0xFF;
    return @intCast((red * 299 + green * 587 + blue * 114 + 500) / 1000);
}

/// Convert a buffer of ARGB8888 pixels into 8-bit grayscale bytes.
pub fn toGray(argb: []const u32, gray: []u8) void {
    std.debug.assert(gray.len == argb.len);
    for (argb, gray) |pixel, *out| {
        out.* = argbToGray(pixel);
    }
}

/// The minimal bounding box covering differing pixels between `before` and `after`.
/// Null when both frames are identical.
pub fn diffBox(before: []const u8, after: []const u8, width: u32) ?Rect {
    if (width == 0 or before.len != after.len or before.len % width != 0) return null;
    const rows = before.len / width;
    var top: usize = 0;
    while (top < rows and firstDiff(before, after, width, top) == null) top += 1;
    if (top == rows) return null;
    var bottom: usize = rows - 1;
    while (firstDiff(before, after, width, bottom) == null) bottom -= 1;
    var left: usize = width;
    var right: usize = 0;
    for (top..bottom + 1) |row| {
        const first = firstDiff(before, after, width, row) orelse continue;
        left = @min(left, first);
        right = @max(right, lastDiff(before, after, width, row));
    }
    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(right - left + 1),
        .height = @intCast(bottom - top + 1),
    };
}

fn firstDiff(before: []const u8, after: []const u8, width: u32, row: usize) ?usize {
    const from = row * width;
    const b_row = before[from .. from + width];
    const a_row = after[from .. from + width];
    for (b_row, a_row, 0..) |b, a, col| {
        if (b != a) return col;
    }
    return null;
}

fn lastDiff(before: []const u8, after: []const u8, width: u32, row: usize) usize {
    const from = row * width;
    const b_row = before[from .. from + width];
    const a_row = after[from .. from + width];
    var col: usize = width;
    while (col > 0) {
        col -= 1;
        if (b_row[col] != a_row[col]) return col;
    }
    return 0;
}

/// Extract pixels inside `rect` from `frame` into `out`.
pub fn extractCrop(frame: []const u8, frame_width: u32, rect: Rect, out: []u8) void {
    const expected = @as(usize, rect.width) * rect.height;
    std.debug.assert(out.len == expected);
    var dest_at: usize = 0;
    var r: usize = 0;
    while (r < rect.height) : (r += 1) {
        const src_at = (@as(usize, rect.y) + r) * frame_width + rect.x;
        @memcpy(out[dest_at .. dest_at + rect.width], frame[src_at .. src_at + rect.width]);
        dest_at += rect.width;
    }
}

/// Apply `crop` pixels inside `rect` onto `target` in place.
pub fn applyCrop(target: []u8, frame_width: u32, rect: Rect, crop: []const u8) void {
    const expected = @as(usize, rect.width) * rect.height;
    std.debug.assert(crop.len == expected);
    var src_at: usize = 0;
    var r: usize = 0;
    while (r < rect.height) : (r += 1) {
        const dest_at = (@as(usize, rect.y) + r) * frame_width + rect.x;
        @memcpy(target[dest_at .. dest_at + rect.width], crop[src_at .. src_at + rect.width]);
        src_at += rect.width;
    }
}

/// Compress an uncompressed byte slice with flate level 1 (raw deflate).
pub fn compress(allocator: std.mem.Allocator, uncompressed: []const u8) ![]u8 {
    if (uncompressed.len == 0) return try allocator.alloc(u8, 0);
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 1024);
    defer out.deinit();
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var deflater = try std.compress.flate.Compress.init(&out.writer, window, .raw, .level_1);
    try deflater.writer.writeAll(uncompressed);
    try deflater.finish();
    return try allocator.dupe(u8, out.written());
}

/// Decompress raw flate data into caller-supplied `uncompressed` buffer.
pub fn decompress(allocator: std.mem.Allocator, compressed: []const u8, uncompressed: []u8) !void {
    if (compressed.len == 0 and uncompressed.len == 0) return;
    if (compressed.len == 0 and uncompressed.len > 0) return Error.Truncated;
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var reader: std.Io.Reader = .fixed(compressed);
    var inflater: std.compress.flate.Decompress = .init(&reader, .raw, window);
    inflater.reader.readSliceAll(uncompressed) catch |err| return switch (err) {
        error.EndOfStream => Error.Truncated,
        error.ReadFailed => if (inflater.err) |ie| (if (ie == error.EndOfStream) Error.Truncated else Error.Corrupt) else Error.Corrupt,
    };
    _ = inflater.reader.takeByte() catch |err| switch (err) {
        error.EndOfStream => {},
        else => return Error.Corrupt,
    };
    if (reader.seek < reader.end) return Error.Corrupt;
}

/// Reconstruct a full frame by copying `keyframe`, decompressing delta crop,
/// and applying it inside `rect`.
pub fn reconstruct(
    allocator: std.mem.Allocator,
    keyframe: []const u8,
    frame_width: u32,
    rect: Rect,
    compressed_crop: []const u8,
) ![]u8 {
    if (frame_width == 0) return Error.BadFrameShape;
    if (@as(usize, rect.x) + rect.width > frame_width) return Error.BadCropShape;
    const max_y = @as(usize, rect.y) + rect.height;
    if (max_y * frame_width > keyframe.len) return Error.BadCropShape;

    const full = try allocator.dupe(u8, keyframe);
    errdefer allocator.free(full);
    const crop_len = @as(usize, rect.width) * rect.height;
    if (crop_len == 0) return full;
    const crop_buf = try allocator.alloc(u8, crop_len);
    defer allocator.free(crop_buf);
    try decompress(allocator, compressed_crop, crop_buf);
    applyCrop(full, frame_width, rect, crop_buf);
    return full;
}

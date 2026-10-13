//! The default camera source: the diagonal gradient the CEU always painted,
//! byte (x + y) & 0xFF of the destination buffer, so a real grab always
//! varies and a min/max/mean over it is never degenerate. It holds no state
//! and ignores the time, so every frame is the same frame.
const frame_source = @import("frame_source.zig");

pub const pattern = struct {
    pub const mask: u32 = 0xFF;
    /// The gradient repeats every 256 bytes, so one chunk fills any line.
    pub const chunk: u32 = 256;
};

/// The gradient as a FrameSource. It has no state, so no context either.
pub fn source() frame_source.FrameSource {
    return .{ .context = undefined, .vtable = &vtable };
}

const vtable = frame_source.FrameSource.VTable{
    .frame = frame,
    .fill = fill,
    .close = close,
    .preview = preview,
};

const preview_w = 160;
const preview_h = 120;
var preview_pixels: [preview_w * preview_h * 3]u8 = undefined;
var preview_ready: bool = false;

fn preview(_: *anyopaque) ?frame_source.Preview {
    if (!preview_ready) {
        for (0..preview_h) |y| {
            for (0..preview_w) |x| {
                const b: u8 = @truncate((x +% y) & pattern.mask);
                const i = (y * preview_w + x) * 3;
                preview_pixels[i] = b;
                preview_pixels[i + 1] = b;
                preview_pixels[i + 2] = b;
            }
        }
        preview_ready = true;
    }
    return .{
        .width = preview_w,
        .height = preview_h,
        .pixels = &preview_pixels,
    };
}

fn frame(_: *anyopaque, _: u64, _: frame_source.Shape) void {}

fn fill(_: *anyopaque, row: u32, column: u32, out: []u8) void {
    for (out, 0..) |*byte, index| {
        byte.* = @truncate((column +% row +% @as(u32, @intCast(index))) & pattern.mask);
    }
}

fn close(_: *anyopaque) void {}

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

const vtable = frame_source.FrameSource.VTable{ .frame = frame, .fill = fill, .close = close };

fn frame(_: *anyopaque, _: u64, _: frame_source.Shape) void {}

fn fill(_: *anyopaque, row: u32, column: u32, out: []u8) void {
    for (out, 0..) |*byte, index| {
        byte.* = @truncate((column +% row +% @as(u32, @intCast(index))) & pattern.mask);
    }
}

fn close(_: *anyopaque) void {}

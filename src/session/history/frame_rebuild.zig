//! Rebuilds one stored frame's gray pixels from its compressed payload
//! (and, for a delta, its segment keyframe's payload). Pure: it holds no
//! cache state, so a caller decodes outside any lock it copied the
//! payload bytes under.
const std = @import("std");
const frame_types = @import("frame_types.zig");
const frame_crop = @import("frame_crop.zig");
const picture = @import("checkpoint_picture.zig");

pub const Error = error{NoKeyframe} || frame_types.Error || frame_crop.Error;

/// The picture `header` stands for. `payload` is the frame's own
/// compressed bytes; `key_payload` is its segment keyframe's, required
/// for a delta and ignored for a keyframe.
pub fn rebuild(
    allocator: std.mem.Allocator,
    header: frame_types.FrameHeader,
    payload: []const u8,
    key_payload: ?[]const u8,
) !picture.Decoded {
    var out: picture.Decoded = .{
        .position = header.position,
        .virtual_ns = header.virtual_ns,
        .width = header.width,
        .height = header.height,
        .pixels = undefined,
    };
    const count = @as(usize, header.width) * header.height;
    if (header.kind == .keyframe) {
        out.pixels = try allocator.alloc(u8, count);
        errdefer allocator.free(out.pixels);
        try frame_crop.decompress(allocator, payload, out.pixels);
        return out;
    }
    const key = key_payload orelse return Error.NoKeyframe;
    const key_pixels = try allocator.alloc(u8, count);
    defer allocator.free(key_pixels);
    try frame_crop.decompress(allocator, key, key_pixels);
    out.pixels = try frame_crop.reconstruct(allocator, key_pixels, header.width, header.rect, payload);
    return out;
}

//! Owned presentation frame and its history source.
const Position = @import("position.zig").Position;
const std = @import("std");

pub const SourceKind = enum {
    frame_cache,
    decoded_segment,
    checkpoint_picture,
};

/// One decoded frame presented during playback.
pub const DecodedFrame = struct {
    position: Position,
    virtual_ns: u64,
    width: u16,
    height: u16,
    pixels: []u8,
    source: SourceKind,

    pub fn deinit(self: *DecodedFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.pixels = &.{};
    }

    pub fn dupe(self: *const DecodedFrame, allocator: std.mem.Allocator) !DecodedFrame {
        const px = try allocator.dupe(u8, self.pixels);
        return .{
            .position = self.position,
            .virtual_ns = self.virtual_ns,
            .width = self.width,
            .height = self.height,
            .pixels = px,
            .source = self.source,
        };
    }
};

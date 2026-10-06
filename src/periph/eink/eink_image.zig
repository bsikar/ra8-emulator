//! The IT8951's host image plane and refreshed glass plane.

const std = @import("std");
const proto = @import("eink_wire.zig");

/// A grayscale plane at one panel geometry. Empty until sized, and a write
/// outside it is dropped, so a load never runs past the reported panel.
pub const Buffer = struct {
    width: u16 = 0,
    height: u16 = 0,
    pixels: []u8 = &.{},

    pub fn alloc(allocator: std.mem.Allocator, geometry: proto.Geometry) !Buffer {
        const pixels = try allocator.alloc(u8, geometry.pixels());
        @memset(pixels, 0);
        return .{ .width = geometry.width, .height = geometry.height, .pixels = pixels };
    }

    pub fn free(self: *Buffer, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = .{};
    }

    pub fn pixel(self: *const Buffer, x: u16, y: u16) u8 {
        if (x >= self.width or y >= self.height) return 0;
        return self.pixels[@as(usize, y) * self.width + x];
    }

    pub fn set(self: *Buffer, x: u32, y: u32, value: u8) void {
        if (x >= self.width or y >= self.height) return;
        self.pixels[@as(usize, y) * self.width + x] = value;
    }

    pub fn copyRectFrom(self: *Buffer, source: *const Buffer, x: u16, y: u16, width: u16, height: u16) void {
        if (x >= self.width or y >= self.height) return;
        const copy_width = @min(width, self.width - x);
        const copy_height = @min(height, self.height - y);
        var row: u32 = 0;
        while (row < copy_height) : (row += 1) {
            var column: u32 = 0;
            while (column < copy_width) : (column += 1) {
                const target_x = @as(u32, x) + column;
                const target_y = @as(u32, y) + row;
                self.set(target_x, target_y, source.pixel(@intCast(target_x), @intCast(target_y)));
            }
        }
    }

    /// Apply the selected waveform to a rectangle copied from the image plane.
    pub fn refreshFrom(self: *Buffer, source: *const Buffer, x: u16, y: u16, width: u16, height: u16, mode: u16) void {
        if (x >= self.width or y >= self.height) return;
        const copy_width = @min(width, self.width - x);
        const copy_height = @min(height, self.height - y);
        var row: u32 = 0;
        while (row < copy_height) : (row += 1) {
            var column: u32 = 0;
            while (column < copy_width) : (column += 1) {
                const target_x = @as(u32, x) + column;
                const target_y = @as(u32, y) + row;
                const value = source.pixel(@intCast(target_x), @intCast(target_y));
                self.set(target_x, target_y, waveformPixel(value, mode));
            }
        }
    }
};

/// The host image plane and the refreshed glass plane, at the panel's
/// geometry. Both are allocated on the first pixel or refresh, so a run that
/// never draws pays nothing for a 1072x1448 panel.
pub const Planes = struct {
    geometry: proto.Geometry = .{},
    allocator: std.mem.Allocator = std.heap.page_allocator,
    image: Buffer = .{},
    glass: Buffer = .{},
    /// Pixels or refreshes dropped because the planes could not be allocated.
    unplaced: u32 = 0,

    /// Allocate both planes if they are not yet; false when that failed.
    pub fn ready(self: *Planes) bool {
        if (self.image.pixels.len != 0) return true;
        self.image = Buffer.alloc(self.allocator, self.geometry) catch return self.refuse();
        self.glass = Buffer.alloc(self.allocator, self.geometry) catch {
            self.image.free(self.allocator);
            return self.refuse();
        };
        return true;
    }

    fn refuse(self: *Planes) bool {
        self.unplaced +%= 1;
        return false;
    }

    /// Change the panel. Drawn planes are dropped and re-made at the new size.
    pub fn resize(self: *Planes, geometry: proto.Geometry) void {
        self.deinit();
        self.geometry = geometry;
    }

    pub fn deinit(self: *Planes) void {
        if (self.image.pixels.len != 0) self.image.free(self.allocator);
        if (self.glass.pixels.len != 0) self.glass.free(self.allocator);
    }
};

/// Bit offset of the nth packed pixel in one SPI data word.
pub fn pixelBitOffset(index: u32, bits_per_pixel: u5, big_endian: bool) u5 {
    const offset: u32 = index * bits_per_pixel;
    return @intCast(if (big_endian) 16 - bits_per_pixel - offset else offset);
}

/// Map the row-major input pixel into its panel location.
pub fn rotate(rotation: u16, column: u32, row: u32, width: u16, height: u16) struct { x: u32, y: u32 } {
    return switch (rotation & proto.wire.rotation_mask) {
        1 => .{ .x = @as(u32, height) - 1 - row, .y = column },
        2 => .{ .x = @as(u32, width) - 1 - column, .y = @as(u32, height) - 1 - row },
        3 => .{ .x = row, .y = @as(u32, width) - 1 - column },
        else => .{ .x = column, .y = row },
    };
}

/// A host observer called after a requested glass refresh has copied.
pub const RefreshHook = struct {
    context: *anyopaque,
    refreshFn: *const fn (*anyopaque) void,
};

fn waveformPixel(value: u8, mode: u16) u8 {
    if (mode == proto.waveform.init) return 0xFF;
    if (mode == proto.waveform.du or mode == proto.waveform.a2_m641 or mode == proto.waveform.a2_generic) {
        return if (value >= 128) 0xFF else 0;
    }
    if (mode == proto.waveform.gc16) {
        const level: u16 = (@as(u16, value) * 15 + 127) / 255;
        return @intCast(level * 17);
    }
    return value;
}

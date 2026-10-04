//! The IT8951's host image plane and refreshed glass plane.

const proto = @import("eink_wire.zig");

/// A grayscale plane at the panel's reported geometry.
pub const Buffer = struct {
    pixels: [@as(usize, proto.panel.width) * @as(usize, proto.panel.height)]u8 = .{0} ** (@as(usize, proto.panel.width) * @as(usize, proto.panel.height)),

    pub fn pixel(self: *const Buffer, x: u16, y: u16) u8 {
        if (x >= proto.panel.width or y >= proto.panel.height) return 0;
        return self.pixels[@as(usize, y) * proto.panel.width + x];
    }

    pub fn set(self: *Buffer, x: u32, y: u32, value: u8) void {
        if (x >= proto.panel.width or y >= proto.panel.height) return;
        self.pixels[@as(usize, y) * proto.panel.width + x] = value;
    }

    pub fn copyRectFrom(
        self: *Buffer,
        source: *const Buffer,
        x: u16,
        y: u16,
        width: u16,
        height: u16,
    ) void {
        if (x >= proto.panel.width or y >= proto.panel.height) return;
        const copy_width = @min(width, proto.panel.width - x);
        const copy_height = @min(height, proto.panel.height - y);
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

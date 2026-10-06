//! Reader for the versioned ra8_widget debug-tree channel (RA8EMU-562).
const std = @import("std");
const core_view = @import("core_view.zig");

pub const symbol = "ra8_widget_debug_tree";
pub const magic: u32 = 0x52385754;
pub const records_offset: u32 = 16;
pub const record_bytes: usize = 88;
/// Most records any supported version publishes (v2, RA8FW-782).
pub const record_limit: usize = 256;
pub const name_bytes: usize = 32;
pub const kind_bytes: usize = 16;
pub const state_bytes: usize = 24;

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

pub const Widget = struct {
    name: [name_bytes]u8,
    kind: [kind_bytes]u8,
    state: [state_bytes]u8,
    rect: Rect,

    pub fn nameSlice(self: *const Widget) []const u8 {
        return text(&self.name);
    }

    pub fn kindSlice(self: *const Widget) []const u8 {
        return text(&self.kind);
    }

    pub fn stateSlice(self: *const Widget) []const u8 {
        return text(&self.state);
    }
};

pub const Header = struct {
    version: u16,
    count: u16,
    generation: u32,
    truncated: bool,
};

/// Record capacity of a protocol version: v1 carries 64, v2 carries 256.
pub fn limitFor(version: u16) ?usize {
    return switch (version) {
        1 => 64,
        2 => record_limit,
        else => null,
    };
}

/// Check the 16-byte header and return what it publishes.
pub fn parseHeader(header: *const [records_offset]u8) error{ InvalidWidgetTree, UnsupportedWidgetTree }!Header {
    if (std.mem.readInt(u32, header[0..4], .little) != magic) return error.InvalidWidgetTree;
    const version = std.mem.readInt(u16, header[4..6], .little);
    const limit = limitFor(version) orelse return error.UnsupportedWidgetTree;
    const count = std.mem.readInt(u16, header[6..8], .little);
    if (count > limit) return error.InvalidWidgetTree;
    return .{
        .version = version,
        .count = count,
        .generation = std.mem.readInt(u32, header[8..12], .little),
        .truncated = header[12] != 0,
    };
}

/// Read one complete, published snapshot from guest memory.
pub fn read(view: core_view.View, address: u32, allocator: std.mem.Allocator) anyerror![]Widget {
    var header: [records_offset]u8 = undefined;
    try view.read(address, &header);
    const count = (try parseHeader(&header)).count;
    const widgets = try allocator.alloc(Widget, count);
    errdefer allocator.free(widgets);
    for (widgets, 0..) |*widget, index| {
        const record_address = address + records_offset + @as(u32, @intCast(index * record_bytes));
        var bytes: [record_bytes]u8 = undefined;
        try view.read(record_address, &bytes);
        @memcpy(&widget.name, bytes[0..name_bytes]);
        @memcpy(&widget.kind, bytes[name_bytes..][0..kind_bytes]);
        @memcpy(&widget.state, bytes[name_bytes + kind_bytes ..][0..state_bytes]);
        const rect_at = name_bytes + kind_bytes + state_bytes;
        widget.rect = .{
            .x = std.mem.readInt(i32, bytes[rect_at..][0..4], .little),
            .y = std.mem.readInt(i32, bytes[rect_at + 4 ..][0..4], .little),
            .w = std.mem.readInt(i32, bytes[rect_at + 8 ..][0..4], .little),
            .h = std.mem.readInt(i32, bytes[rect_at + 12 ..][0..4], .little),
        };
    }
    return widgets;
}

fn text(bytes: []const u8) []const u8 {
    return bytes[0 .. std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len];
}

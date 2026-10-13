//! The camera leaf's listing rows (RA8EMU-1123): under the live preview,
//! one row of the host's webcams and, while the image or video source is
//! active, one row of the project's files of that kind. Each entry is a
//! slot; the chosen one ringed; a click on a slot changes the source
//! through the leaf's picks. No entries of a kind, no row.
const std = @import("std");
const draw_list = @import("ra8_render").draw_list;
const font = @import("ra8_render").font;
const camera_view = @import("../ui/camera_view.zig");
const shell_frame = @import("../ui/shell/frame.zig");
const Theme = @import("../ui/colors.zig").Theme;
const Rect = draw_list.Rect;

pub const button = camera_view.button;
pub const gap = camera_view.gap;

/// One slot's rectangle inside a row whose top-left corner is `at`.
pub const Row = struct {
    x: i32,
    y: i32,

    pub fn slot(self: Row, index: usize) Rect {
        const at: i32 = @intCast(index);
        return .{ .x = self.x + gap + at * (button + gap), .y = self.y, .w = button, .h = button };
    }

    pub fn area(self: Row, count: usize) Rect {
        const n: i32 = @intCast(count);
        return .{ .x = self.x, .y = self.y, .w = n * (button + gap) + gap, .h = button };
    }
};

/// Where the two rows sit at the bottom of a leaf body, from its entries'
/// counts. Null when neither row shows.
pub const Stack = struct {
    x: i32,
    top: i32,
    device_count: usize,
    media_count: usize,

    pub fn height(self: Stack) i32 {
        var h: i32 = 0;
        if (self.device_count > 0) h += button + gap;
        if (self.media_count > 0) h += button + gap;
        return h;
    }

    /// The device row's corner, or null with no devices.
    pub fn device(self: Stack) ?Row {
        if (self.device_count == 0) return null;
        return .{ .x = self.x, .y = self.top };
    }

    /// The media row's corner: under the device row when that shows.
    pub fn media(self: Stack) ?Row {
        if (self.media_count == 0) return null;
        var y = self.top;
        if (self.device_count > 0) y += button + gap;
        return .{ .x = self.x, .y = y };
    }
};

pub fn stackFor(body: Rect, device_count: usize, media_count: usize) ?Stack {
    if (device_count == 0 and media_count == 0) return null;
    var stack = Stack{ .x = body.x + shell_frame.pad, .top = body.y, .device_count = device_count, .media_count = media_count };
    stack.top = body.y + body.h - shell_frame.pad - stack.height();
    return stack;
}

/// Appends the webcam device row, `chosen` ringed. No devices, no row.
pub fn drawDevices(theme: *const Theme, list: *draw_list.DrawList, row: Row, devices: []const u32, chosen: ?u32) !void {
    if (devices.len == 0) return;
    try list.fill(row.area(devices.len), theme.well);
    for (devices, 0..) |device, index| {
        const at = row.slot(index);
        if (chosen != null and chosen.? == device) {
            try list.fill(.{ .x = at.x - 2, .y = at.y - 2, .w = at.w + 4, .h = at.h + 4 }, theme.ink);
        }
        try list.fill(at, theme.muted);
        var text: [12]u8 = undefined;
        const label = std.fmt.bufPrint(&text, "v{d}", .{device}) catch "v?";
        try font.centred(list, at, label, camera_view.inkOn(theme, theme.muted));
    }
}

/// Appends the media row for `names` in `color`, `chosen` ringed. No names,
/// no row.
pub fn drawMedia(theme: *const Theme, list: *draw_list.DrawList, row: Row, names: []const []const u8, chosen: []const u8, color: draw_list.Color) !void {
    if (names.len == 0) return;
    try list.fill(row.area(names.len), theme.well);
    for (names, 0..) |name, index| {
        const at = row.slot(index);
        if (std.mem.eql(u8, name, chosen)) {
            try list.fill(.{ .x = at.x - 2, .y = at.y - 2, .w = at.w + 4, .h = at.h + 4 }, theme.ink);
        }
        try list.fill(at, color);
        try font.centred(list, at, std.fs.path.stem(name), camera_view.inkOn(theme, color));
    }
}

/// The device under (`x`, `y`), or null when the click missed every slot.
pub fn hitDevices(row: Row, devices: []const u32, x: i32, y: i32) ?u32 {
    for (devices, 0..) |device, index| {
        if (row.slot(index).contains(x, y)) return device;
    }
    return null;
}

/// The name under (`x`, `y`), or null when the click missed every slot.
pub fn hitMedia(row: Row, names: []const []const u8, x: i32, y: i32) ?[]const u8 {
    for (names, 0..) |name, index| {
        if (row.slot(index).contains(x, y)) return name;
    }
    return null;
}

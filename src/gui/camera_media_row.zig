//! The picture and clip row under the camera panel (RA8EMU-500): while the
//! image or video source is active, one slot per file camera_media found
//! for it, the chosen one ringed. A click on a slot names that file; the
//! pane makes it the source's argument. It sits under the webcam device
//! row when that row shows, else straight under the panel. Until the font
//! atlas lands the slots carry no labels, so their order is name order.
const std = @import("std");
const draw_list = @import("draw_list.zig");
const camera_view = @import("camera_view.zig");
const device_row = @import("camera_device_row.zig");
const Row = device_row.Row;

/// Where the row goes for a pane whose device row has `device_count` slots.
pub fn rowFor(layout: camera_view.Layout, device_count: usize) Row {
    var row = Row.under(layout);
    if (device_count > 0) row.y += camera_view.button + camera_view.gap;
    return row;
}

/// Appends the row for `names` in `color`, the one equal to `chosen`
/// ringed. No names, no row.
pub fn draw(
    list: *draw_list.DrawList,
    row: Row,
    names: []const []const u8,
    chosen: []const u8,
    color: draw_list.Color,
) !void {
    if (names.len == 0) return;
    try list.fill(row.area(names.len), camera_view.background);
    for (names, 0..) |name, index| {
        const at = row.slot(index);
        if (std.mem.eql(u8, name, chosen)) {
            try list.fill(.{ .x = at.x - 2, .y = at.y - 2, .w = at.w + 4, .h = at.h + 4 }, camera_view.ring);
        }
        try list.fill(at, color);
    }
}

/// The name under (`x`, `y`), or null when the click missed every slot.
pub fn hit(row: Row, names: []const []const u8, x: i32, y: i32) ?[]const u8 {
    for (names, 0..) |name, index| {
        if (row.slot(index).contains(x, y)) return name;
    }
    return null;
}

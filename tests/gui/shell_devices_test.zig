//! Host tests for the shell's device list (RA8EMU-792): only the response to
//! its own ask is kept, a refused or garbled reply becomes a note, lines split
//! into name and endpoint, and the devices leaf draws rows in place of its note.
const std = @import("std");
const ra8 = @import("ra8");
const proto = ra8.interfaces.rpc.session;
const draw_list = ra8.gui.draw_list;
const raster = ra8.gui.raster;
const font = ra8.gui.font;
const pane_layout = ra8.gui.pane_layout;
const frame = ra8.gui.shell_frame;
const panes = ra8.gui.shell_panes;
const status_bar = ra8.gui.status_bar;
const shell_devices = ra8.gui.shell_devices;
const Devices = shell_devices.Devices;

fn answer(devices: *Devices, id: u32, text: []const u8) !void {
    var bytes: [4200]u8 = undefined;
    const payload = try proto.encode(proto.PartList, .{ .text = text }, &bytes);
    devices.observe(.{ .response = .{ .id = id, .result = .{ .ok = payload } } });
}

test "only the response to its own ask is kept" {
    var devices: Devices = .{ .asked = 7 };
    try std.testing.expectEqual(@as(?[]const u8, null), devices.note());
    devices.observe(.{ .event = .{ .topic = @intFromEnum(proto.Topic.uart), .payload = "x" } });
    try answer(&devices, 6, "led@gpio:P106\n");
    try std.testing.expect(!devices.answered);
    try answer(&devices, 7, "lsm6dso@i2c:touch@0x6b\nmax17048@i2c:touch@0x36\n");
    try std.testing.expect(devices.answered);
    try answer(&devices, 7, "led@gpio:P106\n");
    var rows = devices.lines();
    try std.testing.expectEqualStrings("lsm6dso@i2c:touch@0x6b", rows.next().?);
    try std.testing.expectEqualStrings("max17048@i2c:touch@0x36", rows.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), rows.next());
    try std.testing.expectEqual(@as(?[]const u8, null), devices.note());
}

test "a refused, garbled or empty reply leaves a note" {
    var refused: Devices = .{ .asked = 1 };
    refused.observe(.{ .response = .{ .id = 1, .result = .{ .err = @enumFromInt(0x0003) } } });
    try std.testing.expectEqualStrings("the session would not list its parts", refused.note().?);
    var garbled: Devices = .{ .asked = 1 };
    garbled.observe(.{ .response = .{ .id = 1, .result = .{ .ok = "" } } });
    try std.testing.expect(garbled.refused);
    var empty: Devices = .{ .asked = 1 };
    try answer(&empty, 1, "");
    try std.testing.expectEqualStrings("no parts fitted", empty.note().?);
}

test "a line splits at its first @ into name and endpoint" {
    const part = shell_devices.split("lsm6dso@i2c:touch@0x6b");
    try std.testing.expectEqualStrings("lsm6dso", part.name);
    try std.testing.expectEqualStrings("i2c:touch@0x6b", part.at);
    const bare = shell_devices.split("gpio:P106");
    try std.testing.expectEqualStrings("", bare.name);
    try std.testing.expectEqualStrings("gpio:P106", bare.at);
}

fn holds(pixels: *const raster.Framebuffer, area: draw_list.Rect, color: draw_list.Color) bool {
    var y = area.y;
    while (y < area.y + area.h) : (y += 1) {
        var x = area.x;
        while (x < area.x + area.w) : (x += 1) {
            if (std.meta.eql(pixels.at(@intCast(x), @intCast(y)), color)) return true;
        }
    }
    return false;
}

fn drawShell(gpa: std.mem.Allocator, devices: *const Devices, pixels: *raster.Framebuffer, layout: *pane_layout.Layout, solved: anytype) !void {
    var list = draw_list.DrawList.init(gpa, 480, 320);
    defer list.deinit();
    const status: status_bar.Status = .{};
    var painter: panes.Panes = .{ .devices = devices };
    try frame.draw(&list, .{ .layout = layout, .solved = solved, .status = &status, .state = .closed, .width = 480, .height = 320, .painter = painter.painter() });
    raster.draw(pixels, &list, font.atlas);
}

test "the devices leaf draws a row per part in place of its note" {
    const gpa = std.testing.allocator;
    var devices: Devices = .{ .asked = 1 };
    try answer(&devices, 1, "lsm6dso@i2c:touch@0x6b\n");
    var layout = try pane_layout.twoCore(gpa);
    defer layout.deinit();
    var solved = try frame.solve(&layout, gpa, 480, 320);
    defer solved.deinit(gpa);
    var pixels = try raster.Framebuffer.init(gpa, 480, 320);
    defer pixels.deinit(gpa);
    try drawShell(gpa, &devices, &pixels, &layout, &solved);
    var leaves: usize = 0;
    for (solved.panes.items) |leaf| {
        const placed = layout.pane(leaf.index) orelse continue;
        if (placed.kind != .devices) continue;
        leaves += 1;
        const body = frame.bodyOf(leaf.area);
        const row: draw_list.Rect = .{ .x = body.x, .y = body.y + frame.pad, .w = body.w, .h = font.glyph_h };
        const column: i32 = @intCast(font.textWidth(shell_devices.name_cells));
        const name: draw_list.Rect = .{ .x = row.x, .y = row.y, .w = frame.pad + column, .h = row.h };
        const at: draw_list.Rect = .{ .x = row.x + frame.pad + column, .y = row.y, .w = body.w - frame.pad - column, .h = row.h };
        try std.testing.expect(holds(&pixels, name, frame.ink));
        try std.testing.expect(holds(&pixels, at, frame.muted));
        const below: draw_list.Rect = .{ .x = body.x, .y = row.y + shell_devices.row_h, .w = body.w, .h = body.h - frame.pad - shell_devices.row_h };
        try std.testing.expect(!holds(&pixels, below, frame.muted));
    }
    try std.testing.expect(leaves > 0);
}

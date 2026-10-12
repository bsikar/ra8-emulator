//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! S9 Settings: four groups of two rows, each leading somewhere.

const tree = @import("../tree.zig");
const theme = @import("../theme.zig");
const screen = @import("../screen.zig");
const bars = @import("../chrome/bars.zig");
const header = @import("../chrome/header.zig");
const page = @import("../chrome/page.zig");

const Builder = tree.Builder;
const Parts = tree.Parts;
const Error = tree.Error;

const group_names = [_][:0]const u8{ "CONNECTION", "DISPLAY AND SOUND", "SECURITY", "DEVICE" };
const list_names = [_][:0]const u8{ "settings.connection", "settings.display", "settings.security", "settings.device" };
const rows_per_group = 2;

pub fn build(b: *Builder, ctx: screen.Ctx) Error!tree.Widget {
    const settings = ctx.svc.settings;
    const preset = @import("../data/player.zig").preset_names[ctx.svc.player.preset()];
    const rows = [group_names.len][rows_per_group]tree.Row{
        .{
            .{ .title = "Wi-Fi", .subtitle = settings.info(.wifi), .chevron = true },
            .{ .title = "Audio output", .subtitle = settings.info(.audio_output), .chevron = true },
        },
        .{
            .{ .title = "Page refresh", .subtitle = settings.info(.page_refresh), .chevron = true },
            .{ .title = "Equalizer", .subtitle = preset, .chevron = true },
        },
        .{
            .{ .title = "Passcode and encryption", .subtitle = if (settings.flag(.passcode_lock)) "On" else "Off", .chevron = true },
            .{ .title = "Date and time", .subtitle = if (settings.flag(.time_from_wifi)) "Set from Wi-Fi" else "Set by hand", .chevron = true },
        },
        .{
            .{ .title = "Storage", .subtitle = settings.info(.storage), .chevron = true },
            .{ .title = "Software", .subtitle = settings.info(.software), .chevron = true },
        },
    };

    var root: Parts = .{};
    try bars.system(b, ctx, &root, "Home");
    var body: Parts = .{};
    try header.add(b, &body, "Settings", .{});
    for (group_names, list_names, rows, 0..) |group, name, group_rows, index| {
        try body.add(try page.section(b, group));
        const base: u8 = @intCast(index * rows_per_group);
        try body.add(try b.named(name, try b.list(&group_rows, theme.metric.row, .open_setting, base)));
    }
    try body.add(try page.filler(b));
    try root.add(try page.body(b, body.slice()));
    try bars.shell(b, ctx, &root, 4);
    return b.col(0, root.slice());
}

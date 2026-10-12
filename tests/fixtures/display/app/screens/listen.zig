//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! S5 Listen: what there is to browse, and what was played recently.

const tree = @import("../tree.zig");
const theme = @import("../theme.zig");
const screen = @import("../screen.zig");
const bars = @import("../chrome/bars.zig");
const header = @import("../chrome/header.zig");
const page = @import("../chrome/page.zig");

const Builder = tree.Builder;
const Parts = tree.Parts;
const Error = tree.Error;

pub const tabs = [_][:0]const u8{ "Music", "Audiobooks" };

const row_cap = 8;

pub fn build(b: *Builder, ctx: screen.Ctx) Error!tree.Widget {
    var browse: [row_cap]tree.Row = undefined;
    const shelves = ctx.svc.player.shelves();
    const shelf_count = @min(shelves.len, row_cap);
    for (shelves[0..shelf_count], browse[0..shelf_count]) |shelf, *row| row.* = .{ .title = shelf.label, .value = shelf.count };

    var played: [row_cap]tree.Row = undefined;
    const recent = ctx.svc.player.played();
    const played_count = @min(recent.len, row_cap);
    for (recent[0..played_count], played[0..played_count]) |item, *row| row.* = .{ .title = item.title, .subtitle = item.meta };

    var root: Parts = .{};
    try bars.system(b, ctx, &root, "Home");
    var body: Parts = .{};
    const equalizer = try b.named("listen.equalizer", try b.button("Equalizer", .open_equalizer, .{}));
    try header.add(b, &body, "Listen", .{ .aside = equalizer, .aside_width = 200 });
    try body.add(tree.sized(try b.named("listen.tab", try b.segmented(&tabs, ctx.state.listen_tab, .listen_tab)), 88));
    try body.add(try b.named("listen.browse", try b.list(browse[0..shelf_count], theme.metric.row, .open_listen_row, 0)));
    try body.add(try page.section(b, "RECENTLY PLAYED"));
    try body.add(try b.named("listen.played", try b.list(played[0..played_count], theme.metric.tall_row, .open_listen_row, @intCast(shelf_count))));
    try body.add(try page.filler(b));
    try root.add(try page.body(b, body.slice()));
    try bars.shell(b, ctx, &root, 2);
    return b.col(0, root.slice());
}

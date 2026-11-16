//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! M8 MDL settings: sources, the adult-content switch, and storage.

const tree = @import("../tree.zig");
const theme = @import("../theme.zig");
const screen = @import("../screen.zig");
const bars = @import("../chrome/bars.zig");
const header = @import("../chrome/header.zig");
const page = @import("../chrome/page.zig");
const mdl_page = @import("../chrome/mdl_page.zig");
const passcode = @import("passcode.zig");

const Builder = tree.Builder;
const Parts = tree.Parts;
const Error = tree.Error;

const cache = struct {
    pub const used_mb: u16 = 212;
    pub const limit_mb: u16 = 512;
};

pub fn build(b: *Builder, ctx: screen.Ctx) Error!tree.Widget {
    const count = ctx.svc.mdl.sourceCount();
    const sources = [_]tree.Row{.{
        .title = try b.fmt("{d} of {d} turned on", .{ count.on, count.total }),
        .subtitle = "1 has not responded today",
        .chevron = true,
    }};
    const storage = [_]tree.Row{
        .{ .title = "Downloaded chapters", .value = "1.9 GB" },
        .{ .title = "Streaming cache", .value = "212 of 512 MB" },
    };

    var root: Parts = .{};
    try bars.system(b, ctx, &root, mdl_page.where);
    var body: Parts = .{};
    try header.add(b, &body, "MDL settings", .{});
    try body.add(try page.section(b, "SOURCES"));
    try body.add(try b.named("mdl_settings.sources", try b.list(&sources, theme.metric.tall_row, .open_source_list, 0)));
    try body.add(try page.section(b, "CONTENT"));
    try body.add(tree.sized(try b.named("mdl_settings.adult", try b.toggle("Show adult sources", ctx.svc.settings.flag(.mdl_adult), .mdl_adult, 0)), passcode.toggle_height));
    try body.add(try page.note(b, "Adult results appear only in Search, never in Explore"));
    try body.add(try page.section(b, "STORAGE"));
    try body.add(try b.list(&storage, theme.metric.row, .inert, 0));
    try body.add(tree.sized(try b.progress(cache.used_mb, cache.limit_mb), 12));
    try body.add(tree.sized(try b.row(0, &.{ tree.sized(try b.button("Clear streaming cache", .inert, .{}), 360), try page.filler(b) }), theme.metric.control));
    try body.add(try page.filler(b));
    try root.add(try page.body(b, body.slice()));
    try bars.mdl(b, &root, 4);
    return b.col(0, root.slice());
}

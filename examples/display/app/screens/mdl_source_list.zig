//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! M9 Manage sources: every source with its own on/off switch.

const tree = @import("../tree.zig");
const theme = @import("../theme.zig");
const screen = @import("../screen.zig");
const bars = @import("../chrome/bars.zig");
const header = @import("../chrome/header.zig");
const page = @import("../chrome/page.zig");
const mdl_page = @import("../chrome/mdl_page.zig");

const Builder = tree.Builder;
const Parts = tree.Parts;
const Error = tree.Error;

const per_page: u16 = 8;
const toggle_height: i16 = 80;

pub fn build(b: *Builder, ctx: screen.Ctx) Error!tree.Widget {
    const mdl = ctx.svc.mdl;
    var root: Parts = .{};
    try bars.system(b, ctx, &root, mdl_page.where);
    var body: Parts = .{};
    const count = mdl.sourceCount();
    const summary = try b.fmt("{d} of {d} on", .{ count.on, count.total });
    try header.add(b, &body, "Sources", .{ .back = true, .aside = try header.note(b, summary), .aside_width = 200 });
    for (mdl.sources()[0..@min(mdl.sources().len, per_page)], 0..) |item, index| {
        const text = try b.clip(try b.fmt("{s} - {s}", .{ item.label, item.info }), theme.text.body, page.inner_width - 100);
        const name = try b.fmt("sources.toggle.{d}", .{index});
        try body.add(tree.sized(try b.named(name, try b.toggle(text, mdl.sourceEnabled(index), .source_enabled, @intCast(index))), toggle_height));
    }
    try body.add(try page.filler(b));
    try root.add(try page.body(b, body.slice()));
    try bars.pager(b, &root, count.total, per_page, ctx.state.source_page, .source_page);
    try bars.mdl(b, &root, 4);
    return b.col(0, root.slice());
}

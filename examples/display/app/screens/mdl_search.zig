//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! M2 Search: a query, how many sources answered, and the works found.

const tree = @import("../tree.zig");
const theme = @import("../theme.zig");
const screen = @import("../screen.zig");
const bars = @import("../chrome/bars.zig");
const page = @import("../chrome/page.zig");
const mdl_page = @import("../chrome/mdl_page.zig");

const Builder = tree.Builder;
const Parts = tree.Parts;
const Error = tree.Error;

const hit_height: i16 = 130;
const per_page: u16 = 6;
const row_cap = 8;

pub fn build(b: *Builder, ctx: screen.Ctx) Error!tree.Widget {
    const hits = ctx.svc.mdl.hits();
    var rows: [row_cap]tree.Row = undefined;
    const count = @min(hits.len, row_cap);
    for (hits[0..count], rows[0..count]) |hit, *row| {
        const detail = try b.fmt("{s} - {s}", .{ hit.by, hit.availability });
        row.* = .{ .title = hit.title, .subtitle = try b.clip(detail, theme.text.body, page.inner_width - 200), .chevron = true };
    }

    var root: Parts = .{};
    try bars.system(b, ctx, &root, mdl_page.where);
    var body: Parts = .{};
    const field = try b.named("search.field", try b.toolbar("ferry", try b.fmt("{d} works", .{count})));
    const go = try b.named("search.go", try b.button("Go", .search_go, .solid));
    try body.add(tree.sized(try b.row(16, &.{ tree.grow(field), tree.sized(go, 148) }), theme.metric.control));
    try body.add(tree.sized(try b.fill(theme.color.ink), theme.metric.rule));
    try body.add(tree.sized(try b.row(16, &.{
        tree.grow(try b.label("4 of 5 sources answered", theme.text.note.with(.right))),
        tree.sized(try b.button("Retry 1 source", .inert, .{}), 260),
    }), theme.metric.control));
    try body.add(try b.named("search.hits", try b.list(rows[0..count], hit_height, .open_work, 0)));
    try body.add(try page.filler(b));
    try root.add(try page.body(b, body.slice()));
    try bars.pager(b, &root, @intCast(count), per_page, ctx.state.search_page, .search_page);
    try bars.mdl(b, &root, 3);
    return b.col(0, root.slice());
}

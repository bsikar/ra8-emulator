//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! M4 Chapter sources: every source that has one chapter, and what to do
//! with each copy.

const tree = @import("../tree.zig");
const theme = @import("../theme.zig");
const screen = @import("../screen.zig");
const mdl = @import("../data/mdl.zig");
const bars = @import("../chrome/bars.zig");
const header = @import("../chrome/header.zig");
const page = @import("../chrome/page.zig");
const mdl_page = @import("../chrome/mdl_page.zig");

const Builder = tree.Builder;
const Parts = tree.Parts;
const Error = tree.Error;

const per_page: u16 = 6;
const shown_cap = 2;

fn source(b: *Builder, body: *Parts, item: mdl.ChapterSource, index: u8) Error!void {
    try body.add(try page.hair(b));
    try body.add(tree.sized(try b.label(item.label, theme.text.heading), theme.metric.heading_line));
    try body.add(try page.note(b, try b.clip(item.info, theme.text.note, page.inner_width)));
    try body.add(tree.sized(try b.label(item.local, theme.text.strong), page.line_height));
    const primary = try b.named(try b.fmt("sources.read.{d}", .{index}), try b.button(item.primary, .read_source, .{ .fg = theme.color.paper, .face = theme.color.ink, .index = index }));
    try body.add(tree.sized(try b.row(16, &.{
        tree.sized(primary, 220),
        tree.sized(try b.button(item.secondary, .inert, .{}), 280),
        try page.filler(b),
    }), theme.metric.control));
}

pub fn build(b: *Builder, ctx: screen.Ctx) Error!tree.Widget {
    const sources = ctx.svc.mdl.chapterSources();
    const count = @min(sources.len, shown_cap);

    var root: Parts = .{};
    try bars.system(b, ctx, &root, mdl_page.where);
    var body: Parts = .{};
    try header.add(b, &body, "Chapter 212", .{ .back = true, .aside = try header.note(b, ctx.svc.mdl.work().title), .aside_width = 260 });
    try body.add(tree.sized(try b.label(try b.fmt("{d} sources have this chapter", .{count}), theme.text.strong), page.line_height));
    for (sources[0..count], 0..) |item, index| try source(b, &body, item, @intCast(index));
    try body.add(try page.hair(b));
    try body.add(try page.note(b, "The copy on this device is kept until a new download passes its checks."));
    try body.add(try page.filler(b));
    try root.add(try page.body(b, body.slice()));
    try bars.pager(b, &root, @intCast(count), per_page, ctx.state.sources_page, .sources_page);
    try bars.mdl(b, &root, 3);
    return b.col(0, root.slice());
}

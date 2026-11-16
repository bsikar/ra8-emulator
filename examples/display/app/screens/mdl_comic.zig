//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! M5 Comic page: one whole page, edge to edge. As in the book reader the
//! left turns back, the right turns forward and the middle leaves; the
//! strip along the bottom labels those three zones.

const tree = @import("../tree.zig");
const theme = @import("../theme.zig");
const screen = @import("../screen.zig");
const route = @import("../route.zig");

const Builder = tree.Builder;
const Error = tree.Error;

const page_width: i16 = 1013;
const strip_height: i16 = 64;

pub fn build(b: *Builder, ctx: screen.Ctx) Error!tree.Widget {
    const work = ctx.svc.mdl.work();
    const caption = try b.fmt("page {d} of {d}", .{ work.page, work.pages });
    const side: i16 = @divTrunc(@as(i16, @intCast(theme.panel.width)) - page_width, 2);
    const sheet = try b.row(0, &.{
        try b.space(side),
        tree.grow(try b.label(caption, theme.text.placeholder)),
        try b.space(side),
    });
    const zones = try b.row(0, &.{
        tree.sized(try b.label("Previous", theme.text.note.with(.center)), @intCast(route.zones.menu_from)),
        tree.sized(try b.fill(theme.color.ink), theme.metric.rule),
        tree.sized(try b.label("Menu", theme.text.note.with(.center)), @intCast(route.zones.next_from - route.zones.menu_from - theme.metric.rule)),
        tree.sized(try b.fill(theme.color.ink), theme.metric.rule),
        tree.grow(try b.label("Next", theme.text.note.with(.center))),
    });
    return b.named("comic.page", try b.col(0, &.{ tree.grow(sheet), tree.sized(zones, strip_height) }));
}

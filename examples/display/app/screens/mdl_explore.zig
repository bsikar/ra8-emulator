//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! M1 Explore: the newest or most popular works across the sources.

const tree = @import("../tree.zig");
const screen = @import("../screen.zig");
const bars = @import("../chrome/bars.zig");
const header = @import("../chrome/header.zig");
const cards = @import("../chrome/cards.zig");
const page = @import("../chrome/page.zig");
const mdl_page = @import("../chrome/mdl_page.zig");

const Builder = tree.Builder;
const Parts = tree.Parts;
const Error = tree.Error;

pub const tabs = [_][:0]const u8{ "Latest", "Popular" };
const catalogue: u16 = 48;

pub fn build(b: *Builder, ctx: screen.Ctx) Error!tree.Widget {
    const popular = ctx.state.explore_tab == 1;
    var buffer: [mdl_page.works_cap]cards.Card = undefined;
    const works = mdl_page.cardsFor(ctx.svc.mdl.latest(popular), &buffer);

    var root: Parts = .{};
    try bars.system(b, ctx, &root, mdl_page.where);
    var body: Parts = .{};
    const summary: [:0]const u8 = if (popular) "Popular on 3 sources" else "Latest from 3 sources";
    try header.add(b, &body, "Explore", .{ .aside = try header.note(b, summary), .aside_width = 320 });
    try body.add(tree.sized(try b.named("explore.tab", try b.segmented(&tabs, ctx.state.explore_tab, .explore_tab)), 88));
    try cards.add(b, &body, works, .{}, .open_work, "explore.work");
    try body.add(try page.filler(b));
    try root.add(try page.body(b, body.slice()));
    try bars.pager(b, &root, catalogue, cards.per_page, ctx.state.explore_page, .explore_page);
    try bars.mdl(b, &root, 0);
    return b.col(0, root.slice());
}

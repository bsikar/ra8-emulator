//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! M3 Work: one work, where to resume it, and its chapters newest first.

const tree = @import("../tree.zig");
const theme = @import("../theme.zig");
const screen = @import("../screen.zig");
const bars = @import("../chrome/bars.zig");
const header = @import("../chrome/header.zig");
const page = @import("../chrome/page.zig");
const mdl_page = @import("../chrome/mdl_page.zig");

const Builder = tree.Builder;
const Parts = tree.Parts;
const Widget = tree.Widget;
const Error = tree.Error;

const cover = struct {
    pub const width: i16 = 144;
    pub const height: i16 = 202;
};
const chapter_height: i16 = 100;
const per_page: u16 = 6;
const row_cap = 8;

fn summary(b: *Builder, ctx: screen.Ctx) Error!Widget {
    const work = ctx.svc.mdl.work();
    const resume_button = try b.named("work.continue", try b.button(work.resume_label, .continue_chapter, .solid));
    const actions = try b.row(16, &.{
        tree.sized(resume_button, 300),
        tree.sized(try b.button("Remove from Library", .inert, .{}), 340),
        try page.filler(b),
    });
    const text = try b.col(8, &.{
        try page.line(b, work.author),
        try page.note(b, work.counts),
        try page.filler(b),
        tree.sized(actions, theme.metric.control),
    });
    const band = try b.row(32, &.{ tree.sized(try b.label("cover", theme.text.placeholder), cover.width), tree.grow(text) });
    return tree.sized(band, cover.height);
}

pub fn build(b: *Builder, ctx: screen.Ctx) Error!Widget {
    const work = ctx.svc.mdl.work();
    const chapters = ctx.svc.mdl.chapters();
    var rows: [row_cap]tree.Row = undefined;
    const count = @min(chapters.len, row_cap);
    for (chapters[0..count], rows[0..count]) |chapter, *row| row.* = .{ .title = chapter.label, .subtitle = chapter.status, .chevron = true };

    var root: Parts = .{};
    try bars.system(b, ctx, &root, mdl_page.where);
    var body: Parts = .{};
    try header.add(b, &body, work.title, .{ .back = true });
    try body.add(try summary(b, ctx));
    try body.add(tree.sized(try b.fill(theme.color.ink), theme.metric.rule));
    try body.add(try page.section(b, "CHAPTERS - NEWEST FIRST"));
    try body.add(try b.named("work.chapters", try b.list(rows[0..count], chapter_height, .open_chapter, 0)));
    try body.add(try page.filler(b));
    try root.add(try page.body(b, body.slice()));
    try bars.pager(b, &root, work.chapter_count, per_page, ctx.state.work_page, .work_page);
    try bars.mdl(b, &root, 3);
    return b.col(0, root.slice());
}

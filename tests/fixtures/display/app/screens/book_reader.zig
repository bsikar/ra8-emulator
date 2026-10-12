//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! R1 Book page: one page of the book and nothing else. The left of the
//! page turns back, the right turns forward and the middle opens the menu;
//! those zones belong to the router, not to a widget.

const tree = @import("../tree.zig");
const theme = @import("../theme.zig");
const screen = @import("../screen.zig");
const prose = @import("../chrome/prose.zig");
const page = @import("../chrome/page.zig");
const typography = @import("../chrome/typography.zig");

const Builder = tree.Builder;
const Parts = tree.Parts;
const Widget = tree.Widget;
const Error = tree.Error;

const paragraph_gap: i16 = 24;
const footer_height: i16 = 26;
const clock_width: i16 = 120;

fn footer(b: *Builder, ctx: screen.Ctx) Error!Widget {
    const reading = ctx.svc.library.reading();
    const where = try b.fmt("Page {d} of {d} - {d} pages left in chapter", .{ reading.page, reading.pages, reading.chapter_pages_left });
    var parts: Parts = .{};
    try parts.add(tree.grow(try b.label(where, theme.text.note)));
    if (ctx.svc.settings.flag(.time_in_reader)) {
        try parts.add(tree.sized(try b.label(ctx.svc.clock.now().time, theme.text.note.with(.right)), clock_width));
    }
    return tree.sized(try b.row(0, parts.slice()), footer_height);
}

pub fn build(b: *Builder, ctx: screen.Ctx) Error!Widget {
    const reading = ctx.svc.library.reading();
    const text = ctx.svc.library.page(reading.page);
    const style = typography.current(ctx.svc.settings);
    const width = theme.panel.width - 2 * @as(i32, style.margin);
    var room: i32 = theme.panel.height - 2 * @as(i32, style.margin) - footer_height - paragraph_gap;

    var body: Parts = .{};
    if (text.opens_chapter) {
        try body.add(try page.section(b, reading.chapter));
        try body.add(tree.sized(try b.label(reading.chapter_title, style.heading), style.heading_line));
        room -= page.section_height + style.heading_line + 2 * paragraph_gap;
    }
    for (text.paragraphs) |paragraph| {
        const lines: usize = @intCast(@max(0, @divTrunc(room, style.leading)));
        if (lines == 0) break;
        const block = try prose.paragraph(b, paragraph, style.body, width, style.leading, lines);
        try body.add(block.widget);
        room -= block.height + paragraph_gap;
    }
    try body.add(try page.filler(b));
    try body.add(try footer(b, ctx));
    return b.named("reader.page", try b.padded(paragraph_gap, style.margin, body.slice()));
}

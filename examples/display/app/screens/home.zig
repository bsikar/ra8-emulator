//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! S3 Home: the book in progress, what was opened recently, pinned apps.

const tree = @import("../tree.zig");
const theme = @import("../theme.zig");
const screen = @import("../screen.zig");
const bars = @import("../chrome/bars.zig");
const header = @import("../chrome/header.zig");
const cards = @import("../chrome/cards.zig");
const page = @import("../chrome/page.zig");

const Builder = tree.Builder;
const Parts = tree.Parts;
const Widget = tree.Widget;
const Error = tree.Error;

const cover = struct {
    pub const width: i16 = 216;
    pub const height: i16 = 302;
};
const recent_shape: cards.Shape = .{ .cover_height = 200 };
const pinned_height: i16 = 104;
const resume_width: i16 = 240;

fn continueReading(b: *Builder, ctx: screen.Ctx) Error!Widget {
    const reading = ctx.svc.library.reading();
    const detail = try b.fmt("{s} - Chapter 4 - page {d} of {d}", .{ reading.author, reading.page, reading.pages });
    const resume_button = try b.named("home.resume", try b.button("Resume", .resume_book, .solid));
    const text = try b.col(8, &.{
        try page.filler(b),
        tree.sized(try b.label(reading.title, theme.text.heading), theme.metric.heading_line),
        try page.note(b, detail),
        tree.sized(try b.progress(reading.percent, 100), 12),
        tree.sized(try b.row(0, &.{ tree.sized(resume_button, resume_width), try page.filler(b) }), theme.metric.control),
    });
    const band = try b.row(32, &.{
        tree.sized(try b.label("cover", theme.text.placeholder), cover.width),
        tree.grow(text),
    });
    return tree.sized(band, cover.height);
}

fn recent(b: *Builder, ctx: screen.Ctx, body: *Parts) Error!void {
    const entries = ctx.svc.library.recent();
    var items: [cards.columns]cards.Card = undefined;
    const count = @min(entries.len, items.len);
    for (entries[0..count], items[0..count], 0..) |entry, *item, i| {
        item.* = .{ .title = entry.title, .meta = entry.meta, .index = @intCast(i) };
    }
    try cards.add(b, body, items[0..count], recent_shape, .open_recent, "home.recent");
}

fn pinned(b: *Builder) Error!Widget {
    const mdl = try b.named("home.mdl", try b.button("MDL", .open_app, .{ .index = 0 }));
    const second = try b.button("[APP NAME]", .open_app, .{ .index = 1 });
    const third = try b.button("[APP NAME]", .open_app, .{ .index = 2 });
    const all = try b.named("home.all_apps", try b.button("All apps", .all_apps, .plain));
    const band = try b.row(32, &.{ tree.grow(mdl), tree.grow(second), tree.grow(third), tree.grow(all) });
    return tree.sized(band, pinned_height);
}

pub fn build(b: *Builder, ctx: screen.Ctx) Error!Widget {
    var root: Parts = .{};
    try bars.system(b, ctx, &root, ctx.svc.clock.now().short_date);
    var body: Parts = .{};
    try header.add(b, &body, "Home", .{});
    try body.add(try page.section(b, "CONTINUE READING"));
    try body.add(try continueReading(b, ctx));
    try body.add(try page.section(b, "RECENT"));
    try recent(b, ctx, &body);
    try body.add(try page.section(b, "PINNED APPS"));
    try body.add(try pinned(b));
    try body.add(try page.filler(b));
    try root.add(try page.body(b, body.slice()));
    try bars.shell(b, ctx, &root, 0);
    return b.col(0, root.slice());
}

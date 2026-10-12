//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! S4 Library: everything on the shelf, filtered and paged eight at a time.

const tree = @import("../tree.zig");
const screen = @import("../screen.zig");
const library = @import("../data/library.zig");
const bars = @import("../chrome/bars.zig");
const header = @import("../chrome/header.zig");
const cards = @import("../chrome/cards.zig");
const page = @import("../chrome/page.zig");

const Builder = tree.Builder;
const Parts = tree.Parts;
const Error = tree.Error;

pub const filters = [_][:0]const u8{ "All", "Books", "Comics", "On device" };

const shelf_cap = 64;

fn passes(entry: library.Entry, filter: u8) bool {
    return switch (filter) {
        1 => entry.kind == .book,
        2 => entry.kind == .comic,
        3 => entry.on_device,
        else => true,
    };
}

pub fn build(b: *Builder, ctx: screen.Ctx) Error!tree.Widget {
    var shown: [shelf_cap]cards.Card = undefined;
    var count: usize = 0;
    for (ctx.svc.library.shelf(), 0..) |entry, i| {
        if (count == shelf_cap or !passes(entry, ctx.state.library_filter)) continue;
        shown[count] = .{ .title = entry.title, .meta = entry.meta, .index = @intCast(i) };
        count += 1;
    }
    const first = @min(@as(usize, ctx.state.library_page) * cards.per_page, count);
    const last = @min(first + cards.per_page, count);

    var root: Parts = .{};
    try bars.system(b, ctx, &root, "Home");
    var body: Parts = .{};
    const summary = try b.fmt("{d} items - recent first", .{count});
    try header.add(b, &body, "Library", .{ .aside = try header.note(b, summary), .aside_width = 320 });
    const filter = try b.named("library.filter", try b.segmented(&filters, ctx.state.library_filter, .library_filter));
    try body.add(tree.sized(filter, 88));
    try cards.add(b, &body, shown[first..last], .{}, .open_library_item, "library.item");
    try body.add(try page.filler(b));
    try root.add(try page.body(b, body.slice()));
    try bars.pager(b, &root, @intCast(count), cards.per_page, ctx.state.library_page, .library_page);
    try bars.shell(b, ctx, &root, 1);
    return b.col(0, root.slice());
}

//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! M6 MDL Library: the works the user follows, filtered by where they are.

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

pub const filters = [_][:0]const u8{ "All", "On device", "Needs Wi-Fi" };

pub fn build(b: *Builder, ctx: screen.Ctx) Error!tree.Widget {
    var shown: [mdl_page.works_cap]cards.Card = undefined;
    var count: usize = 0;
    for (ctx.svc.mdl.library(), 0..) |work, index| {
        const wanted = switch (ctx.state.mdl_library_filter) {
            1 => work.on_device,
            2 => !work.on_device,
            else => true,
        };
        if (!wanted or count == shown.len) continue;
        shown[count] = .{ .title = work.title, .meta = work.meta, .index = @intCast(index) };
        count += 1;
    }

    var root: Parts = .{};
    try bars.system(b, ctx, &root, mdl_page.where);
    var body: Parts = .{};
    const summary = try b.fmt("{d} works", .{count});
    try header.add(b, &body, "Library", .{ .aside = try header.note(b, summary), .aside_width = 200 });
    try body.add(tree.sized(try b.named("mdl_library.filter", try b.segmented(&filters, ctx.state.mdl_library_filter, .mdl_library_filter)), 88));
    try cards.add(b, &body, shown[0..count], .{}, .open_work, "mdl_library.work");
    try body.add(try page.filler(b));
    try root.add(try page.body(b, body.slice()));
    try bars.pager(b, &root, @intCast(count), cards.per_page, ctx.state.mdl_library_page, .mdl_library_page);
    try bars.mdl(b, &root, 1);
    return b.col(0, root.slice());
}

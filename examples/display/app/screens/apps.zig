//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! S8 Apps: the installed modules and what each may use.

const tree = @import("../tree.zig");
const screen = @import("../screen.zig");
const bars = @import("../chrome/bars.zig");
const header = @import("../chrome/header.zig");
const page = @import("../chrome/page.zig");

const Builder = tree.Builder;
const Parts = tree.Parts;
const Error = tree.Error;

const row_height: i16 = 120;
const per_page: u16 = 5;
const installed: u16 = 9;

/// The first page of modules. Only MDL exists; the rest are the design's
/// placeholders until real modules can be listed.
const modules = [_]tree.Row{
    .{ .title = "MDL", .subtitle = "Signed, pinned to Home - can use: network, storage, display", .chevron = true },
    .{ .title = "[APP NAME]", .subtitle = "Signed - can use: [PERMISSIONS]", .chevron = true },
    .{ .title = "[APP NAME]", .subtitle = "Signed - can use: [PERMISSIONS]", .chevron = true },
    .{ .title = "[APP NAME]", .subtitle = "Signed - can use: [PERMISSIONS]", .chevron = true },
    .{ .title = "[APP NAME]", .subtitle = "Signature not recognised - nothing until you allow it", .chevron = true },
};

pub fn build(b: *Builder, ctx: screen.Ctx) Error!tree.Widget {
    var root: Parts = .{};
    try bars.system(b, ctx, &root, "Home");
    var body: Parts = .{};
    const install = try b.button("Install from storage", .inert, .{});
    try header.add(b, &body, "Apps", .{ .aside = install, .aside_width = 320 });
    try body.add(try page.note(b, "Each app is a separate module in its own protected memory."));
    try body.add(try page.note(b, "It can use only what is listed under its name."));
    try body.add(try b.named("apps.list", try b.list(&modules, row_height, .open_app, 0)));
    try body.add(try page.filler(b));
    try root.add(try page.body(b, body.slice()));
    try bars.pager(b, &root, installed, per_page, ctx.state.apps_page, .apps_page);
    try bars.shell(b, ctx, &root, 3);
    return b.col(0, root.slice());
}

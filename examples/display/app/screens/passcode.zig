//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! S10 Passcode settings: the lock, how it asks, and what it protects.

const tree = @import("../tree.zig");
const theme = @import("../theme.zig");
const screen = @import("../screen.zig");
const bars = @import("../chrome/bars.zig");
const header = @import("../chrome/header.zig");
const page = @import("../chrome/page.zig");

const Builder = tree.Builder;
const Parts = tree.Parts;
const Error = tree.Error;

pub const toggle_height: i16 = 72;

pub fn build(b: *Builder, ctx: screen.Ctx) Error!tree.Widget {
    const settings = ctx.svc.settings;
    const links = [_]tree.Row{
        .{ .title = "Change passcode", .chevron = true },
        .{ .title = "Passcode type", .subtitle = settings.info(.passcode_type), .chevron = true },
        .{ .title = "Require passcode", .subtitle = settings.info(.require_passcode), .chevron = true },
    };

    var root: Parts = .{};
    try bars.system(b, ctx, &root, "Home");
    var body: Parts = .{};
    try header.add(b, &body, "Passcode", .{ .back = true });
    try body.add(tree.sized(try b.named("passcode.lock", try b.toggle("Passcode lock", settings.flag(.passcode_lock), .passcode_lock, 0)), toggle_height));
    try body.add(try page.note(b, "Ask for the passcode when the device wakes"));
    try body.add(try b.named("passcode.links", try b.list(&links, theme.metric.row, .open_lock, 0)));
    try body.add(tree.sized(try b.named("passcode.media", try b.toggle("Music controls when locked", settings.flag(.media_when_locked), .media_when_locked, 0)), toggle_height));
    try body.add(try page.note(b, "Play, pause, skip and volume work without the passcode"));
    try body.add(tree.sized(try b.named("passcode.erase", try b.toggle("Erase after 10 wrong attempts", settings.flag(.erase_after_wrong), .erase_after_wrong, 0)), toggle_height));
    try body.add(try page.note(b, "Wrong entries otherwise lock for 1, 5, 15, then 60 minutes"));
    try body.add(try page.hair(b));
    try body.add(try page.note(b, "Everything stored on this device is encrypted with a key tied to your passcode."));
    try body.add(try page.note(b, "If you forget it, the only way back in is a reset that erases everything."));
    try body.add(try page.filler(b));
    try root.add(try page.body(b, body.slice()));
    try bars.shell(b, ctx, &root, 4);
    return b.col(0, root.slice());
}

//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! S11 Date and time: the clock, where it gets the time, how it shows it.

const tree = @import("../tree.zig");
const theme = @import("../theme.zig");
const screen = @import("../screen.zig");
const bars = @import("../chrome/bars.zig");
const header = @import("../chrome/header.zig");
const page = @import("../chrome/page.zig");
const passcode = @import("passcode.zig");

const Builder = tree.Builder;
const Parts = tree.Parts;
const Error = tree.Error;

pub fn build(b: *Builder, ctx: screen.Ctx) Error!tree.Widget {
    const settings = ctx.svc.settings;
    const now = ctx.svc.clock.now();
    const zone = [_]tree.Row{.{ .title = "Time zone", .subtitle = settings.info(.time_zone), .chevron = true }};
    const formats = [_]tree.Row{
        .{ .title = "Date format", .subtitle = settings.info(.date_format), .chevron = true },
        .{ .title = "Sleep after", .subtitle = settings.info(.sleep_after), .chevron = true },
    };

    var root: Parts = .{};
    try bars.system(b, ctx, &root, "Home");
    var body: Parts = .{};
    try header.add(b, &body, "Date and time", .{ .back = true });
    try body.add(tree.sized(try b.label(now.time, theme.text.title), header.height));
    try body.add(try page.line(b, now.long_date));
    try body.add(try page.hair(b));
    try body.add(tree.sized(try b.named("time.wifi", try b.toggle("Set from Wi-Fi", settings.flag(.time_from_wifi), .time_from_wifi, 0)), passcode.toggle_height));
    try body.add(try page.note(b, "Last synced today at 09:12. The clock keeps running while asleep."));
    try body.add(try b.list(&zone, theme.metric.row, .inert, 0));
    try body.add(tree.sized(try b.named("time.24h", try b.toggle("24-hour clock", settings.flag(.clock_24h), .clock_24h, 0)), passcode.toggle_height));
    try body.add(try page.note(b, "Shows 14:05 instead of 2:05 pm"));
    try body.add(try b.list(&formats, theme.metric.row, .inert, 0));
    try body.add(tree.sized(try b.named("time.reader", try b.toggle("Show the time while reading", settings.flag(.time_in_reader), .time_in_reader, 0)), passcode.toggle_height));
    try body.add(try page.note(b, "Adds the time to the footer line of the reader"));
    try body.add(try page.filler(b));
    try root.add(try page.body(b, body.slice()));
    try bars.shell(b, ctx, &root, 4);
    return b.col(0, root.slice());
}

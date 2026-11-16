//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! S7 Equalizer: a preset, then seven bands each moved a step at a time.

const tree = @import("../tree.zig");
const theme = @import("../theme.zig");
const screen = @import("../screen.zig");
const player = @import("../data/player.zig");
const bars = @import("../chrome/bars.zig");
const header = @import("../chrome/header.zig");
const page = @import("../chrome/page.zig");

const Builder = tree.Builder;
const Parts = tree.Parts;
const Widget = tree.Widget;
const Error = tree.Error;

const band_height: i16 = 72;
const name_width: i16 = 170;
const step_width: i16 = 88;
const value_width: i16 = 64;

fn band(b: *Builder, index: u8, level: i8) Error!Widget {
    const down = try b.named(try b.fmt("eq.down.{d}", .{index}), try b.button("-", .band_down, .{ .index = index }));
    const up = try b.named(try b.fmt("eq.up.{d}", .{index}), try b.button("+", .band_up, .{ .index = index }));
    const sign: []const u8 = if (level > 0) "+" else "";
    const value = try b.fmt("{s}{d}", .{ sign, level });
    const filled: u16 = @intCast(@as(i16, level) + player.band_limit);
    const strip = try b.row(16, &.{
        tree.sized(try b.label(player.band_names[index], theme.text.body.with(.right)), name_width),
        tree.sized(down, step_width),
        tree.grow(try b.progress(filled, 2 * @as(u16, player.band_limit))),
        tree.sized(try b.label(value, theme.text.strong.with(.center)), value_width),
        tree.sized(up, step_width),
    });
    return tree.sized(strip, band_height);
}

pub fn build(b: *Builder, ctx: screen.Ctx) Error!Widget {
    var root: Parts = .{};
    try bars.system(b, ctx, &root, "Home");
    var body: Parts = .{};
    const reset = try b.named("eq.reset", try b.button("Reset", .eq_reset, .{}));
    try header.add(b, &body, "Equalizer", .{ .back = true, .aside = reset, .aside_width = 160 });
    try body.add(try page.section(b, "PRESET"));
    try body.add(tree.sized(try b.named("eq.preset", try b.segmented(&player.preset_names, ctx.svc.player.preset(), .eq_preset)), 88));
    try body.add(try page.section(b, "BANDS"));
    for (0..player.band_count) |index| try body.add(try band(b, @intCast(index), ctx.svc.player.band(index)));
    try body.add(try page.note(b, "Bass and treble are the two outer bands. Each tap moves a band one step."));
    try body.add(try page.filler(b));
    try root.add(try page.body(b, body.slice()));
    return b.col(0, root.slice());
}

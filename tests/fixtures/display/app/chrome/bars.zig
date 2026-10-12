//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! The bars every screen shares: the system bar on top, and the shell bar,
//! MDL tab bar and pager underneath. Each adds its bands straight to the
//! screen's root column.

const tree = @import("../tree.zig");
const theme = @import("../theme.zig");
const fields = @import("../fields.zig");
const screen = @import("../screen.zig");

const Builder = tree.Builder;
const Parts = tree.Parts;
const Error = tree.Error;
const metric = theme.metric;
const color = theme.color;

pub const shell_tabs = [_][:0]const u8{ "Home", "Library", "Listen", "Apps", "Settings" };
pub const mdl_tabs = [_][:0]const u8{ "Explore", "Library", "Activity", "Search", "Settings" };

const side_width: i16 = 360;
const pause_width: i16 = 104;
/// The inset that centres one line of UI text in a bar band.
const band_pad: i16 = 24;

fn rule(b: *Builder, root: *Parts, thickness: i16) Error!void {
    try root.add(tree.sized(try b.fill(color.ink), thickness));
}

/// The top bar: a link home on the left, the time, then radio and battery.
pub fn system(b: *Builder, ctx: screen.Ctx, root: *Parts, where: [:0]const u8) Error!void {
    const home = try b.named("sys.home", try b.button(where, .go_home, .{ .border_w = 0, .alignment = .left, .pad = band_pad }));
    const clock = try b.label(ctx.svc.clock.now().time, theme.text.strong.with(.center));
    const status = try b.label("Wi-Fi  82%", theme.text.body.with(.right).padded(band_pad));
    const strip = try b.row(0, &.{ tree.sized(home, side_width), tree.grow(clock), tree.sized(status, side_width) });
    try root.add(tree.sized(strip, metric.sys_bar - metric.rule));
    try rule(b, root, metric.rule);
}

/// The bottom bar of the shell: what is playing with its pause control,
/// then the five shell tabs.
pub fn shell(b: *Builder, ctx: screen.Ctx, root: *Parts, active: u16) Error!void {
    const track = ctx.svc.player.track();
    const playing = ctx.svc.player.playing();
    const line = try b.fmt("{s}  {s} - {s}", .{ if (playing) "Playing" else "Paused", track.album, track.artist });
    const open = try b.named("shell.playing", try b.button(line, .open_player, .{ .border_w = 0, .alignment = .left, .pad = band_pad }));
    const pause = try b.named("shell.pause", try b.button(if (playing) "Pause" else "Play", .play_pause, .{}));
    try rule(b, root, metric.rule);
    try root.add(tree.sized(try b.row(0, &.{ tree.grow(open), tree.sized(pause, pause_width) }), metric.now_playing - metric.rule));
    try rule(b, root, metric.heavy_rule);
    const tabs = try b.named("shell.tabs", try b.navBar(&shell_tabs, active, .shell_tab));
    try root.add(tree.sized(tabs, metric.tabs - metric.heavy_rule));
}

/// The bottom bar inside the MDL app: its five tabs.
pub fn mdl(b: *Builder, root: *Parts, active: u16) Error!void {
    try rule(b, root, metric.heavy_rule);
    const tabs = try b.named("mdl.tabs", try b.navBar(&mdl_tabs, active, .mdl_tab));
    try root.add(tree.sized(tabs, metric.tabs - metric.heavy_rule));
}

/// Previous, Page X of Y, Next, under a rule.
pub fn pager(b: *Builder, root: *Parts, item_count: u16, capacity: u16, page: u16, field: fields.Field) Error!void {
    try rule(b, root, metric.rule);
    const control = try b.named("pager", try b.pager(item_count, capacity, page, field));
    try root.add(tree.sized(control, metric.pager - metric.rule));
}

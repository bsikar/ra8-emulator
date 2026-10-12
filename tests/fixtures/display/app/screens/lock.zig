//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! S2 Passcode lock: the clock, six passcode marks and a numeric keypad.

const tree = @import("../tree.zig");
const theme = @import("../theme.zig");
const screen = @import("../screen.zig");
const state = @import("../state.zig");
const route = @import("../route.zig");
const page = @import("../chrome/page.zig");

const Builder = tree.Builder;
const Parts = tree.Parts;
const Widget = tree.Widget;
const Error = tree.Error;

const key = struct {
    pub const width: i16 = 216;
    pub const height: i16 = 120;
    pub const gap: i16 = 16;
};
const mark: i16 = 32;
const control_width: i16 = 120;

/// The keypad, row by row. A null cell is blank.
const layout = [4][3]?u8{
    .{ 1, 2, 3 },
    .{ 4, 5, 6 },
    .{ 7, 8, 9 },
    .{ null, 0, route.keypad.delete },
};
const labels = [_][:0]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "Delete" };

fn marks(b: *Builder, entered: u8) Error!Widget {
    var cells: Parts = .{};
    try cells.add(try page.filler(b));
    for (0..state.passcode_length) |index| {
        const filled = index < entered;
        const cell = if (filled) try b.fill(theme.color.ink) else try b.button(null, .inert, .{});
        try cells.add(tree.sized(cell, mark));
    }
    try cells.add(try page.filler(b));
    return tree.sized(try b.row(24, cells.slice()), mark);
}

fn keys(b: *Builder, numbers: [3]?u8) Error!Widget {
    var cells: Parts = .{};
    try cells.add(try page.filler(b));
    for (numbers) |maybe| {
        const cell = if (maybe) |index|
            try b.named(try b.fmt("lock.key.{d}", .{index}), try b.button(labels[index], .key, .{ .index = index }))
        else
            try b.fill(theme.color.paper);
        try cells.add(tree.sized(cell, key.width));
    }
    try cells.add(try page.filler(b));
    return tree.sized(try b.row(key.gap, cells.slice()), key.height);
}

fn nowPlaying(b: *Builder, ctx: screen.Ctx) Error!Widget {
    const track = ctx.svc.player.track();
    const playing = ctx.svc.player.playing();
    const line = try b.fmt("{s} - {s} - {s}", .{ track.album, track.artist, if (playing) "playing" else "paused" });
    const strip = try b.row(16, &.{
        tree.grow(try b.label(line, theme.text.body.with(.right))),
        tree.sized(try b.button("Back", .previous, .{}), control_width),
        tree.sized(try b.named("lock.pause", try b.button(if (playing) "Pause" else "Play", .play_pause, .solid)), control_width),
        tree.sized(try b.button("Skip", .skip, .{}), control_width),
    });
    return tree.sized(strip, theme.metric.control);
}

pub fn build(b: *Builder, ctx: screen.Ctx) Error!Widget {
    const now = ctx.svc.clock.now();
    var body: Parts = .{};
    try body.add(tree.sized(try b.label(now.time, theme.text.clock.with(.center)), theme.metric.clock_line));
    try body.add(tree.sized(try b.label(now.day, theme.text.body.with(.center)), page.line_height));
    try body.add(tree.sized(try b.label("Enter passcode", theme.text.strong.with(.center)), 72));
    try body.add(try marks(b, ctx.state.passcode_digits));
    try body.add(try b.space(8));
    for (layout) |numbers| try body.add(try keys(b, numbers));
    try body.add(tree.sized(try b.label("Storage stays encrypted until the passcode is entered.", theme.text.note.with(.center)), 48));
    try body.add(try page.filler(b));
    try body.add(tree.sized(try b.fill(theme.color.ink), theme.metric.rule));
    try body.add(try nowPlaying(b, ctx));
    return b.padded(key.gap, theme.metric.margin, body.slice());
}

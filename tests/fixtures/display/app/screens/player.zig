//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! S6 Now playing: the track, its transport and the volume.

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

const cover_side: i16 = 440;
const transport_width: i16 = 200;
const volume_width: i16 = 104;

fn centred(b: *Builder, child: Widget, width: i16, height: i16) Error!Widget {
    return tree.sized(try b.row(0, &.{ try page.filler(b), tree.sized(child, width), try page.filler(b) }), height);
}

fn transport(b: *Builder, playing: bool) Error!Widget {
    const previous = try b.named("player.previous", try b.button("Previous", .previous, .{}));
    const pause = try b.named("player.pause", try b.button(if (playing) "Pause" else "Play", .play_pause, .solid));
    const next = try b.named("player.next", try b.button("Next", .skip, .{}));
    const keys = try b.row(24, &.{
        try page.filler(b),
        tree.sized(previous, transport_width),
        tree.sized(pause, transport_width),
        tree.sized(next, transport_width),
        try page.filler(b),
    });
    return tree.sized(keys, 104);
}

fn volume(b: *Builder, level: u8) Error!Widget {
    const down = try b.named("player.volume_down", try b.button("-", .volume_down, .{}));
    const up = try b.named("player.volume_up", try b.button("+", .volume_up, .{}));
    const strip = try b.row(16, &.{
        tree.sized(down, volume_width),
        tree.grow(try b.progress(level, player.volume_steps)),
        tree.sized(up, volume_width),
    });
    return tree.sized(strip, theme.metric.control);
}

fn shortcuts(b: *Builder) Error!Widget {
    const equalizer = try b.named("player.equalizer", try b.button("Equalizer", .open_equalizer, .{}));
    const strip = try b.row(0, &.{
        tree.grow(equalizer),
        tree.grow(try b.button("Queue", .inert, .{})),
        tree.grow(try b.button("Shuffle off", .inert, .{})),
        tree.grow(try b.button("Output", .inert, .{})),
    });
    return tree.sized(strip, theme.metric.control);
}

pub fn build(b: *Builder, ctx: screen.Ctx) Error!Widget {
    const track = ctx.svc.player.track();
    var root: Parts = .{};
    try bars.system(b, ctx, &root, "Home");
    var body: Parts = .{};
    const position = try b.fmt("Song {d} of {d}", .{ track.number, track.of });
    try header.add(b, &body, "Now playing", .{ .back = true, .aside = try header.note(b, position), .aside_width = 200 });
    try body.add(try centred(b, try b.label("album cover", theme.text.placeholder), cover_side, cover_side));
    try body.add(tree.sized(try b.label(track.title, theme.text.heading.with(.center)), theme.metric.heading_line));
    try body.add(tree.sized(try b.label(try b.fmt("{s} - {s}", .{ track.artist, track.album }), theme.text.note.with(.center)), page.note_height));
    try body.add(tree.sized(try b.progress(track.minute, track.minutes), 12));
    const elapsed = try b.fmt("Minute {d} of {d}", .{ track.minute, track.minutes });
    try body.add(tree.sized(try b.row(0, &.{
        tree.grow(try b.label(elapsed, theme.text.note)),
        tree.grow(try b.label("Updates each minute", theme.text.note.with(.right))),
    }), page.note_height));
    try body.add(try transport(b, ctx.svc.player.playing()));
    try body.add(try volume(b, ctx.svc.player.volume()));
    try body.add(try shortcuts(b));
    try body.add(try page.filler(b));
    try root.add(try page.body(b, body.slice()));
    return b.col(0, root.slice());
}

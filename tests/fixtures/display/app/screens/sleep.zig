//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! S1 Sleep: the cover of the book being read, held while the device is off.

const tree = @import("../tree.zig");
const theme = @import("../theme.zig");
const screen = @import("../screen.zig");
const page = @import("../chrome/page.zig");

const Builder = tree.Builder;
const Widget = tree.Widget;
const Error = tree.Error;

const cover = struct {
    pub const width: i16 = 620;
    pub const height: i16 = 868;
};

fn centred(b: *Builder, child: Widget, height: i16) Error!Widget {
    return tree.sized(try b.row(0, &.{ try page.filler(b), tree.sized(child, cover.width), try page.filler(b) }), height);
}

pub fn build(b: *Builder, ctx: screen.Ctx) Error!Widget {
    const reading = ctx.svc.library.reading();
    const progress = try b.fmt("{s} - {d}% read", .{ reading.author, reading.percent });
    return b.col(16, &.{
        try page.filler(b),
        try centred(b, try b.label("cover of the book being read", theme.text.placeholder), cover.height),
        tree.sized(try b.label(reading.title, theme.text.heading.with(.center)), theme.metric.heading_line),
        tree.sized(try b.label(progress, theme.text.note.with(.center)), page.note_height),
        try centred(b, try b.fill(theme.color.ink), theme.metric.rule),
        tree.sized(try b.label("Asleep. Press the power button to wake.", theme.text.note.with(.center)), page.note_height),
        try page.filler(b),
    });
}

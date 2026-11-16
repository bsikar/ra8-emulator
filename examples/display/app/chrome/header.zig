//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! The title band at the top of a screen's body: a serif title, an optional
//! back arrow before it and an optional widget after it, closed by a rule.

const tree = @import("../tree.zig");
const theme = @import("../theme.zig");

const Builder = tree.Builder;
const Parts = tree.Parts;
const Widget = tree.Widget;
const Error = tree.Error;

pub const height: i16 = theme.metric.title_line;
const back_width: i16 = 88;

pub const Options = struct {
    /// Show a back arrow before the title.
    back: bool = false,
    /// Something to put at the right edge, and how wide it is.
    aside: ?Widget = null,
    aside_width: i16 = 0,
};

/// Add a title band and its rule to a screen body.
pub fn add(b: *Builder, body: *Parts, title: [:0]const u8, options: Options) Error!void {
    const text = try b.label(title, theme.text.title);
    if (!options.back and options.aside == null) {
        try body.add(tree.sized(text, height));
    } else {
        var band: Parts = .{};
        if (options.back) {
            const back = try b.named("header.back", try b.button("<", .back, .{}));
            try band.add(tree.sized(back, back_width));
        }
        try band.add(tree.grow(text));
        if (options.aside) |aside| try band.add(tree.sized(aside, options.aside_width));
        try body.add(tree.sized(try b.row(16, band.slice()), height));
    }
    try body.add(tree.sized(try b.fill(theme.color.ink), theme.metric.rule));
}

/// A small right-aligned note for the right edge of a title band.
pub fn note(b: *Builder, text: [:0]const u8) Error!Widget {
    return b.label(text, theme.text.note.with(.right));
}

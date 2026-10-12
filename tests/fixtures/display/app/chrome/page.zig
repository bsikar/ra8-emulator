//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! Small pieces most screens are assembled from: the margin-inset body, a
//! section heading, white filler and a line of text.

const tree = @import("../tree.zig");
const theme = @import("../theme.zig");

const Builder = tree.Builder;
const Parts = tree.Parts;
const Widget = tree.Widget;
const Error = tree.Error;
const metric = theme.metric;

pub const gap: i16 = 16;
/// Pixels across a screen body, inside its side margins.
pub const inner_width: i32 = theme.panel.width - 2 * @as(i32, metric.margin);
pub const section_height: i16 = 24;
pub const line_height: i16 = 26;
pub const note_height: i16 = 22;

/// The part of a screen between the system bar and the bottom bars: `kids`
/// stacked inside the margins, growing to fill.
pub fn body(b: *Builder, kids: []const Widget) Error!Widget {
    return tree.grow(try b.padded(gap, metric.margin, kids));
}

/// A capitalised section heading.
pub fn section(b: *Builder, text: [:0]const u8) Error!Widget {
    return tree.sized(try b.label(text, theme.text.section), section_height);
}

/// White space that takes whatever its parent has left.
pub fn filler(b: *Builder) Error!Widget {
    return tree.grow(try b.fill(theme.color.paper));
}

/// One line of body text.
pub fn line(b: *Builder, text: [:0]const u8) Error!Widget {
    return tree.sized(try b.label(text, theme.text.body), line_height);
}

/// One line of smaller text.
pub fn note(b: *Builder, text: [:0]const u8) Error!Widget {
    return tree.sized(try b.label(text, theme.text.note), note_height);
}

/// A full-width hairline.
pub fn hair(b: *Builder) Error!Widget {
    return tree.sized(try b.fill(theme.color.ink), metric.hair);
}

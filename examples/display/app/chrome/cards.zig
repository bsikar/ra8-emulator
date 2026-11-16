//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! Rows of cover cards: a tappable cover placeholder, a bold title and one
//! line of detail under it.

const tree = @import("../tree.zig");
const theme = @import("../theme.zig");
const actions = @import("../actions.zig");

const Builder = tree.Builder;
const Parts = tree.Parts;
const Widget = tree.Widget;
const Error = tree.Error;

pub const Card = struct {
    title: [:0]const u8,
    meta: [:0]const u8,
    /// What a tap on this card's cover posts as the action's index.
    index: u8,
};

pub const Shape = struct {
    cover_height: i16 = 270,
    title_height: i16 = 26,
    meta_height: i16 = 22,
    inner_gap: i16 = 6,
    column_gap: i16 = 32,

    pub fn cardHeight(self: Shape) i16 {
        return self.cover_height + self.title_height + self.meta_height + 2 * self.inner_gap;
    }
};

pub const columns: usize = 4;
pub const per_page: usize = 8;
/// The width of one card in a four-column row across a screen body.
pub const card_width: i32 = 216;

fn card(b: *Builder, item: Card, shape: Shape, action: actions.Id, name: [:0]const u8) Error!Widget {
    const cover = try b.named(name, try b.button("cover", action, .{ .fg = theme.color.muted, .face = theme.color.cover, .border_w = 0, .index = item.index }));
    const title = try b.clip(item.title, theme.text.strong, card_width);
    const meta = try b.clip(item.meta, theme.text.note, card_width);
    return b.col(shape.inner_gap, &.{
        tree.sized(cover, shape.cover_height),
        tree.sized(try b.label(title, theme.text.strong), shape.title_height),
        tree.sized(try b.label(meta, theme.text.note), shape.meta_height),
    });
}

/// Add rows of four cards to a screen body. A tapped cover posts `action`
/// with the card's own index; covers are published by position as
/// `<prefix>.0`, `<prefix>.1` and so on.
pub fn add(b: *Builder, body: *Parts, items: []const Card, shape: Shape, action: actions.Id, prefix: []const u8) Error!void {
    var index: usize = 0;
    while (index < items.len) {
        var cells: [columns]Widget = undefined;
        for (&cells) |*cell| {
            if (index < items.len) {
                const name = try b.fmt("{s}.{d}", .{ prefix, index });
                cell.* = tree.grow(try card(b, items[index], shape, action, name));
                index += 1;
            } else {
                cell.* = tree.grow(try b.fill(theme.color.paper));
            }
        }
        try body.add(tree.sized(try b.row(shape.column_gap, &cells), shape.cardHeight()));
    }
}

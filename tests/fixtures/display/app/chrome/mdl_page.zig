//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! What every MDL screen says in the system bar, and the works grid three
//! of them share.

const mdl = @import("../data/mdl.zig");
const cards = @import("cards.zig");

pub const where: [:0]const u8 = "Home / MDL";

pub const works_cap: usize = cards.per_page;

/// Copy `works` into cards, each posting its own position.
pub fn cardsFor(works: []const mdl.Work, out: *[works_cap]cards.Card) []const cards.Card {
    const count = @min(works.len, works_cap);
    for (works[0..count], out[0..count], 0..) |work, *card, index| {
        card.* = .{ .title = work.title, .meta = work.meta, .index = @intCast(index) };
    }
    return out[0..count];
}

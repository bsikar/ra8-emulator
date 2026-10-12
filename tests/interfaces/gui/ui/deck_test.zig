//! The shell's deck (RA8EMU-958, slice 1): a deck node stacks several views
//! over one area, only the active child solves, its title strip shows one
//! tab per child, and a press on a tab switches the shown child.
const std = @import("std");
const gui_app = @import("gui_app");
const pane_layout = gui_app.pane_layout;
const frame = gui_app.shell.frame;
const titles = gui_app.shell.titles;

/// A deck over two leaves: the board on the left, the registers beside it.
fn deckLayout(allocator: std.mem.Allocator, active: u8) !struct { layout: pane_layout.Layout, first: pane_layout.Index, second: pane_layout.Index } {
    var layout = try pane_layout.Layout.init(allocator, .{ .kind = .board, .core = .cpu0 });
    errdefer layout.deinit();
    _ = try layout.split(layout.root, .across, .{ .kind = .registers, .core = .cpu0 });
    const halves = layout.node(layout.root).body.split;
    const children = [_]pane_layout.Index{ halves.first, halves.second };
    try layout.deck(layout.root, &children);
    if (active != 0) {
        var deck = layout.deckAt(layout.root) orelse return error.TestUnexpectedResult;
        deck.active = active;
        try layout.setDeck(layout.root, deck);
    }
    return .{ .layout = layout, .first = halves.first, .second = halves.second };
}

test "a deck solves only its active child over the whole pane area" {
    const allocator = std.testing.allocator;
    const built = try deckLayout(allocator, 0);
    var layout = built.layout;
    defer layout.deinit();
    var solved = try frame.solve(&layout, allocator, 800, 500);
    defer solved.deinit(allocator);
    const room = frame.panesArea(800, 500);
    try std.testing.expectEqual(@as(usize, 1), solved.panes.items.len);
    const placed = solved.panes.items[0];
    try std.testing.expectEqual(room, placed.area);
    const pane = layout.pane(placed.index) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(pane_layout.Kind.board, pane.kind);
    try std.testing.expectEqual(@as(?pane_layout.Index, layout.root), layout.deckParent(placed.index));
}

test "switching a deck's shown child swaps the solved pane" {
    const allocator = std.testing.allocator;
    const built = try deckLayout(allocator, 1);
    var layout = built.layout;
    defer layout.deinit();
    var solved = try frame.solve(&layout, allocator, 800, 500);
    defer solved.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), solved.panes.items.len);
    const placed = solved.panes.items[0];
    try std.testing.expectEqual(built.second, placed.index);
    const pane = layout.pane(placed.index) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(pane_layout.Kind.registers, pane.kind);
}

test "a press on a tab row switches the shown child and a miss takes the row" {
    const allocator = std.testing.allocator;
    const built = try deckLayout(allocator, 0);
    var layout = built.layout;
    defer layout.deinit();
    var solved = try frame.solve(&layout, allocator, 800, 500);
    defer solved.deinit(allocator);
    const placed = solved.panes.items[0];
    const title = frame.titleOf(placed.area);
    var panes: [pane_layout.max_deck]pane_layout.Pane = undefined;
    panes[0] = .{ .kind = .board, .core = .cpu0 };
    panes[1] = .{ .kind = .registers, .core = .cpu0 };
    const cell = frame.tabAt(title, panes[0..2], 1) orelse return error.TestUnexpectedResult;
    try std.testing.expect(titles.press(&layout, &solved, cell.x + @divTrunc(cell.w, 2), title.y + 1));
    const deck = layout.deckAt(layout.root) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1), deck.active);
    try std.testing.expect(titles.press(&layout, &solved, title.x + title.w - 1, title.y + 1));
    const still = layout.deckAt(layout.root) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1), still.active);
}

test "a deck over a split's halves keeps the split's leaves intact" {
    const allocator = std.testing.allocator;
    const built = try deckLayout(allocator, 0);
    var layout = built.layout;
    defer layout.deinit();
    const first = layout.pane(built.first) orelse return error.TestUnexpectedResult;
    const second = layout.pane(built.second) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(pane_layout.Kind.board, first.kind);
    try std.testing.expectEqual(pane_layout.Kind.registers, second.kind);
    const deck = layout.deckAt(layout.root) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 2), deck.count);
    try std.testing.expectEqual(built.first, deck.children[0]);
    try std.testing.expectEqual(built.second, deck.children[1]);
}

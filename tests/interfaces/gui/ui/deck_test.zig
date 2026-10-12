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
    try std.testing.expect(titles.titlePress(&layout, &solved, cell.x + @divTrunc(cell.w, 2), title.y + 1));
    const deck = layout.deckAt(layout.root) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1), deck.active);
    try std.testing.expect(titles.titlePress(&layout, &solved, title.x + title.w - 1, title.y + 1));
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

/// A split with a deck in its second side and a console leaf in the first,
/// so a dragged tab has another pane to drop on.
fn dragLayout(allocator: std.mem.Allocator) !struct { layout: pane_layout.Layout, deck_leaf: pane_layout.Index, other: pane_layout.Index } {
    var layout = try pane_layout.Layout.init(allocator, .{ .kind = .console, .core = .cpu0 });
    errdefer layout.deinit();
    const deck_leaf = try layout.split(layout.root, .across, .{ .kind = .board, .core = .cpu0 });
    const second = try layout.split(deck_leaf, .across, .{ .kind = .registers, .core = .cpu0 });
    const halves = layout.node(deck_leaf).body.split;
    const children = [_]pane_layout.Index{ halves.first, halves.second };
    try layout.deck(deck_leaf, &children);
    _ = second;
    return .{ .layout = layout, .deck_leaf = deck_leaf, .other = layout.node(layout.root).body.split.first };
}

fn placedAt(solved: *const pane_layout.Solved, index: pane_layout.Index) ?pane_layout.Rect {
    for (solved.panes.items) |placed| if (placed.index == index) return placed.area;
    return null;
}

test "a tab drag released over another pane splits the deck side by side" {
    const allocator = std.testing.allocator;
    const built = try dragLayout(allocator);
    var layout = built.layout;
    defer layout.deinit();
    var solved = try frame.solve(&layout, allocator, 800, 500);
    defer solved.deinit(allocator);
    const home = solved.panes.items[1];
    const title = frame.titleOf(home.area);
    const panes = [_]pane_layout.Pane{ .{ .kind = .board, .core = .cpu0 }, .{ .kind = .registers, .core = .cpu0 } };
    const cell = frame.tabAt(title, &panes, 0) orelse return error.TestUnexpectedResult;
    var tracker = titles.Tracker{};
    try std.testing.expect(tracker.press(&layout, &solved, cell.x + 1, cell.y + 1));
    try std.testing.expect(tracker.drag != null);
    try std.testing.expectEqual(@as(u8, 2), layout.deckAt(built.deck_leaf).?.count);
    const drop = placedAt(&solved, built.other) orelse return error.TestUnexpectedResult;
    try std.testing.expect(tracker.release(&layout, &solved, drop.x + 1, drop.y + 1));
    // The console keeps its side; the deck split, the dragged view a leaf beside it.
    try std.testing.expectEqual(pane_layout.Kind.console, layout.pane(layout.node(layout.root).body.split.first).?.kind);
    const halves = layout.node(built.deck_leaf).body.split;
    try std.testing.expectEqual(pane_layout.Kind.board, layout.pane(halves.first).?.kind);
    try std.testing.expectEqual(@as(u8, 1), layout.deckAt(halves.second).?.count);
}

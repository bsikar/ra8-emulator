//! Host tests for the shell's saved board choice (RA8EMU-1152): a saved
//! file parses back to the choice, and anything else restores nothing.
const std = @import("std");
const gui = @import("gui_app");
const board_store = gui.shell.board_store;

test "a saved file parses back to its choice" {
    const choice = board_store.parse("board ek_ra8d2\npanel none\n") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ek_ra8d2", choice.board());
    try std.testing.expectEqualStrings("none", choice.panel());
}

test "an empty file is a choice with no pick" {
    const choice = board_store.parse("") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), choice.board_len);
    try std.testing.expectEqual(@as(usize, 0), choice.panel_len);
}

test "a corrupt file restores nothing" {
    try std.testing.expect(board_store.parse("what no\n") == null);
    try std.testing.expect(board_store.parse("board\n") == null);
    try std.testing.expect(board_store.parse("board a b\n") == null);
}

const std = @import("std");
const ra8 = @import("ra8");

test "the shipped panel files parse their shape" {
    const panel = try ra8.board.panels.parse(ra8.board.panels.ek_ra8d2);
    try std.testing.expectEqualStrings("ER-TFT070-6", panel.name);
    try std.testing.expectEqual(ra8.board.panels.Kind.tft, panel.kind);
    try std.testing.expectEqual(@as(u16, 1024), panel.width);
    try std.testing.expectEqual(@as(u16, 600), panel.height);
    try std.testing.expectEqual(ra8.board.panels.Format.rgb565, panel.format);
    try std.testing.expectEqual(@as(u16, 169), panel.ppi);

    const eink = try ra8.board.panels.parse(ra8.board.panels.sample_eink);
    try std.testing.expectEqualStrings("E-ink 1072x1448", eink.name);
    try std.testing.expectEqual(ra8.board.panels.Kind.eink, eink.kind);
    try std.testing.expectEqual(@as(u16, 1072), eink.width);
    try std.testing.expectEqual(@as(u16, 1448), eink.height);
    try std.testing.expectEqual(ra8.board.panels.Format.grayscale4, eink.format);
}

test "a panel stem resolves by name and unknown stems fail closed" {
    try std.testing.expect(ra8.board.panels.byName("ek_ra8d2") != null);
    try std.testing.expectEqual(@as(u16, 800), ra8.board.panels.byName("sample_800x480").?.width);
    try std.testing.expect(ra8.board.panels.byName("nope") == null);
    try std.testing.expect(ra8.board.panels.byName("") == null);
}

test "panel files reject missing, unknown and duplicate keys" {
    try std.testing.expectError(error.BadPanel, ra8.board.panels.parse(
        \\name = "X"
        \\type = "tft"
        \\width = 1
        \\height = 1
        \\format = "rgb565"
    ));
    try std.testing.expectError(error.BadPanel, ra8.board.panels.parse(
        \\name = "X"
        \\type = "tft"
        \\width = 1
        \\height = 1
        \\format = "rgb565"
        \\ppi = 1
        \\junk = 1
    ));
    try std.testing.expectError(error.BadPanel, ra8.board.panels.parse(
        \\name = "X"
        \\type = "tft"
        \\width = 1
        \\width = 1
        \\height = 1
        \\format = "rgb565"
        \\ppi = 1
    ));
    try std.testing.expectError(error.BadPanel, ra8.board.panels.parse(
        \\name = "X"
        \\type = "lcd"
        \\width = 1
        \\height = 1
        \\format = "rgb565"
        \\ppi = 1
    ));
    try std.testing.expectError(error.BadPanel, ra8.board.panels.parse(
        \\name = X
        \\type = "tft"
        \\width = 1
        \\height = 1
        \\format = "rgb565"
        \\ppi = 1
    ));
}

test "panel files tolerate comments and blank lines" {
    const panel = try ra8.board.panels.parse("# a comment\n\nname = \"X\"  # trailing\n\ntype = \"eink\"\nwidth = 1\nheight = 2\nformat = \"grayscale4\"\nppi = 3\n");
    try std.testing.expectEqualStrings("X", panel.name);
    try std.testing.expectEqual(ra8.board.panels.Kind.eink, panel.kind);
}

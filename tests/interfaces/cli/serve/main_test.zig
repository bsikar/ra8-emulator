const std = @import("std");
const cli = @import("cli_app").serve.main;

test "serve workspace access requires one explicit nonempty root" {
    const plain = cli.parse(&.{ "ra8", "serve", "--stdio", "firmware.elf" }).?;
    try std.testing.expectEqual(@as(?[]const u8, null), plain.workspace);
    const enabled = cli.parse(&.{ "ra8", "serve", "--workspace", "project with spaces", "--stdio", "firmware.elf" }).?;
    try std.testing.expectEqualStrings("project with spaces", enabled.workspace.?);
    try std.testing.expectEqualStrings("firmware.elf", enabled.elf);
    try std.testing.expect(cli.parse(&.{ "ra8", "serve", "--workspace", "", "--stdio", "fw.elf" }) == null);
    try std.testing.expect(cli.parse(&.{ "ra8", "serve", "--workspace", "one", "--workspace", "two", "--stdio", "fw.elf" }) == null);
    try std.testing.expect(cli.parse(&.{ "ra8", "serve", "--workspace" }) == null);
}

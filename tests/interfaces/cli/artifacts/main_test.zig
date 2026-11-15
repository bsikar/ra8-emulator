const std = @import("std");
const artifacts = @import("cli_app").artifacts;

test "artifact commands accept one target and output path without ambiguous trailing arguments" {
    const snapshot = artifacts.parse(&.{ "ra8", "export-session", "--connect", "tcp::9000", "out.tar", "--state-only" }).?;
    try std.testing.expect(!snapshot.importing and !snapshot.recording);
    try std.testing.expectEqualStrings("out.tar", snapshot.path);
    const recording = artifacts.parse(&.{ "ra8", "export-session", "--connect", "tcp::9000", "out.tar" }).?;
    try std.testing.expect(recording.recording);
    const importing = artifacts.parse(&.{ "ra8", "import-session", "--connect", "tcp::9000", "in.tar" }).?;
    try std.testing.expect(importing.importing);
    try std.testing.expect(artifacts.parse(&.{ "ra8", "import-session", "--connect", "tcp::9000", "in.tar", "--state-only" }) == null);
    try std.testing.expect(artifacts.parse(&.{ "ra8", "export-session", "--connect", "tcp::9000", "out.tar", "extra" }) == null);
    try std.testing.expect(artifacts.parse(&.{ "ra8", "export-session", "--connect", "bad", "out.tar" }) == null);
    try std.testing.expect(artifacts.parse(&.{ "ra8", "export-session", "--connect", "tcp::9000", "" }) == null);
}

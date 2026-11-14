const std = @import("std");
const artifacts = @import("ra8").host.toolchain.artifact;

test "toolchain baseline names complete pinned host archives and refuses unvalidated host support" {
    for (artifacts.zig) |artifact| {
        try std.testing.expectEqualStrings("0.17.0", artifact.version);
        try std.testing.expectEqual(@as(usize, 64), artifact.sha256.len);
        for (artifact.sha256) |c| try std.testing.expect(std.ascii.isHex(c));
        try std.testing.expect(std.mem.startsWith(u8, artifact.url, "https://ziglang.org/download/0.17.0/"));
        try std.testing.expect(artifact.archive_bytes > 50_000_000);
    }
    try std.testing.expectEqual(@as(u64, 57_332_648), (try artifacts.forHost("x86_64-linux")).archive_bytes);
    try std.testing.expectEqual(@as(u64, 100_268_137), (try artifacts.forHost("x86_64-windows")).archive_bytes);
    try std.testing.expectError(error.UnsupportedHost, artifacts.forHost("aarch64-linux"));
    try std.testing.expectError(error.UnsupportedHost, artifacts.forHost("x86_64-macos"));
}

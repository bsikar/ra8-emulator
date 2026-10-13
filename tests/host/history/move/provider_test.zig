const std = @import("std");
const provider = @import("ra8").host.history.move.provider;
const fixture = @import("../root_test.zig");

test "native provider rejects relative paths digest drift and non-PE data" {
    try std.testing.expectError(error.RelativePath, provider.digest(fixture.io, "peer.exe"));
    var f = try fixture.Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(fixture.io, .{ .sub_path = "peer", .data = "not executable" });
    const path = try f.tmp.dir.realPathFileAlloc(fixture.io, "peer", fixture.allocator);
    defer fixture.allocator.free(path);
    const digest = try provider.digest(fixture.io, path);
    try std.testing.expectError(error.InvalidPeer, provider.check(fixture.io, .{ .executable = path, .sha256 = digest }));
    try std.testing.expectError(error.PeerDigestMismatch, provider.check(fixture.io, .{ .executable = path, .sha256 = @splat(0) }));
    var bytes: [64]u8 = undefined;
    try std.testing.expectEqualStrings("not executable", try f.tmp.dir.readFile(fixture.io, "peer", &bytes));
}

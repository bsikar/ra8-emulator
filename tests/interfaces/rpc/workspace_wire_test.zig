const std = @import("std");
const rpc = @import("ra8").rpc;
const wire = rpc.workspace_wire;

test "workspace version tokens preserve identity and reject malformed encodings" {
    var bytes: [wire.version_bytes]u8 = undefined;
    const expected: wire.Version = .{ .kind = .file, .size = 23, .modified_ns = -45, .identity = 67 };
    const token = try wire.encodeVersion(expected, &bytes);
    try std.testing.expectEqual(@as(usize, 25), token.len);
    try std.testing.expect(expected.same(try wire.decodeVersion(token)));
    try std.testing.expectError(error.Truncated, wire.decodeVersion(token[0..24]));
    var encoded: [512]u8 = undefined;
    const request = try rpc.session.rpc.encode(wire.Write, .{ .path = "src/main.zig", .expected = token, .bytes = "edited" }, &encoded);
    const decoded = try rpc.session.rpc.decode(wire.Write, request);
    try std.testing.expectEqualStrings("src/main.zig", decoded.path);
    try std.testing.expectEqualStrings("edited", decoded.bytes);
    try std.testing.expect(expected.same(try wire.decodeVersion(decoded.expected)));
}

const std = @import("std");
const ra8 = @import("ra8");

const artifacts = ra8.rpc.artifacts;
const zeros: [32]u8 = @splat(0);
const fixture = @import("fixture.zig");

test "guessed IDs reordered chunks and bad checksums abort only the current transfer" {
    var f = try fixture.Fixture.open();
    defer f.close();
    const context = &f.original.context;
    const begin = artifacts.handlers.importBegin(context, .{ .total = 3, .sha256 = &zeros });
    const id = begin.ok.id;
    const wrong = artifacts.handlers.importWrite(context, .{ .id = id + 1, .offset = 0, .bytes = "abc" });
    try std.testing.expect(wrong == .err);
    try std.testing.expectEqual(null, context.artifact_transfer.file);
    const second = artifacts.handlers.importBegin(context, .{ .total = 3, .sha256 = &zeros });
    _ = artifacts.handlers.importWrite(context, .{ .id = second.ok.id, .offset = 0, .bytes = "abc" });
    try std.testing.expect(artifacts.handlers.importEnd(context, second.ok) == .err);
    try std.testing.expectEqual(null, context.artifact_transfer.file);
    try std.testing.expectEqual(null, f.service.pending);
    try std.testing.expect(f.service.active == f.original);
}

test "oversized transfer requests refuse before creating a file and disconnect drops uploads" {
    var f = try fixture.Fixture.open();
    defer f.close();
    const context = &f.original.context;
    try std.testing.expect(artifacts.handlers.importBegin(context, .{ .total = artifacts.wire.max_bundle + 1, .sha256 = &zeros }) == .err);
    try std.testing.expectEqual(null, context.artifact_transfer.file);
    _ = artifacts.handlers.importBegin(context, .{ .total = 10, .sha256 = &zeros });
    ra8.rpc.session.server.forget(context);
    try std.testing.expectEqual(null, context.artifact_transfer.file);
}

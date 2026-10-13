const std = @import("std");
const builtin = @import("builtin");
const history = @import("ra8").host.history;
const fixture = @import("../root_test.zig");

test "native bridge without a supplied peer makes no intent or destination" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('d');
    defer fixture.Fixture.abandon(&session);
    var gate = try f.cache.gate(.exclusive);
    defer gate.release();
    try std.testing.expectError(error.NativePeerUnavailable, history.move.bridge.move(.{ .source = &f.cache, .target = &f.cache, .authorities = &.{ gate.file, session.lock } }, &session.id, "target", "publish\n"));
    try std.testing.expect(!history.move.intent.pending(fixture.io, f.cache.dir, &session.id));
    try std.testing.expectError(error.FileNotFound, f.cache.dir.access(fixture.io, "target", .{}));
}

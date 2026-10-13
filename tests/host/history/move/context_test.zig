const std = @import("std");
const builtin = @import("builtin");
const history = @import("ra8").host.history;
const fixture = @import("../root_test.zig");

test "native context requires the actual named gate and source lease" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('a');
    defer fixture.Fixture.abandon(&session);
    var gate = try f.cache.gate(.exclusive);
    defer gate.release();
    const context: history.move.context.Context = .{ .source = &f.cache, .target = &f.cache, .authorities = &.{ gate.file, session.lock } };
    try context.validate(&session.id);
    const wrong: history.move.context.Context = .{ .source = &f.cache, .target = &f.cache, .authorities = &.{ gate.file, gate.file } };
    try std.testing.expectError(error.MissingAuthority, wrong.validate(&session.id));
    const absent: history.move.context.Context = .{ .source = &f.cache, .target = &f.cache, .authorities = &.{} };
    try std.testing.expectError(error.MissingAuthority, absent.validate(&session.id));
    var target_gate = try f.kept.gate(.exclusive);
    defer target_gate.release();
    const target_lease = try history.lock.create(fixture.io, f.kept.dir, &session.id);
    defer target_lease.close(fixture.io);
    const incomplete: history.move.context.Context = .{ .source = &f.cache, .target = &f.kept, .authorities = &.{ gate.file, target_gate.file, session.lock } };
    try std.testing.expectError(error.MissingAuthority, incomplete.validate(&session.id));
    const complete: history.move.context.Context = .{ .source = &f.cache, .target = &f.kept, .authorities = &.{ gate.file, target_gate.file, session.lock, target_lease } };
    try complete.validate(&session.id);
}

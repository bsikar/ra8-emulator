const std = @import("std");
const ra8 = @import("ra8");
const Fixture = @import("../../../host/project/fixture.zig").Fixture;

test "connection cleanup closes an open project and is idempotent before a new client" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var context: ra8.rpc.session.server.Context = .{ .session = undefined, .scratch = &.{}, .workspace = &f.project.workspace.?, .build_runner = &f.project.runner.?, .project = &f.project, .project_base_workspace = &f.base, .topics = .{ 255, 255 }, .advance_from_ns = 12, .advance_target_ns = 24, .transport_epoch = 3 };
    ra8.rpc.session.handlers.forget(&context);
    ra8.rpc.session.handlers.forget(&context);
    try std.testing.expect(context.workspace == &f.base and context.build_runner == null);
    try std.testing.expect(f.project.parsed == null and f.project.workspace == null and f.project.runner == null);
    try std.testing.expectEqual([2]u8{ 0, 0 }, context.topics);
    try std.testing.expectEqual(@as(u64, 0), context.advance_from_ns);
    try std.testing.expectEqual(@as(u64, 0), context.advance_target_ns);
    try std.testing.expectEqual(@as(u64, 0), context.transport_epoch);
}

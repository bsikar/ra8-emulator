const std = @import("std");
const ra8 = @import("ra8");
const Fixture = @import("../../host/project/fixture.zig").Fixture;

test "project RPC open and close restore the base workspace and release the owned build" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.project.close();
    var base_runner = try ra8.host.build.Runner.init(std.testing.io, f.tmp.dir, f.project.backend_compiler);
    defer base_runner.clear();
    var context: ra8.rpc.session.server.Context = .{ .session = undefined, .scratch = &.{}, .workspace = &f.base, .build_runner = &base_runner, .project = &f.project, .project_base_workspace = &f.base, .project_base_runner = &base_runner };
    try std.testing.expectEqual(@as(u8, 1), ra8.rpc.project.open(&context, .{ .config = "project.json" }).ok.accepted);
    try std.testing.expect(context.workspace == &f.project.workspace.? and context.build_runner == &f.project.runner.?);
    try std.testing.expectEqual(@as(u16, 2), @backingInt(ra8.rpc.build.start(&context, .{ .step = "", .options = "[]", .artifact = "bin/fw.elf", .timeout_ms = 5000 }).err));
    const id = ra8.rpc.project.start(&context, .{ .recipe = "debug" }).ok.id;
    try std.testing.expect(id != 0);
    try std.testing.expectEqual(ra8.rpc.project_wire.codes.state, @backingInt(ra8.rpc.project.prepare(&context, .{ .id = id + 1 }).err));
    try std.testing.expectEqual(@as(u8, 1), ra8.rpc.project.close(&context, .{}).ok.accepted);
    try std.testing.expect(context.workspace == &f.base and context.build_runner == &base_runner);
    try std.testing.expect(context.build_id == 0 and f.project.runner == null);
    try std.testing.expectEqual(@as(u8, 1), ra8.rpc.project.open(&context, .{ .config = "project.json" }).ok.accepted);
    ra8.rpc.session.handlers.forget(&context);
    try std.testing.expect(f.project.workspace == null and context.workspace == &f.base);
}

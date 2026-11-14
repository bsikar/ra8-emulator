const std = @import("std");
const api = @import("ra8").host.project;
const Fixture = @import("fixture.zig").Fixture;

test "project handoff binds recipe options and original success state, rather than trusting receipt claims" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.receipt();
    const path = Fixture.directory ++ "/result.json";
    const bytes = try api.files.read(std.testing.allocator, std.testing.io, f.tmp.dir, path, 32_768);
    defer std.testing.allocator.free(bytes);
    var original = try api.receipt.record(std.testing.allocator, bytes);
    defer original.deinit();
    original.value.options = &.{"-Dchanged=true"};
    const changed = try std.json.Stringify.valueAlloc(std.testing.allocator, original.value, .{});
    defer std.testing.allocator.free(changed);
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = changed });
    try std.testing.expectError(error.InvalidBuildReceipt, f.project.load(Fixture.receipt_path));
    original.value.state = "failed";
    const failed = try std.json.Stringify.valueAlloc(std.testing.allocator, original.value, .{});
    defer std.testing.allocator.free(failed);
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = failed });
    try std.testing.expectError(error.BuildNotSuccessful, f.project.load(Fixture.receipt_path));
}

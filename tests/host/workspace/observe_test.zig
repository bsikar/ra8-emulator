const std = @import("std");
const workspace = @import("ra8").host.workspace;
const io = std.testing.io;

test "directory observation sees edits to an existing child without following links" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: workspace.Workspace = .{ .dir = tmp.dir, .io = io };
    try tmp.dir.writeFile(io, .{ .sub_path = "child", .data = "one" });
    const before = try root.observe("");
    try std.testing.expect(before.same(try root.observe("")));
    try tmp.dir.writeFile(io, .{ .sub_path = "child", .data = "different contents" });
    try std.testing.expect(!before.same(try root.observe("")));
}

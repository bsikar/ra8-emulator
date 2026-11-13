const std = @import("std");
const workspace = @import("ra8").host.workspace;
const io = std.testing.io;

test "workspace lazy pages and ranged reads stay within the explicitly opened root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "src", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "abcdef" });
    try tmp.dir.writeFile(io, .{ .sub_path = "second", .data = "two" });
    var files: workspace.Workspace = .{ .dir = tmp.dir, .io = io };
    var entries: [1]workspace.Entry = undefined;
    var names: [512]u8 = undefined;
    const first = try files.list("", 0, &entries, &names);
    try std.testing.expectEqual(@as(usize, 1), first.entries.len);
    try std.testing.expect(first.more);
    const second = try files.list(".", 1, &entries, &names);
    try std.testing.expectEqual(@as(usize, 1), second.entries.len);
    try std.testing.expect(!second.more);
    var bytes: [3]u8 = undefined;
    const read = try files.read("src\\main.zig", 2, &bytes);
    try std.testing.expectEqualStrings("cde", read.bytes);
    try std.testing.expect(!read.eof);
    try std.testing.expect((try files.read("src/main.zig", 3, &bytes)).eof);
    try std.testing.expectEqual(workspace.entry.Kind.missing, (try files.stat("missing")).kind);
    try std.testing.expectError(error.FileNotFound, files.read("missing", 0, &bytes));
    try std.testing.expectError(error.FileNotFound, files.list("missing", 0, &entries, &names));
    try std.testing.expectError(error.InvalidPath, files.read("../outside", 0, &bytes));
    try std.testing.expectError(error.BadOffset, files.read("src/main.zig", 7, &bytes));
    try std.testing.expectError(error.NotFile, files.read("src", 0, &bytes));
}

test "workspace refuses final and ancestor symlink escapes without modifying outside files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try outside.dir.writeFile(io, .{ .sub_path = "sentinel", .data = "preserved" });
    var absolute: [std.fs.max_path_bytes]u8 = undefined;
    const count = try outside.dir.realPath(io, &absolute);
    tmp.dir.symLink(io, absolute[0..count], "outside", .{ .is_directory = true }) catch |err| {
        if (@import("builtin").os.tag == .windows and err == error.PermissionDenied) return error.SkipZigTest;
        return err;
    };
    var target: [std.fs.max_path_bytes]u8 = undefined;
    const file = try std.fmt.bufPrint(&target, "{s}/sentinel", .{absolute[0..count]});
    try tmp.dir.symLink(io, file, "linked", .{});
    var root: workspace.Workspace = .{ .dir = tmp.dir, .io = io };
    var bytes: [32]u8 = undefined;
    try std.testing.expectError(error.NotFile, root.read("linked", 0, &bytes));
    try std.testing.expectError(error.NotFile, root.write("linked", "clobber", try root.stat("linked")));
    if (root.write("outside/sentinel", "clobber", .{})) |_| return error.Escaped else |err| switch (err) {
        error.NotDir, error.SymLinkLoop, error.AccessDenied => {},
        else => return err,
    }
    const kept = try outside.dir.readFileAlloc(io, "sentinel", std.testing.allocator, .limited(32));
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqualStrings("preserved", kept);
}

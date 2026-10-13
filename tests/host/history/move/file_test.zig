const std = @import("std");
const builtin = @import("builtin");
const history = @import("ra8").host.history;
const fixture = @import("../root_test.zig");

const file = history.move.file;
const io = fixture.io;

test "host relocation file carry keeps the file and its bytes under one name" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(io, .{ .sub_path = "from", .data = "store bytes" });
    const before = try file.state(f.tmp.dir, "from");
    try file.carry(f.tmp.dir, "from", f.tmp.dir, "to");
    const after = try file.state(f.tmp.dir, "to");
    try std.testing.expect(before.same(after));
    try std.testing.expectEqual(@as(u32, 1), after.links);
    try std.testing.expectError(error.FileNotFound, file.state(f.tmp.dir, "from"));
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("store bytes", try f.tmp.dir.readFile(io, "to", &buffer));
}

test "host relocation file carry refuses every existing target and changes nothing" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(io, .{ .sub_path = "from", .data = "store bytes" });
    try f.tmp.dir.writeFile(io, .{ .sub_path = "taken", .data = "taken sentinel" });
    try f.tmp.dir.createDir(io, "dir", .default_dir);
    const taken = try file.state(f.tmp.dir, "taken");
    for ([_][]const u8{ "taken", "dir" }) |target| try std.testing.expectError(error.PathAlreadyExists, file.carry(f.tmp.dir, "from", f.tmp.dir, target));
    try std.testing.expectError(error.UnexpectedKind, file.carry(f.tmp.dir, "dir", f.tmp.dir, "other"));
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("store bytes", try f.tmp.dir.readFile(io, "from", &buffer));
    try std.testing.expectEqualStrings("taken sentinel", try f.tmp.dir.readFile(io, "taken", &buffer));
    try std.testing.expect(taken.same(try file.state(f.tmp.dir, "taken")));
    try std.testing.expectEqual(@as(u32, 1), (try file.state(f.tmp.dir, "from")).links);
}

test "host relocation file settle ends a killed carry and never takes a name from another file" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(io, .{ .sub_path = "from", .data = "store bytes" });
    try file.link(f.tmp.dir, "from", f.tmp.dir, "to");
    try std.testing.expectError(error.UnexpectedLinkCount, file.carry(f.tmp.dir, "from", f.tmp.dir, "elsewhere"));
    try file.settle(f.tmp.dir, "from", f.tmp.dir, "to");
    try std.testing.expectError(error.FileNotFound, file.state(f.tmp.dir, "from"));
    try std.testing.expectEqual(@as(u32, 1), (try file.state(f.tmp.dir, "to")).links);
    try f.tmp.dir.writeFile(io, .{ .sub_path = "other", .data = "other bytes" });
    try std.testing.expectError(error.IdentityConflict, file.settle(f.tmp.dir, "other", f.tmp.dir, "to"));
    try std.testing.expectError(error.IdentityConflict, file.finish(f.tmp.dir, "other", f.tmp.dir, "to"));
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("other bytes", try f.tmp.dir.readFile(io, "other", &buffer));
    try std.testing.expectEqualStrings("store bytes", try f.tmp.dir.readFile(io, "to", &buffer));
}

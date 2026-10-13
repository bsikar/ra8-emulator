const std = @import("std");
const history = @import("ra8").host.history;
const fixture = @import("root_test.zig");

const sentinel = "owned outside bytes";
const leaves = [_][]const u8{ history.layout.root.marker, history.layout.root.tag, history.layout.root.gate, history.layout.files.owner, history.layout.files.lock, history.layout.files.incomplete, history.layout.files.kept, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.lease" };

fn unchanged(f: *fixture.Fixture) !void {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(sentinel, try f.tmp.dir.readFile(fixture.io, "sentinel", &buffer));
}

fn matrix(f: *fixture.Fixture) !std.Io.Dir {
    try f.tmp.dir.writeFile(fixture.io, .{ .sub_path = "sentinel", .data = sentinel });
    try f.tmp.dir.createDir(fixture.io, "metadata-matrix", history.layout.directory_permissions);
    return f.tmp.dir.openDir(fixture.io, "metadata-matrix", .{});
}

test "host lifecycle every metadata leaf refuses directories and preserves exclusive bytes" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var dir = try matrix(&f);
    defer dir.close(fixture.io);
    for (leaves) |leaf| {
        try dir.createDir(fixture.io, leaf, history.layout.directory_permissions);
        try std.testing.expectError(error.OutsideRoot, history.metadata.ensure(fixture.io, dir, leaf, "new"));
        try dir.deleteDir(fixture.io, leaf);
        try history.metadata.ensure(fixture.io, dir, leaf, "original");
        const before = try dir.statFile(fixture.io, leaf, .{});
        try history.metadata.ensure(fixture.io, dir, leaf, "original");
        try std.testing.expectEqual(before.inode, (try dir.statFile(fixture.io, leaf, .{})).inode);
        try std.testing.expectError(error.BadMetadata, history.metadata.ensure(fixture.io, dir, leaf, "new"));
        try history.metadata.expect(fixture.io, dir, leaf, "original");
    }
    try unchanged(&f);
}

test "host lifecycle every metadata leaf refuses hardlinks to an owned outside sentinel" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var dir = try matrix(&f);
    defer dir.close(fixture.io);
    for (leaves) |leaf| {
        try f.hardLink("sentinel", dir, leaf);
        try std.testing.expectError(error.OutsideRoot, history.metadata.ensure(fixture.io, dir, leaf, "new"));
        try std.testing.expectError(error.OutsideRoot, history.metadata.open(fixture.io, dir, leaf, .read_write));
        try unchanged(&f);
        try dir.deleteFile(fixture.io, leaf);
    }
}

test "host lifecycle every metadata leaf refuses symlinks and dangling links without outside writes" {
    // Exercise the actual host capability. No privilege changes or
    // automatic unsupported-platform skip hides a missing refusal proof.
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var dir = try matrix(&f);
    defer dir.close(fixture.io);
    for (leaves) |leaf| {
        for ([_][]const u8{ "../sentinel", "../missing-sentinel" }) |target| {
            try fixture.symLink(dir, target, leaf);
            try std.testing.expectError(error.OutsideRoot, history.metadata.ensure(fixture.io, dir, leaf, "new"));
            try unchanged(&f);
            try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(fixture.io, "missing-sentinel", .{}));
            try dir.deleteFile(fixture.io, leaf);
        }
    }
}

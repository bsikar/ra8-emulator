const std = @import("std");
const builtin = @import("builtin");
const history = @import("ra8").host.history;
const fixture = @import("../root_test.zig");

const tree = history.move.tree;
const file = history.move.file;
const moving = history.layout.files.moving;
const io = fixture.io;

/// A source with a file at the top and one a directory down.
fn seed(dir: std.Io.Dir, leaf: []const u8) !void {
    try dir.createDir(io, leaf, .default_dir);
    var made = try dir.openDir(io, leaf, .{});
    defer made.close(io);
    try made.writeFile(io, .{ .sub_path = "payload", .data = "owner bytes" });
    try made.createDir(io, "log", .default_dir);
    var log = try made.openDir(io, "log", .{});
    defer log.close(io);
    try log.writeFile(io, .{ .sub_path = "events", .data = "event bytes" });
}

fn write(dir: std.Io.Dir, entry: []const u8, leaf: []const u8, data: []const u8) !void {
    var made = try dir.openDir(io, entry, .{});
    defer made.close(io);
    try made.writeFile(io, .{ .sub_path = leaf, .data = data });
}

fn expectWhole(dir: std.Io.Dir, leaf: []const u8) !void {
    var made = try dir.openDir(io, leaf, .{});
    defer made.close(io);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("owner bytes", try made.readFile(io, "payload", &buffer));
    try std.testing.expectEqualStrings("event bytes", try made.readFile(io, "log/events", &buffer));
    try std.testing.expectError(error.FileNotFound, made.access(io, moving, .{}));
}

test "host relocation tree move keeps every file one file and leaves no marker" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    try seed(f.tmp.dir, "source");
    var source = try f.tmp.dir.openDir(io, "source", .{});
    const before = try file.state(source, "payload");
    source.close(io);
    try tree.move(fixture.allocator, io, f.tmp.dir, "source", f.tmp.dir, "target", "publish\n");
    try expectWhole(f.tmp.dir, "target");
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "source", .{}));
    var target = try f.tmp.dir.openDir(io, "target", .{});
    defer target.close(io);
    const after = try file.state(target, "payload");
    try std.testing.expect(before.same(after));
    try std.testing.expectEqual(@as(u32, 1), after.links);
}

test "host relocation new tree move refuses every existing target and unmarks its source" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    try seed(f.tmp.dir, "source");
    try seed(f.tmp.dir, "full");
    try f.tmp.dir.createDir(io, "empty", .default_dir);
    try f.tmp.dir.writeFile(io, .{ .sub_path = "plain", .data = "file sentinel" });
    const empty = try file.state(f.tmp.dir, "empty");
    for ([_][]const u8{ "full", "empty", "plain" }) |target| {
        try std.testing.expectError(error.PathAlreadyExists, tree.move(fixture.allocator, io, f.tmp.dir, "source", f.tmp.dir, target, "trash\n"));
        try std.testing.expect(!try tree.moving(io, f.tmp.dir, "source"));
    }
    try expectWhole(f.tmp.dir, "source");
    try expectWhole(f.tmp.dir, "full");
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("file sentinel", try f.tmp.dir.readFile(io, "plain", &buffer));
    try std.testing.expect(empty.same(try file.state(f.tmp.dir, "empty")));
    var kept = try f.tmp.dir.openDir(io, "empty", .{ .iterate = true });
    defer kept.close(io);
    var entries = kept.iterate();
    try std.testing.expect((try entries.next(io)) == null);
}

const Stop = struct {
    phase: history.move.probe.Phase,
    fired: bool = false,
    fn reached(context: *anyopaque, phase: history.move.probe.Phase, _: std.Io.Dir, _: []const u8, _: std.Io.Dir, _: []const u8) !void {
        const self: *Stop = @ptrCast(@alignCast(context));
        if (self.phase == phase and !self.fired) {
            self.fired = true;
            return error.OwnedInterruption;
        }
    }
};
test "host relocation proven tree phases resume and unknown mkdir remains protected" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    for ([_]history.move.probe.Phase{ .source_marked, .target_created, .target_owned, .target_marked, .file_linked, .file_unlinked, .target_ready, .target_unmarked }) |phase| {
        var f = try fixture.Fixture.init();
        defer f.deinit();
        try seed(f.tmp.dir, "source");
        var stop: Stop = .{ .phase = phase };
        try std.testing.expectError(error.OwnedInterruption, tree.moveProbed(fixture.allocator, io, f.tmp.dir, "source", f.tmp.dir, "target", "publish\n", .{ .context = &stop, .reached = Stop.reached }));
        if (phase == .target_created) {
            const before = try file.state(f.tmp.dir, "target");
            try std.testing.expectError(error.UnknownReservation, tree.directory(fixture.allocator, io, f.tmp.dir, "source", f.tmp.dir, "target", "publish\n"));
            try std.testing.expect(before.same(try file.state(f.tmp.dir, "target")));
            try std.testing.expect(try tree.moving(io, f.tmp.dir, "source"));
        } else {
            try tree.directory(fixture.allocator, io, f.tmp.dir, "source", f.tmp.dir, "target", "publish\n");
            try expectWhole(f.tmp.dir, "target");
        }
    }
}
test "host relocation foreign empty target after intent is never adopted" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    try seed(f.tmp.dir, "source");
    try history.move.receipt.start(fixture.allocator, io, f.tmp.dir, "source", f.tmp.dir, "target", "publish\n", null);
    try f.tmp.dir.createDir(io, "target", .default_dir);
    const before = try file.state(f.tmp.dir, "target");
    try std.testing.expectError(error.UnknownReservation, tree.directory(fixture.allocator, io, f.tmp.dir, "source", f.tmp.dir, "target", "publish\n"));
    try std.testing.expect(before.same(try file.state(f.tmp.dir, "target")));
    var target = try f.tmp.dir.openDir(io, "target", .{ .iterate = true });
    defer target.close(io);
    var entries = target.iterate();
    try std.testing.expect(try entries.next(io) == null);
    var bytes: [64]u8 = undefined;
    try std.testing.expectEqualStrings("owner bytes", try f.tmp.dir.readFile(io, "source/payload", &bytes));
}

test "host relocation injected target mkdir ENOSPC retains source and resumes after space returns" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    try seed(f.tmp.dir, "source");
    const failure = struct {
        fn create(userdata: ?*anyopaque, dir: std.Io.Dir, leaf: []const u8, permissions: std.Io.Dir.Permissions) std.Io.Dir.CreateDirError!void {
            if (std.mem.eql(u8, leaf, "target")) return error.NoSpaceLeft;
            return fixture.io.vtable.dirCreateDir(userdata, dir, leaf, permissions);
        }
    };
    var vtable = io.vtable.*;
    vtable.dirCreateDir = failure.create;
    var injected = io;
    injected.vtable = &vtable;
    try std.testing.expectError(error.NoSpaceLeft, tree.move(fixture.allocator, injected, f.tmp.dir, "source", f.tmp.dir, "target", "publish\n"));
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(io, "target", .{}));
    var bytes: [64]u8 = undefined;
    try std.testing.expectEqualStrings("owner bytes", try f.tmp.dir.readFile(io, "source/payload", &bytes));
    try tree.directory(fixture.allocator, io, f.tmp.dir, "source", f.tmp.dir, "target", "publish\n");
    try expectWhole(f.tmp.dir, "target");
}

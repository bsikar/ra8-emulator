const std = @import("std");
const history = @import("ra8").host.history;
const fixture = @import("root_test.zig");

test "host lifecycle runtime probe preserves live discovery and reclaims only stale entries" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    const parent = try f.tmp.dir.realPathFileAlloc(fixture.io, ".", fixture.allocator);
    defer fixture.allocator.free(parent);
    const path = try std.fs.path.join(fixture.allocator, &.{ parent, "runtime" });
    defer fixture.allocator.free(path);
    var directory = try history.runtime.Directory.open(fixture.allocator, fixture.io, path);
    defer directory.close();
    try std.testing.expectError(error.FileNotFound, directory.root.dir.access(fixture.io, history.layout.root.tag, .{}));
    try directory.root.dir.writeFile(fixture.io, .{ .sub_path = "discovery", .data = "existing listener" });
    var state: history.runtime.State = .live;
    const callback = struct {
        fn connect(context: *anyopaque, absolute: []const u8) !history.runtime.State {
            try std.testing.expect(std.fs.path.isAbsolute(absolute));
            const value: *history.runtime.State = @ptrCast(@alignCast(context));
            return value.*;
        }
    };
    const probe: history.runtime.Probe = .{ .context = &state, .connect = callback.connect };
    try std.testing.expectError(error.AlreadyServing, directory.prepare("rpc.sock", "discovery", probe));
    try directory.root.dir.access(fixture.io, "discovery", .{});
    state = .stale;
    var gate = try directory.prepare("rpc.sock", "discovery", probe);
    gate.release();
    try std.testing.expectError(error.FileNotFound, directory.root.dir.access(fixture.io, "discovery", .{}));
    try std.testing.expectError(error.BadName, directory.path(fixture.allocator, "../outside"));
    try std.testing.expectError(error.BadName, directory.path(fixture.allocator, history.layout.root.marker));
}

test "host lifecycle runtime probe errors and unexpected kinds preserve discovery" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    const parent = try f.tmp.dir.realPathFileAlloc(fixture.io, ".", fixture.allocator);
    defer fixture.allocator.free(parent);
    const path = try std.fs.path.join(fixture.allocator, &.{ parent, "runtime-errors" });
    defer fixture.allocator.free(path);
    var directory = try history.runtime.Directory.open(fixture.allocator, fixture.io, path);
    defer directory.close();
    try history.metadata.ensure(fixture.io, directory.root.dir, "discovery", "preserve");
    var fail = true;
    const callback = struct {
        fn connect(context: *anyopaque, _: []const u8) !history.runtime.State {
            const value: *bool = @ptrCast(@alignCast(context));
            if (value.*) return error.OwnedProbeFailure;
            return .stale;
        }
    };
    const probe: history.runtime.Probe = .{ .context = &fail, .connect = callback.connect };
    try std.testing.expectError(error.OwnedProbeFailure, directory.prepare("rpc.sock", "discovery", probe));
    try history.metadata.expect(fixture.io, directory.root.dir, "discovery", "preserve");
    fail = false;
    try directory.root.dir.createDir(fixture.io, "rpc.sock", history.layout.directory_permissions);
    try std.testing.expectError(error.OutsideRoot, directory.prepare("rpc.sock", "discovery", probe));
    try history.metadata.expect(fixture.io, directory.root.dir, "discovery", "preserve");
}

//! Shared owned fixture: only random std.testing.tmpDir namespaces are
//! created or removed. Product APIs resolve and check their own children.
const std = @import("std");
const history = @import("ra8").host.history;
const builtin = @import("builtin");
extern "kernel32" fn CreateHardLinkW(new: [*:0]const u16, existing: [*:0]const u16, reserved: ?*anyopaque) callconv(.winapi) std.os.windows.BOOL;
pub const io = std.testing.io;
pub const allocator = std.testing.allocator;

pub const Fixture = struct {
    tmp: std.testing.TmpDir,
    cache: history.base.Base,
    kept: history.base.Base,

    pub fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer cleanupTmp(&tmp);
        const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(root);
        const cache_path = try std.fs.path.join(allocator, &.{ root, "cache" });
        defer allocator.free(cache_path);
        const kept_path = try std.fs.path.join(allocator, &.{ root, "kept" });
        defer allocator.free(kept_path);
        var cache = try history.base.Base.open(allocator, io, cache_path, .cache);
        errdefer cache.close();
        const kept = try history.base.Base.open(allocator, io, kept_path, .kept);
        return .{ .tmp = tmp, .cache = cache, .kept = kept };
    }

    pub fn deinit(self: *Fixture) void {
        self.kept.close();
        self.cache.close();
        cleanupTmp(&self.tmp);
    }

    pub fn create(self: *Fixture, digit: u8) !history.session.Session {
        const id: history.name.Id = @splat(digit);
        return history.session.Session.create(&self.cache, .{ .id = id });
    }

    /// Construct links only between paths under this owned fixture. The
    /// Zig backend lacks Windows Dir.hardLink; use the native OS primitive.
    pub fn hardLink(self: *Fixture, from: []const u8, to: std.Io.Dir, leaf: []const u8) !void {
        _ = try history.name.component(from);
        _ = try history.name.component(leaf);
        if (builtin.os.tag != .windows) return self.tmp.dir.hardLink(from, to, leaf, io, .{ .follow_symlinks = false });
        const root = try self.tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(root);
        const source = try self.tmp.dir.realPathFileAlloc(io, from, allocator);
        defer allocator.free(source);
        const target_dir = try to.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(target_dir);
        if (!std.mem.startsWith(u8, source, root) or source[root.len] != std.fs.path.sep) return error.UnownedFixture;
        if (!std.mem.startsWith(u8, target_dir, root) or target_dir[root.len] != std.fs.path.sep) return error.UnownedFixture;
        const target = try std.fs.path.join(allocator, &.{ target_dir, leaf });
        defer allocator.free(target);
        const source_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, source);
        defer allocator.free(source_w);
        const target_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, target);
        defer allocator.free(target_w);
        if (!CreateHardLinkW(target_w, source_w, null).toBool()) return error.NativeHardLinkFixtureFailed;
    }

    /// Simulate an abrupt exit by releasing handles without lifecycle work.
    pub fn abandon(session: *history.session.Session) void {
        session.dir.close(io);
        session.lock.close(io);
    }
};

fn cleanupTmp(tmp: *std.testing.TmpDir) void {
    var parent: [std.fs.max_path_bytes]u8 = undefined;
    var actual: [std.fs.max_path_bytes]u8 = undefined;
    var wanted: [std.fs.max_path_bytes]u8 = undefined;
    const len = tmp.parent_dir.realPath(io, &parent) catch @panic("fixture parent resolution failed");
    const expected = std.fmt.bufPrint(&wanted, "{s}{c}{s}", .{ parent[0..len], std.fs.path.sep, &tmp.sub_path }) catch @panic("fixture path overflow");
    const stat = tmp.parent_dir.statFile(io, &tmp.sub_path, .{ .follow_symlinks = false }) catch @panic("fixture missing before cleanup");
    if (stat.kind != .directory) @panic("fixture is a link or non-directory");
    const child_len = tmp.parent_dir.realPathFile(io, &tmp.sub_path, &actual) catch @panic("fixture target resolution failed");
    if (!std.fs.path.isAbsolute(expected) or !std.mem.eql(u8, expected, actual[0..child_len])) @panic("fixture escaped its parent");
    tmp.dir.close(io);
    tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch @panic("owned fixture deletion failed");
    tmp.parent_dir.access(io, &tmp.sub_path, .{}) catch |err| {
        if (err != error.FileNotFound) @panic("fixture deletion could not be verified");
        tmp.parent_dir.close(io);
        tmp.* = undefined;
        return;
    };
    @panic("owned fixture still exists after deletion");
}

test "host lifecycle root exposes only host libraries" {
    _ = history.session.Session;
    _ = history.storage.Store;
    _ = history.budget.Shares;
}

/// Record the actual current Windows link-creation privilege limitation.
/// This is a missing native proof, not a functionality waiver; Linux runs
/// the same metadata-link matrix. No privilege/configuration is changed.
pub fn symLink(dir: std.Io.Dir, target: []const u8, leaf: []const u8) !void {
    dir.symLink(io, target, leaf, .{}) catch |err| {
        if (builtin.os.tag == .windows and err == error.PermissionDenied) return error.SkipZigTest;
        return err;
    };
}

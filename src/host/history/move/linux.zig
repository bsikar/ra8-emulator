//! Linux primitives for the shared native move peer driver (peer.zig):
//! pinned opens, a no-replace renameat2 through the same pins, the process
//! identity the two replies of one exchange are matched by, and the watchdog
//! exit.
const std = @import("std");
const wire = @import("wire.zig");
const metadata = @import("../metadata.zig");
const layout = @import("../layout.zig");

pub fn leafPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return allocator.dupe(u8, path);
}

pub fn selfPid() u32 {
    return @intCast(std.os.linux.getpid());
}

/// End the whole process from the watchdog without running anything that
/// could wait on a stalled thread.
pub fn terminate(code: u8) noreturn {
    std.process.exit(code);
}

/// Whether this filesystem honors the no-replace rename at all: shared
/// filesystems (v9fs and friends) refuse the flag with EINVAL rather than
/// honoring it, and the pin-and-rename contract cannot be exercised there.
/// A collision verdict also proves the flag was honored.
pub fn noReplaceHonored(io: std.Io, root: std.Io.Dir) bool {
    root.createDirPath(io, "probe/src/a") catch return false;
    root.createDirPath(io, "probe/dst") catch return false;
    defer root.deleteTree(io, "probe") catch {};
    const source = std.os.linux.openat(root.handle, "probe/src", .{ .PATH = true, .DIRECTORY = true }, 0);
    if (std.os.linux.errno(source) != .SUCCESS) return false;
    defer {
        _ = std.os.linux.close(@intCast(source));
    }
    const target = std.os.linux.openat(root.handle, "probe/dst", .{ .PATH = true, .DIRECTORY = true }, 0);
    if (std.os.linux.errno(target) != .SUCCESS) return false;
    defer {
        _ = std.os.linux.close(@intCast(target));
    }
    const status = std.os.linux.errno(std.os.linux.renameat2(@intCast(source), "a", @intCast(target), "a", .{ .NOREPLACE = true }));
    return status == .SUCCESS or status == .EXIST;
}

pub fn pinRoot(allocator: std.mem.Allocator, io: std.Io, root: wire.Root) !std.Io.Dir {
    if (root.path.len == 0 or root.path[0] != '/') return error.UnsupportedRoot;
    if (!std.mem.eql(u8, root.marker, layout.root.marker_text) and !std.mem.eql(u8, root.marker, layout.root.kept_marker_text)) return error.Unmarked;
    var result = try pin(allocator, io, null, root.path, false);
    errdefer result.close(io);
    try metadata.expect(io, result, layout.root.marker, root.marker);
    return result;
}

pub fn pin(allocator: std.mem.Allocator, io: std.Io, root: ?std.Io.Dir, path: []const u8, deleting: bool) !std.Io.Dir {
    _ = allocator;
    _ = deleting;
    var result: std.Io.Dir = undefined;
    if (root) |dir| {
        result = dir.openDir(io, path, .{ .follow_symlinks = false }) catch return error.NativePinFailed;
    } else {
        result = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true, .follow_symlinks = false }) catch return error.NativePinFailed;
    }
    errdefer result.close(io);
    if ((try result.stat(io)).kind != .directory) return error.OutsideRoot;
    return result;
}

/// The creation time of this process, reported beside its PID so the two
/// replies of one exchange can be matched. Never a signalling authority.
pub fn birth(io: std.Io) !u64 {
    var bytes: [1024]u8 = undefined;
    const text = std.Io.Dir.cwd().readFile(io, "/proc/self/stat", &bytes) catch return error.ProcessIdentityUnavailable;
    const comm_end = std.mem.lastIndexOfScalar(u8, text, ')') orelse return error.ProcessIdentityUnavailable;
    var fields = std.mem.tokenizeScalar(u8, text[comm_end + 1 ..], ' ');
    var index: usize = 0;
    while (fields.next()) |field| : (index += 1) {
        if (index == 19) return std.fmt.parseInt(u64, field, 10);
    }
    return error.ProcessIdentityUnavailable;
}

/// The rename the request commits: the source entry by its name inside the
/// source root, into the target root under `leaf`, refused rather than
/// replacing whatever is already there. The kernel gives no rename through
/// the entry's own pin, so the parent and the name it was pinned by are the
/// authority; the entry's pin is what held the identity steady.
pub fn rename(allocator: std.mem.Allocator, child: std.Io.Dir, parent: std.Io.Dir, from: []const u8, target: std.Io.Dir, leaf: []const u8) !wire.Status {
    _ = child;
    const source_name = try allocator.allocSentinel(u8, from.len, 0);
    defer allocator.free(source_name);
    @memcpy(source_name[0..from.len], from);
    const target_name = try allocator.allocSentinel(u8, leaf.len, 0);
    defer allocator.free(target_name);
    @memcpy(target_name[0..leaf.len], leaf);
    while (true) {
        const status = std.os.linux.errno(std.os.linux.renameat2(parent.handle, source_name[0..from.len :0], target.handle, target_name[0..leaf.len :0], .{ .NOREPLACE = true }));
        switch (status) {
            .SUCCESS => return .success,
            .EXIST, .NOTEMPTY => return .collision,
            .XDEV => return .cross_device,
            .INTR => continue,
            else => return .refused,
        }
    }
}

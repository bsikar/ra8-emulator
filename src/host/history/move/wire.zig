//! Bounded anonymous-pipe protocol for one native directory move.
const std = @import("std");
const name = @import("../name.zig");
const Deadline = @import("deadline.zig").Deadline;
pub const version = 2;
pub const max_bytes = 32768;
/// One request frame and one COMMIT frame, the most a caller ever writes.
pub const pipe_bytes = max_bytes + 4 + 256 + 4;
/// Milliseconds. `ready` runs from spawn to the bound reply. `commit` is the
/// peer's own window from that reply to an honored COMMIT, and the caller
/// waits `commit` and `drain` together for the done reply. `reap` bounds
/// each wait for the proxy to exit.
pub const Bounds = struct {
    ready: u32 = 10_000,
    commit: u32 = 5_000,
    drain: u32 = 5_000,
    reap: u32 = 2_000,
    pub const limit = 60_000;

    pub fn check(self: Bounds) !void {
        for ([_]u32{ self.ready, self.commit, self.drain, self.reap }) |ms| if (ms == 0 or ms > limit) return error.BadBounds;
    }
};
pub const Root = struct { path: []const u8, marker: []const u8 };
pub const Request = struct { version: u32 = version, nonce: name.Id, source: Root, target: Root, from: []const u8, to: []const u8, commit_ms: u32, drain_ms: u32 };
pub const Phase = enum { starting, bound, done };
pub const Status = enum { success, collision, cross_device, refused, expired };
pub const Reply = struct { version: u32 = version, nonce: name.Id, phase: Phase, pid: u32, source_inode: u64, source_root: u64, target_root: u64, status: Status = .success };
pub const Commit = struct { version: u32 = version, nonce: name.Id, commit: bool };

pub fn write(allocator: std.mem.Allocator, io: std.Io, stream: std.Io.File, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(bytes);
    if (bytes.len == 0 or bytes.len > max_bytes) return error.BadFrame;
    var prefix: [4]u8 = undefined;
    std.mem.writeInt(u32, &prefix, @intCast(bytes.len), .little);
    try stream.writeStreamingAll(io, &prefix);
    try stream.writeStreamingAll(io, bytes);
}

/// A null deadline waits for as long as the writer takes.
pub fn read(comptime T: type, allocator: std.mem.Allocator, io: std.Io, stream: std.Io.File, deadline: ?Deadline) !std.json.Parsed(T) {
    var prefix: [4]u8 = undefined;
    try exact(io, stream, &prefix, deadline);
    const size = std.mem.readInt(u32, &prefix, .little);
    if (size == 0 or size > max_bytes) return error.BadFrame;
    const bytes = try allocator.alloc(u8, size);
    defer allocator.free(bytes);
    try exact(io, stream, bytes, deadline);
    return std.json.parseFromSlice(T, allocator, bytes, .{ .allocate = .alloc_always });
}

fn exact(io: std.Io, stream: std.Io.File, bytes: []u8, deadline: ?Deadline) !void {
    var used: usize = 0;
    while (used < bytes.len) {
        if (deadline) |bound| try bound.readable(io, stream);
        const count = try stream.readStreaming(io, &.{bytes[used..]});
        if (count == 0) return error.EndOfStream;
        used += count;
    }
}

pub fn windowsPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len < 7 or !std.mem.startsWith(u8, path, "/mnt/") or path[5] < 'a' or path[5] > 'z' or path[6] != '/') return error.UnsupportedRoot;
    const result = try allocator.alloc(u8, path.len - 4);
    result[0] = std.ascii.toUpper(path[5]);
    result[1] = ':';
    for (path[6..], 2..) |c, i| result[i] = if (c == '/') '\\' else c;
    return result;
}

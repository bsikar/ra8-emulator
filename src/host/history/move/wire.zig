//! Bounded anonymous-pipe protocol for one native directory move.
const std = @import("std");
const name = @import("../name.zig");
const Deadline = @import("deadline.zig").Deadline;
pub const version = 3;
pub const max_bytes = 32768;
/// One request frame and one COMMIT frame, the most a caller ever writes.
pub const pipe_bytes = max_bytes + 4 + 512 + 4;
/// Milliseconds. Every phase is a ceiling inside one admission that starts
/// before the proxy is spawned and is never reset: `ready` to the bound
/// reply, `commit` the peer's own window from that reply to an honored
/// COMMIT, `drain` after it for the done reply, `reap` for the proxy to
/// exit and `settle` for the caller's own verdict. The admission is their
/// sum, with no grace on top.
pub const Bounds = struct {
    ready: u32 = 10_000,
    commit: u32 = 5_000,
    drain: u32 = 5_000,
    reap: u32 = 2_000,
    settle: u32 = 2_000,
    /// The longest admission a caller may configure.
    pub const limit = 60_000;

    pub fn check(self: Bounds) !void {
        for ([_]u32{ self.ready, self.commit, self.drain, self.reap, self.settle }) |ms| if (ms == 0 or ms > limit) return error.BadBounds;
        if (self.total() > limit) return error.BadBounds;
    }

    pub fn total(self: Bounds) u64 {
        return @as(u64, self.ready) + self.commit + self.drain + self.reap + self.settle;
    }
};
/// Lowercase hex SHA-256 of one durable intent name's exact bytes.
pub const Digest = [64]u8;
/// The anchor and the note as both sides read them through their own handles.
pub const Proof = struct { anchor: Digest, note: Digest };
pub const Root = struct { path: []const u8, marker: []const u8 };
/// `nonce` names the durable intent and `operation` this one exchange, so a
/// frame from an earlier exchange of the same intent is never honored.
pub const Request = struct { version: u32, nonce: name.Id, operation: name.Id, proof: Proof, source: Root, target: Root, from: []const u8, to: []const u8, ready_ms: u32, commit_ms: u32, drain_ms: u32 };
pub const Phase = enum { starting, bound, done };
pub const Status = enum { success, collision, cross_device, refused, expired };
/// `pid` and `birth` are the peer's own report. They are compared between
/// its two replies and shown to observers; they never authorize a signal.
pub const Reply = struct { version: u32, nonce: name.Id, operation: name.Id, proof: Proof, phase: Phase, pid: u32, birth: u64, source_inode: u64, source_root: u64, target_root: u64, status: Status = .success };
pub const Commit = struct { version: u32, nonce: name.Id, operation: name.Id, proof: Proof, commit: bool };

pub fn digest(bytes: []const u8) Digest {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    return std.fmt.bytesToHex(raw, .lower);
}

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

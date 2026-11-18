//! Host-wide target ownership: an exclusive OS lock on `KEY.lease` in a
//! shared lease directory, so two processes on one host can never reserve
//! the same probe. The kernel drops the lock on any exit.
//!
//! Each acquisition also advances a counter stored in the file and returns
//! it as a fencing token. Operations carry the token, and whatever executes
//! them admits only tokens at least as new as the newest it has seen, so a
//! holder that lost its lease (a dropped agent link) cannot act after a newer
//! holder took over.
const std = @import("std");

pub const Lease = struct {
    file: std.Io.File,
    token: u64,

    /// Takes the lease for `key` without waiting. `error.TargetBusy` when
    /// another holder, in this process or another, has it.
    pub fn acquire(io: std.Io, dir_path: []const u8, key: []const u8) !Lease {
        try checkKey(key);
        var name_buffer: [80]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "{s}.lease", .{key});
        var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
        defer dir.close(io);
        const file = try dir.createFile(io, name, .{ .read = true, .truncate = false });
        errdefer file.close(io);
        if (!try file.tryLock(io, .exclusive)) return error.TargetBusy;
        var bytes: [8]u8 = @splat(0);
        const got = try file.readPositional(io, &.{&bytes}, 0);
        if (got != 0 and got != bytes.len) return error.BadLease;
        const last = std.mem.readInt(u64, &bytes, .little);
        const token = std.math.add(u64, last, 1) catch return error.BadLease;
        std.mem.writeInt(u64, &bytes, token, .little);
        if (try file.writePositional(io, &.{&bytes}, 0) != bytes.len) return error.BadLease;
        try file.sync(io);
        return .{ .file = file, .token = token };
    }

    pub fn close(self: *Lease, io: std.Io) void {
        self.file.unlock(io);
        self.file.close(io);
    }
};

/// The executor's side of fencing: the newest token admitted so far.
pub const Fence = struct {
    newest: u64 = 0,

    pub fn admit(self: *Fence, token: u64) !void {
        if (token == 0 or token < self.newest) return error.StaleLease;
        self.newest = token;
    }
};

fn checkKey(key: []const u8) !void {
    if (key.len == 0 or key.len > 64) return error.BadLeaseKey;
    for (key) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.BadLeaseKey;
}

//! Read-only root listing and byte accounting. Host and lock state are
//! reported separately: a remote lock never authorizes local cleanup.
const std = @import("std");
const Base = @import("base.zig").Base;
const name = @import("name.zig");
const layout = @import("layout.zig");
const owner = @import("owner.zig");
const lock = @import("lock.zig");
const machine = @import("machine.zig");

pub const Status = enum { live, stale, kept, other_host, unmarked, creating, pointer, foreign };
pub const Entry = struct {
    /// All strings are borrowed until Iterator.next().
    name: []const u8,
    kind: name.Kind,
    status: Status,
    owner: ?owner.Record = null,
    lock: lock.State = .missing,
    kept: bool = false,
    pointer: ?[]const u8 = null,
};

pub const Iterator = struct {
    base: *const Base,
    entries: std.Io.Dir.Iterator,
    record_buffer: [owner.max_bytes]u8 = undefined,
    pointer_buffer: [std.fs.max_path_bytes]u8 = undefined,

    pub fn init(base: *const Base) !Iterator {
        try base.checkMarked();
        return .{ .base = base, .entries = base.dir.iterate() };
    }

    pub fn next(self: *Iterator) !?Entry {
        while (try self.entries.next(self.base.io)) |entry| {
            const found = name.classify(entry.name);
            // A lease is the root's own file, read through its session.
            if (found.kind == .reserved or found.kind == .lease) continue;
            var result: Entry = .{ .name = entry.name, .kind = found.kind, .status = .foreign };
            if (found.kind == .pointer) {
                const stat = try self.base.dir.statFile(self.base.io, entry.name, .{ .follow_symlinks = false });
                if (stat.kind != .file) return result;
                result.pointer = try self.base.dir.readFile(self.base.io, entry.name, &self.pointer_buffer);
                result.status = .pointer;
                return result;
            }
            if (found.kind != .session and found.kind != .creating and found.kind != .trash) return result;
            self.base.owns(entry.name) catch {
                result.status = .unmarked;
                return result;
            };
            var dir = try self.base.dir.openDir(self.base.io, entry.name, .{ .follow_symlinks = false });
            defer dir.close(self.base.io);
            // One end of a move that has not ended is not a session yet.
            if (@import("move/root.zig").tree.moving(self.base.io, self.base.dir, entry.name) catch true) {
                result.status = .unmarked;
                return result;
            }
            const record = owner.read(self.base.io, dir, &self.record_buffer) catch {
                result.status = .unmarked;
                return result;
            };
            result.owner = record;
            result.lock = lock.probe(self.base.io, self.base.dir, found.id);
            result.kept = exists(self.base.io, dir, layout.files.kept) or self.base.role == .kept;
            var buffer: [machine.limits.host]u8 = undefined;
            const local = machine.hostName(&buffer);
            result.status = if (!std.mem.eql(u8, record.host, local) or std.mem.eql(u8, local, machine.unknown)) .other_host else if (result.lock == .held) .live else if (result.kept) .kept else if (result.lock == .missing) .unmarked else if (found.kind == .creating) .creating else .stale;
            return result;
        }
        return null;
    }
};

pub fn du(base: *const Base, entry: []const u8) !u64 {
    try base.owns(entry);
    var dir = try base.dir.openDir(base.io, entry, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(base.io);
    return directoryBytes(base.io, dir, 0);
}

fn directoryBytes(io: std.Io, dir: std.Io.Dir, depth: u32) anyerror!u64 {
    if (depth >= 64) return error.TooDeep;
    var total: u64 = 0;
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        _ = try name.component(entry.name);
        const stat = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
        if (stat.kind == .file) {
            total = try std.math.add(u64, total, stat.size);
        } else if (stat.kind == .directory) {
            var child = try dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false });
            defer child.close(io);
            total = try std.math.add(u64, total, try directoryBytes(io, child, depth + 1));
        }
    }
    return total;
}

fn exists(io: std.Io, dir: std.Io.Dir, leaf: []const u8) bool {
    _ = dir.statFile(io, leaf, .{ .follow_symlinks = false }) catch return false;
    return true;
}

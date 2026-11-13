//! One explicitly opened host workspace. Descendants never follow symlinks.
const std = @import("std");
pub const path = @import("path.zig");
pub const entry = @import("entry.zig");
pub const observation = @import("observe.zig");
const saving = @import("save.zig");
pub const Version = entry.Version;
pub const Entry = entry.Entry;
pub const max_file_bytes = 262_144;
pub const max_page_entries = 64;
pub const max_offset = 65_536;

pub const Workspace = struct {
    dir: std.Io.Dir,
    io: std.Io,

    pub fn open(io: std.Io, root: []const u8) !Workspace {
        return .{ .dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }), .io = io };
    }

    pub fn close(self: *Workspace) void {
        self.dir.close(self.io);
    }

    pub fn stat(self: *Workspace, name: []const u8) !Version {
        var buffer: [path.capacity]u8 = undefined;
        const normalized = try path.normalize(name, &buffer);
        const parent = try path.parent(self.dir, self.io, normalized);
        defer parent.close(self.io);
        return entry.at(parent.dir, self.io, parent.name);
    }

    pub fn observe(self: *Workspace, name: []const u8) !observation.Snapshot {
        var buffer: [path.capacity]u8 = undefined;
        return observation.inspect(self.dir, self.io, try path.normalize(name, &buffer));
    }

    pub const Read = struct { bytes: []const u8, version: Version, eof: bool };
    pub fn read(self: *Workspace, name: []const u8, offset: u64, into: []u8) !Read {
        if (into.len > max_file_bytes) return error.TooLarge;
        var buffer: [path.capacity]u8 = undefined;
        const normalized = try path.normalize(name, &buffer);
        const parent = try path.parent(self.dir, self.io, normalized);
        defer parent.close(self.io);
        const kind = (try entry.at(parent.dir, self.io, parent.name)).kind;
        if (kind == .missing) return error.FileNotFound;
        if (kind != .file) return error.NotFile;
        const file = try parent.dir.openFile(self.io, parent.name, .{ .allow_directory = false, .follow_symlinks = false });
        defer file.close(self.io);
        const before = try entry.version(try file.stat(self.io));
        if (before.kind != .file) return error.NotFile;
        if (offset > before.size) return error.BadOffset;
        const count: usize = @intCast(@min(before.size - offset, into.len));
        if (try file.readPositionalAll(self.io, into[0..count], offset) != count) return error.Conflict;
        if (!before.same(try entry.version(try file.stat(self.io)))) return error.Conflict;
        return .{ .bytes = into[0..count], .version = before, .eof = offset + count == before.size };
    }

    pub fn write(self: *Workspace, name: []const u8, bytes: []const u8, expected: Version) !Version {
        if (bytes.len > max_file_bytes) return error.TooLarge;
        var buffer: [path.capacity]u8 = undefined;
        const normalized = try path.normalize(name, &buffer);
        if (normalized.len == 0) return error.NotFile;
        const parent = try path.parent(self.dir, self.io, normalized);
        defer parent.close(self.io);
        return saving.save(parent.dir, self.io, parent.name, bytes, expected);
    }

    pub const Page = struct { entries: []const Entry, more: bool };
    pub fn list(self: *Workspace, name: []const u8, offset: u32, entries: []Entry, names: []u8) !Page {
        if (offset > max_offset or entries.len == 0 or entries.len > max_page_entries) return error.BadPage;
        var buffer: [path.capacity]u8 = undefined;
        const normalized = try path.normalize(name, &buffer);
        const parent = try path.parent(self.dir, self.io, normalized);
        defer parent.close(self.io);
        const kind = (try entry.at(parent.dir, self.io, parent.name)).kind;
        if (kind == .missing) return error.FileNotFound;
        if (kind != .directory) return error.NotDir;
        const dir = try parent.dir.openDir(self.io, parent.name, .{ .iterate = true, .follow_symlinks = false });
        defer dir.close(self.io);
        if ((try dir.stat(self.io)).kind != .directory) return error.NotDir;
        var iterator = dir.iterate();
        var skipped: u32 = 0;
        var count: usize = 0;
        var used: usize = 0;
        while (try iterator.next(self.io)) |item| {
            if (skipped < offset) {
                skipped += 1;
                continue;
            }
            if (count == entries.len) return .{ .entries = entries[0..count], .more = true };
            if (item.name.len > names.len - used) return error.NoSpaceLeft;
            @memcpy(names[used..][0..item.name.len], item.name);
            entries[count] = .{ .name = names[used..][0..item.name.len], .kind = entry.kind(item.kind) };
            used += item.name.len;
            count += 1;
        }
        return .{ .entries = entries[0..count], .more = false };
    }
};

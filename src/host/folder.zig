//! A host folder as the SD card builder reads it (components/sd_card/
//! mkimage.zig, RA8EMU-1020): its entries, its subfolders, and its files'
//! sizes and bytes. The builder never opens host files itself; the
//! application hands it a Folder.
const std = @import("std");

pub const Kind = enum { file, directory, other };
pub const Entry = struct { name: []const u8, kind: Kind };

pub const Folder = struct {
    io: std.Io,
    dir: std.Io.Dir,

    /// The folder at `path`, opened for listing.
    pub fn open(io: std.Io, path: []const u8) !Folder {
        return .{ .io = io, .dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) };
    }

    /// A folder over a directory the caller already opened for listing.
    pub fn of(io: std.Io, dir: std.Io.Dir) Folder {
        return .{ .io = io, .dir = dir };
    }

    pub fn close(self: *Folder) void {
        self.dir.close(self.io);
    }

    /// Every entry, in the host's order, names owned by `allocator`; free
    /// with `free`.
    pub fn list(self: Folder, allocator: std.mem.Allocator) ![]Entry {
        var entries: std.ArrayList(Entry) = .empty;
        errdefer free(allocator, entries.items);
        var it = self.dir.iterate();
        while (try it.next(self.io)) |entry| {
            const kind: Kind = switch (entry.kind) {
                .directory => .directory,
                .file => .file,
                else => .other,
            };
            try entries.append(allocator, .{ .name = try allocator.dupe(u8, entry.name), .kind = kind });
        }
        return entries.toOwnedSlice(allocator);
    }

    pub fn free(allocator: std.mem.Allocator, entries: []Entry) void {
        for (entries) |entry| allocator.free(entry.name);
        allocator.free(entries);
    }

    /// The subfolder `name`, which the caller closes.
    pub fn sub(self: Folder, name: []const u8) !Folder {
        return .{ .io = self.io, .dir = try self.dir.openDir(self.io, name, .{ .iterate = true }) };
    }

    pub fn size(self: Folder, name: []const u8) !u64 {
        return (try self.dir.statFile(self.io, name, .{})).size;
    }

    /// The whole file `name`, owned by `allocator`, at most 4 GiB - 1.
    pub fn read(self: Folder, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        return self.dir.readFileAlloc(self.io, name, allocator, .limited(std.math.maxInt(u32)));
    }
};

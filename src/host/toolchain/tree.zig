//! Safe install/verification sink. The pinned archive is the integrity oracle.
const builtin = @import("builtin");
const digest = @import("digest.zig");
const ownership = @import("ownership.zig");
const paths = @import("paths.zig");
const std = @import("std");

pub const Kind = enum { file, directory };
pub const Entry = struct { name: []const u8, kind: Kind, size: u64, mode: u32 };
const Seen = struct { original: []const u8, kind: Kind, declared: bool };
const DirNode = struct { name: []u8, dir: std.Io.Dir };
const Match = struct { depth: usize, offset: usize };

pub const Tree = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    install: bool,
    prefix: []const u8,
    seen: std.StringHashMap(Seen),
    manifest: std.ArrayList(u8) = .empty,
    bytes: u64 = 0,
    entries: u32 = 0,
    stack: [16]DirNode = undefined,
    depth: usize = 0,
    overflow_dir: ?std.Io.Dir = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, root: std.Io.Dir, install: bool, prefix: []const u8) Tree {
        return .{
            .allocator = gpa,
            .io = io,
            .root = root,
            .install = install,
            .prefix = prefix,
            .seen = std.StringHashMap(Seen).init(gpa),
        };
    }

    pub fn deinit(self: *Tree) void {
        self.closeCurrent();
        var entries = self.seen.iterator();
        while (entries.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.original);
        }
        self.seen.deinit();
        self.manifest.deinit(self.allocator);
    }

    fn closeCurrent(self: *Tree) void {
        self.popTo(0);
    }

    fn popTo(self: *Tree, target: usize) void {
        if (self.overflow_dir) |dir| {
            var opened = dir;
            opened.close(self.io);
            self.overflow_dir = null;
        }
        while (self.depth > target) {
            self.depth -= 1;
            var opened = self.stack[self.depth].dir;
            opened.close(self.io);
            self.allocator.free(self.stack[self.depth].name);
        }
    }

    fn remember(self: *Tree, path: []const u8, kind: Kind, declared: bool) !void {
        const key = try std.ascii.allocLowerString(self.allocator, path);
        defer self.allocator.free(key);
        if (self.seen.getPtr(key)) |found| {
            if (!std.mem.eql(u8, found.original, path) or found.kind != kind or
                (found.declared and declared))
            {
                return error.ArchiveCollision;
            }
            found.declared = found.declared or declared;
            return;
        }
        if (self.seen.count() >= 60_000) return error.ArchiveEntryLimit;
        const original = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(original);
        const stored = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(stored);
        try self.seen.put(stored, .{ .original = original, .kind = kind, .declared = declared });
    }

    fn matchPrefix(self: *const Tree, dirname: []const u8) Match {
        var idx: usize = 0;
        var offset: usize = 0;
        var parts = std.mem.splitScalar(u8, dirname, '/');
        while (parts.next()) |part| {
            if (idx >= self.depth or !std.mem.eql(u8, self.stack[idx].name, part)) break;
            idx += 1;
            offset += part.len;
            if (offset < dirname.len) offset += 1;
        }
        return .{ .depth = idx, .offset = offset };
    }

    fn rememberTail(self: *Tree, dirname: []const u8, start: usize) !void {
        var end = start;
        var parts = std.mem.splitScalar(u8, dirname[start..], '/');
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            end += part.len;
            try self.remember(dirname[0..end], .directory, false);
            end += 1;
        }
    }

    fn descendTail(self: *Tree, dirname: []const u8, start: usize) !void {
        try self.rememberTail(dirname, start);
        var offset = start;
        var parts = std.mem.splitScalar(u8, dirname[start..], '/');
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            const base = if (self.depth == 0) self.root else self.stack[self.depth - 1].dir;
            if (self.depth >= self.stack.len) {
                self.overflow_dir = try paths.descend(self.io, base, dirname[offset..], self.install);
                return;
            }
            var opened = try paths.enter(self.io, base, part, self.install);
            errdefer opened.close(self.io);
            const copy = try self.allocator.dupe(u8, part);
            self.stack[self.depth] = .{ .name = copy, .dir = opened };
            self.depth += 1;
            offset += part.len + 1;
        }
    }

    fn parent(self: *Tree, path: []const u8) !std.Io.Dir {
        const dirname = std.fs.path.dirname(path) orelse "";
        if (dirname.len == 0) {
            self.popTo(0);
            return self.root;
        }
        const matched = self.matchPrefix(dirname);
        if (self.overflow_dir != null or matched.depth < self.depth) self.popTo(matched.depth);
        if (matched.offset < dirname.len) try self.descendTail(dirname, matched.offset);
        return self.overflow_dir orelse if (self.depth == 0) self.root else self.stack[self.depth - 1].dir;
    }

    pub fn accept(self: *Tree, entry: Entry, source: anytype) !void {
        const path = try paths.name(entry.name);
        if (!std.mem.eql(u8, path, self.prefix) and
            !(std.mem.startsWith(u8, path, self.prefix) and path.len > self.prefix.len and
                path[self.prefix.len] == '/'))
        {
            return error.WrongArchiveRoot;
        }
        if (entry.size > 512_000_000 or self.bytes + entry.size > 2_000_000_000) return error.ArchiveSizeLimit;
        try self.remember(path, entry.kind, true);
        const parent_dir = try self.parent(path);
        const leaf = std.fs.path.basename(path);
        const hash = switch (entry.kind) {
            .directory => blk: {
                if (entry.size != 0) return error.BadArchiveDirectory;
                var dir = try paths.enter(self.io, parent_dir, leaf, self.install);
                dir.close(self.io);
                break :blk @as([64]u8, @splat('-'));
            },
            .file => try self.file(parent_dir, leaf, entry, source),
        };
        self.bytes += entry.size;
        self.entries += 1;
        const mode = entry.mode & 0o777;
        const line = try std.fmt.allocPrint(self.allocator, "{o} {d} {s} {s}\n", .{ mode, entry.size, hash, path });
        defer self.allocator.free(line);
        if (self.manifest.items.len + line.len > 16_000_000) return error.ManifestLimit;
        try self.manifest.appendSlice(self.allocator, line);
    }

    fn file(self: *Tree, dir: std.Io.Dir, leaf: []const u8, entry: Entry, source: anytype) ![64]u8 {
        if (self.install) {
            const output = try dir.createFile(self.io, leaf, .{
                .read = true,
                .exclusive = true,
                .permissions = permissions(entry.mode),
            });
            defer output.close(self.io);
            try ownership.makeFilePrivate(self.io, dir, leaf, output);
            var buffer: [65536]u8 = undefined;
            var file_writer = output.writer(self.io, &buffer);
            var hash_buffer: [8192]u8 = undefined;
            var hashed = file_writer.interface.hashed(digest.Sha.init(.{}), &hash_buffer);
            try source.writeTo(&hashed.writer);
            try hashed.writer.flush();
            try file_writer.interface.flush();
            if ((try output.stat(self.io)).size != entry.size) return error.ArchiveLengthMismatch;
            try output.setPermissions(self.io, permissions(entry.mode));
            return std.fmt.bytesToHex(hashed.hasher.finalResult(), .lower);
        }
        var hash_buffer: [65536]u8 = undefined;
        var expected = std.Io.Writer.Hashing(digest.Sha).init(&hash_buffer);
        try source.writeTo(&expected.writer);
        try expected.writer.flush();
        const wanted = std.fmt.bytesToHex(expected.hasher.finalResult(), .lower);
        const installed = try paths.regular(self.io, dir, leaf);
        defer installed.close(self.io);
        const info = try installed.stat(self.io);
        if (info.size != entry.size or !(try samePermissions(installed, info.permissions, permissions(entry.mode)))) {
            return error.CacheIntegrityMismatch;
        }
        if (!std.mem.eql(u8, &wanted, &try digest.file(self.io, installed, entry.size))) {
            return error.CacheIntegrityMismatch;
        }
        return wanted;
    }

    /// Refuse extra files, links and case aliases; every installed entry is accounted for.
    pub fn finish(self: *Tree) !void {
        self.closeCurrent();
        var walker = try self.root.walkSelectively(self.allocator);
        defer walker.deinit();
        var count: usize = 0;
        while (try walker.next(self.io)) |entry| {
            if (std.mem.eql(u8, entry.path, ".archive") or std.mem.eql(u8, entry.path, ".manifest")) continue;
            try self.checkEntry(entry, &walker);
            count += 1;
        }
        if (count != self.seen.count()) return error.CacheIntegrityMismatch;
    }

    fn checkEntry(self: *Tree, entry: std.Io.Dir.Walker.Entry, walker: *std.Io.Dir.SelectiveWalker) !void {
        const key = try std.ascii.allocLowerString(self.allocator, entry.path);
        defer self.allocator.free(key);
        if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, key, '\\', '/');
        const expected = self.seen.get(key) orelse return error.ExtraCacheEntry;
        var normalized: [4096]u8 = undefined;
        if (entry.path.len > normalized.len) return error.UnsafeCacheEntry;
        @memcpy(normalized[0..entry.path.len], entry.path);
        std.mem.replaceScalar(u8, normalized[0..entry.path.len], '\\', '/');
        if (!std.mem.eql(u8, expected.original, normalized[0..entry.path.len])) return error.ArchiveCollision;
        const info = try entry.dir.statFile(self.io, entry.basename, .{ .follow_symlinks = false });
        switch (expected.kind) {
            .file => if (info.kind != .file or info.nlink != 1) return error.UnsafeCacheEntry,
            .directory => {
                if (info.kind != .directory) return error.UnsafeCacheEntry;
                const dir = try entry.dir.openDir(self.io, entry.basename, .{ .follow_symlinks = false });
                defer dir.close(self.io);
                try ownership.directory(self.io, dir);
                try walker.enter(self.io, entry);
            },
        }
    }
};

fn permissions(mode: u32) std.Io.File.Permissions {
    return if (builtin.os.tag == .windows)
        @fromBackingInt(1)
    else
        .fromMode(if (mode & 0o111 != 0) 0o555 else 0o444);
}

fn samePermissions(
    opened: std.Io.File,
    actual: std.Io.File.Permissions,
    expected: std.Io.File.Permissions,
) !bool {
    if (builtin.os.tag != .windows) return actual.toMode() & 0o777 == expected.toMode();
    // Zig 0.17 fileStatWindows currently returns .default_file regardless of
    // the real attributes. Query the pinned file instead of trusting that stub.
    const w = std.os.windows;
    var info: w.FILE.BASIC_INFORMATION = undefined;
    var status_block: w.IO_STATUS_BLOCK = undefined;
    const status = w.ntdll.NtQueryInformationFile(
        opened.handle,
        &status_block,
        &info,
        @sizeOf(w.FILE.BASIC_INFORMATION),
        .Basic,
    );
    if (status != .SUCCESS) return error.CacheAttributesUnavailable;
    return info.FileAttributes.READONLY == (@backingInt(expected) & 1 != 0);
}

//! Content revision of regular workspace inputs, with explicit finite limits.
const std = @import("std");
const paths = @import("../workspace/path.zig");
const Budget = @import("request.zig").Budget;
const Hash = std.crypto.hash.sha2.Sha256;
const allocator = std.heap.page_allocator;
const Totals = struct { entries: usize = 0, bytes: u64 = 0 };

pub fn revision(root: std.Io.Dir, budget: Budget) ![64]u8 {
    var hash = Hash.init(.{});
    var totals: Totals = .{};
    try directory(root, budget, &hash, &totals, 0);
    return std.fmt.bytesToHex(hash.finalResult(), .lower);
}

fn ignored(name: []const u8) bool {
    inline for (.{ ".git", ".zig-cache", "zig-out", ".ra8-builds" }) |skip| if (std.mem.eql(u8, name, skip)) return true;
    return false;
}

fn directory(dir: std.Io.Dir, budget: Budget, hash: *Hash, totals: *Totals, depth: usize) !void {
    if (depth > 32) return error.SourceLimit;
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var iterator = dir.iterate();
    while (try iterator.next(budget.io)) |entry| {
        try budget.check();
        if (ignored(entry.name)) continue;
        totals.entries += 1;
        if (totals.entries > 10_000) return error.SourceLimit;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    for (names.items) |name| {
        try budget.check();
        const info = try dir.statFile(budget.io, name, .{ .follow_symlinks = false });
        hash.update(name);
        hash.update(&.{0});
        switch (info.kind) {
            .directory => {
                hash.update("directory\x00");
                const child = try dir.openDir(budget.io, name, .{ .iterate = true, .follow_symlinks = false });
                defer child.close(budget.io);
                try directory(child, budget, hash, totals, depth + 1);
                hash.update("end-directory\x00");
            },
            .file => {
                const file = try dir.openFile(budget.io, name, .{ .follow_symlinks = false, .allow_directory = false });
                defer file.close(budget.io);
                const digest = try fileHash(file, budget, &totals.bytes, 256 * 1024 * 1024);
                hash.update(&digest);
            },
            else => return error.UnsupportedSourceEntry,
        }
    }
}

pub fn fileHash(file: std.Io.File, budget: Budget, total: *u64, limit: u64) ![32]u8 {
    const before = try file.stat(budget.io);
    if (before.kind != .file) return error.NotFile;
    var hash = Hash.init(.{});
    var buffer: [32_768]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        try budget.check();
        const n = try file.readPositionalAll(budget.io, &buffer, offset);
        if (n == 0) break;
        total.* += n;
        if (total.* > limit) return error.SourceLimit;
        hash.update(buffer[0..n]);
        offset += n;
    }
    const after = try file.stat(budget.io);
    if (offset != before.size or before.size != after.size or before.mtime.nanoseconds != after.mtime.nanoseconds) return error.SourceChanged;
    return hash.finalResult();
}

pub fn artifact(root: std.Io.Dir, name: []const u8, budget: Budget) ![64]u8 {
    const parent = try paths.parent(root, budget.io, name);
    defer parent.close(budget.io);
    const file = try parent.dir.openFile(budget.io, parent.name, .{ .follow_symlinks = false, .allow_directory = false });
    defer file.close(budget.io);
    var magic: [4]u8 = undefined;
    if (try file.readPositionalAll(budget.io, &magic, 0) != 4 or !std.mem.eql(u8, &magic, "\x7fELF")) return error.NotElf;
    var size: u64 = 0;
    return std.fmt.bytesToHex(try fileHash(file, budget, &size, 64 * 1024 * 1024), .lower);
}

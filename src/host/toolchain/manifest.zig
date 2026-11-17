//! Verify installed compiler trees from a SHA-256-pinned archive manifest.
const digest = @import("digest.zig");
const std = @import("std");
const tree_mod = @import("tree.zig");

const maximum_bytes: usize = 16_000_000;

const Parsed = struct {
    entry: tree_mod.Entry,
    wanted: *const [64]u8,
};

pub fn read(gpa: std.mem.Allocator, io: std.Io, record: std.Io.File) ![]u8 {
    const size = (try record.stat(io)).size;
    if (size > maximum_bytes) return error.ManifestLimit;
    const bytes = try gpa.alloc(u8, @intCast(size));
    errdefer gpa.free(bytes);
    if (try record.readPositionalAll(io, bytes, 0) != size) return error.CacheManifestMismatch;
    if ((try record.stat(io)).size != size) return error.CacheManifestMismatch;
    return bytes;
}

pub fn verify(bytes: []const u8, expected_sha256: []const u8, tree: *tree_mod.Tree) !void {
    if (bytes.len > maximum_bytes) return error.ManifestLimit;
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') return error.CacheManifestMismatch;
    if (!std.mem.eql(u8, &digest.bytes(bytes), expected_sha256)) return error.CacheManifestMismatch;
    var lines = std.mem.splitScalar(u8, bytes[0 .. bytes.len - 1], '\n');
    while (lines.next()) |line| {
        const parsed = try parseLine(line);
        try tree.verifyRecorded(parsed.entry, parsed.wanted);
    }
    try tree.finish();
}

fn nextField(rest: *[]const u8) ![]const u8 {
    const space = std.mem.indexOfScalar(u8, rest.*, ' ') orelse return error.CacheManifestMismatch;
    if (space == 0) return error.CacheManifestMismatch;
    const field = rest.*[0..space];
    rest.* = rest.*[space + 1 ..];
    return field;
}

fn classifyHash(hash: *const [64]u8) !tree_mod.Kind {
    if (std.mem.allEqual(u8, hash, '-')) return .directory;
    for (hash) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!is_hex) return error.CacheManifestMismatch;
    }
    return .file;
}

fn parseLine(line: []const u8) !Parsed {
    var rest = line;
    const mode_text = try nextField(&rest);
    const size_text = try nextField(&rest);
    const hash_text = try nextField(&rest);
    if (rest.len == 0 or hash_text.len != 64) return error.CacheManifestMismatch;
    const mode = std.fmt.parseInt(u32, mode_text, 8) catch return error.CacheManifestMismatch;
    if (mode > 0o777) return error.CacheManifestMismatch;
    const size = std.fmt.parseInt(u64, size_text, 10) catch return error.CacheManifestMismatch;
    const wanted = hash_text[0..64];
    const kind = try classifyHash(wanted);
    return .{
        .entry = .{ .name = rest, .kind = kind, .size = size, .mode = mode },
        .wanted = wanted,
    };
}

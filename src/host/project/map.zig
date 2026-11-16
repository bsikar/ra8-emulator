//! Lexical source paths use the path's own grammar, independent of the host OS.
const std = @import("std");

pub fn normalize(name: []const u8, into: []u8) ![]const u8 {
    if (name.len == 0 or
        name.len > 4096 or
        name.len > into.len or
        std.mem.indexOfScalar(u8, name, 0) != null) return error.SourceUnavailable;
    const drive = name.len >= 3 and std.ascii.isAlphabetic(name[0]) and name[1] == ':' and slash(name[2]);
    if (!drive and !slash(name[0])) return error.SourceUnavailable;
    var used: usize = if (drive) 3 else if (name.len > 1 and slash(name[1])) 2 else 1;
    if (drive) @memcpy(into[0..3], &[_]u8{ name[0], ':', '/' }) else @memset(into[0..used], '/');
    const floor = used;
    var ends: [512]usize = undefined;
    var count: usize = 0;
    var parts = std.mem.tokenizeAny(u8, name[used..], "/\\");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (count == 0) return error.SourceUnavailable;
            count -= 1;
            used = ends[count];
            continue;
        }
        if (count == ends.len) return error.SourceUnavailable;
        ends[count] = used;
        count += 1;
        if (used > floor) {
            into[used] = '/';
            used += 1;
        }
        @memcpy(into[used..][0..part.len], part);
        used += part.len;
    }
    return into[0..used];
}

pub fn prefix(name: []const u8, root: []const u8) bool {
    if (name.len < root.len) return false;
    const windows = (root.len > 1 and root[1] == ':') or std.mem.startsWith(u8, root, "//");
    if (!(if (windows)
        std.ascii.eqlIgnoreCase(name[0..root.len], root)
    else
        std.mem.eql(u8, name[0..root.len], root))) return false;
    return name.len == root.len or std.mem.endsWith(u8, root, "/") or name[root.len] == '/';
}

pub fn replace(name: []const u8, from: []const u8, to: []const u8, into: []u8) ![]const u8 {
    if (!prefix(name, from)) return error.SourceUnavailable;
    const joined = try std.fmt.bufPrint(
        into,
        "{s}/{s}",
        .{ std.mem.trimEnd(u8, to, "/"), std.mem.trimStart(u8, name[from.len..], "/") },
    );
    return std.mem.trimEnd(u8, joined, if (joined.len > 3) "/" else "");
}

fn slash(c: u8) bool {
    return c == '/' or c == '\\';
}

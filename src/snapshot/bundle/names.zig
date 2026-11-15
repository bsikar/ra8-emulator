//! Portable archive leaf names shared by the reader and writer.
const std = @import("std");

pub fn check(leaf: []const u8) !void {
    if (leaf.len == 0 or leaf.len > 96) return error.InvalidName;
    if (std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, "..")) return error.InvalidName;
    for (leaf) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_') {
            return error.InvalidName;
        }
    }
}

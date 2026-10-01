//! Which encodings have conformance vectors. A semantics module claims the
//! encodings it implements and lists the encoding of every vector it carries;
//! an encoding claimed with no vector is a gap, and the suite test turns a gap
//! into a failed `zig build test`.
const std = @import("std");

/// How many of `covered` name `encoding`.
pub fn count(encoding: []const u8, covered: []const []const u8) usize {
    var n: usize = 0;
    for (covered) |name| {
        if (std.mem.eql(u8, name, encoding)) n += 1;
    }
    return n;
}

/// The first claimed encoding that no vector covers, or null when every
/// claimed encoding has at least one.
pub fn firstMissing(claimed: []const []const u8, covered: []const []const u8) ?[]const u8 {
    for (claimed) |encoding| {
        if (count(encoding, covered) == 0) return encoding;
    }
    return null;
}

/// The first vector encoding that nothing claims, or null. A vector for an
/// encoding nobody claims is a typo in its name or a claim someone forgot.
pub fn firstUnclaimed(claimed: []const []const u8, covered: []const []const u8) ?[]const u8 {
    for (covered) |encoding| {
        if (count(encoding, claimed) == 0) return encoding;
    }
    return null;
}

/// The coverage table as Markdown: one row per claimed encoding, in claim
/// order, with its vector count and "missing" where the count is zero.
pub fn writeTable(writer: anytype, claimed: []const []const u8, covered: []const []const u8) !void {
    try writer.writeAll("| Encoding | Vectors |\n|---|---|\n");
    for (claimed) |encoding| {
        const n = count(encoding, covered);
        if (n == 0) {
            try writer.print("| {s} | missing |\n", .{encoding});
        } else {
            try writer.print("| {s} | {d} |\n", .{ encoding, n });
        }
    }
}

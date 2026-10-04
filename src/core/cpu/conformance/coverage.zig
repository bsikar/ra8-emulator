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

/// The whole coverage document, docs/conformance.md: a short header saying
/// what the table is and how to regenerate it, then the table.
pub fn writeDocument(writer: anytype, claimed: []const []const u8, covered: []const []const u8) !void {
    try writer.writeAll(
        \\# Conformance coverage
        \\
        \\Every encoding the Zig core's semantics claim, and how many vectors from
        \\the Arm ARM (DDI0553) pseudocode cover it. Generated from
        \\src/core/cpu/conformance/suite.zig; `zig build test` fails when this file
        \\is stale or a semantics encoding is missing. Regenerate with
        \\`RA8_BLESS_CONFORMANCE=1 zig build test`.
        \\
        \\
    );
    if (claimed.len == 0) {
        try writer.writeAll("No encodings claimed yet.\n");
        return;
    }
    try writeTable(writer, claimed, covered);
}

/// The decode-table section: one row per group the Zig decode table
/// registers, in decode order, with how many vectors name the group. A group
/// with none reads "missing", and the suite test fails the build on it as it
/// does for a semantics encoding (RA8EMU-278).
pub fn writeDecoded(writer: anytype, decoded: []const []const u8, covered: []const []const u8) !void {
    try writer.writeAll(
        \\
        \\## Decode table
        \\
        \\Every instruction group the Zig decode table registers
        \\(src/core/cpu/ops/table.zig), and how many conformance vectors name it.
        \\The FP and MVE groups' semantics are covered encoding by encoding in the
        \\table above. A group with no vector fails `zig build test`.
        \\
        \\
    );
    try writer.writeAll("| Group | Vectors |\n|---|---|\n");
    for (decoded) |group| {
        const n = count(group, covered);
        if (n == 0) {
            try writer.print("| {s} | missing |\n", .{group});
        } else {
            try writer.print("| {s} | {d} |\n", .{ group, n });
        }
    }
}

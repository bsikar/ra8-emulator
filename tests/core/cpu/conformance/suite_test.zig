//! The build-failing half of the conformance suite: a claimed encoding with no
//! vector, or a vector naming an encoding nobody claims, fails `zig build test`.
const std = @import("std");
const ra8 = @import("ra8");
const coverage = ra8.core.conformance_coverage;
const suite = ra8.core.conformance_suite;

test "every claimed encoding has at least one vector" {
    if (coverage.firstMissing(suite.claimed, suite.covered)) |gap| {
        std.debug.print("conformance: {s} is claimed but has no vector\n", .{gap});
        return error.MissingConformanceVector;
    }
}

test "every vector names an encoding the core claims" {
    if (coverage.firstUnclaimed(suite.claimed, suite.covered)) |stray| {
        std.debug.print("conformance: a vector names {s}, which nothing claims\n", .{stray});
        return error.UnclaimedConformanceVector;
    }
}

/// The coverage document as it should read for the suite as it stands.
fn expectedDocument(allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try coverage.writeDocument(out.writer(), suite.claimed, suite.covered);
    return out.toOwnedSlice();
}

test "docs/conformance.md matches the suite, or is rewritten when blessed" {
    const allocator = std.testing.allocator;
    const want = try expectedDocument(allocator);
    defer allocator.free(want);
    if (std.process.hasEnvVarConstant("RA8_BLESS_CONFORMANCE")) {
        try std.fs.cwd().writeFile(.{ .sub_path = suite.table_path, .data = want });
        return;
    }
    const have = try std.fs.cwd().readFileAlloc(allocator, suite.table_path, 1 << 20);
    defer allocator.free(have);
    if (!std.mem.eql(u8, have, want)) {
        std.debug.print("conformance: {s} is stale; run RA8_BLESS_CONFORMANCE=1 zig build test\n", .{suite.table_path});
        return error.StaleConformanceTable;
    }
}

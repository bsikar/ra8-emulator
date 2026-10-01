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

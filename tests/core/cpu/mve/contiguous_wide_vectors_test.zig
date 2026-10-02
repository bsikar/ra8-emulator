//! Covers src/core/cpu/mve/contiguous_wide_vectors.zig.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.core.conformance_vector;
const contiguous = ra8.core.mve.contiguous;
const vectors = ra8.core.mve.contiguous_wide_vectors;

test "widening loads and narrowing stores match the pseudocode" {
    try vector.expectAll(contiguous.Element, u32, contiguous.element, &vectors.vectors);
}

test "every vector is counted in covered" {
    try std.testing.expectEqual(vectors.vectors.len, vectors.covered.len);
}

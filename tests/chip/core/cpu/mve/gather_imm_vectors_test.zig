//! Covers src/chip/core/cpu/mve/gather_imm_vectors.zig.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.core.conformance_vector;
const gather = ra8.core.mve.gather;
const vectors = ra8.core.mve.gather_imm_vectors;

test "vector-base gather/scatter addresses match the pseudocode" {
    try vector.expectAll(gather.VectorBase, u32, gather.vectorAddress, &vectors.vectors);
}

test "every vector is counted in covered" {
    try std.testing.expectEqual(vectors.vectors.len, vectors.covered.len);
}

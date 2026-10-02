//! Covers src/core/cpu/mve/contiguous_vectors.zig.
const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.core.conformance_vector;
const contiguous = ra8.core.mve.contiguous;
const vectors = ra8.core.mve.contiguous_vectors;

fn run(in: contiguous.Form) contiguous.Plan {
    return contiguous.plan(in);
}

test "the VLDR/VSTR address plan matches the pseudocode" {
    try vector.expectAll(contiguous.Form, contiguous.Plan, run, &vectors.vectors);
}

test "every vector is counted in covered" {
    try std.testing.expectEqual(vectors.vectors.len, vectors.covered.len);
}

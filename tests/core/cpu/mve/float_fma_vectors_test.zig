//! Covers src/core/cpu/mve/float_fma_vectors.zig.
const ra8 = @import("ra8");
const vector = ra8.core.conformance_vector;
const float = ra8.core.mve.float;
const vectors = ra8.core.mve.float_fma_vectors;
const Out = ra8.core.mve.float_vectors.Out;

fn run(in: vectors.Operands) Out {
    var fpscr: ra8.core.fpu.fpscr.Fpscr = .{};
    const q = float.fused(in.d, in.n, in.m, in.size, in.op, in.mask, &fpscr);
    return .{ .q = q, .flags = ra8.core.fpu.case.flagsOf(fpscr) };
}

test "MVE VFMA, VFMS and VFMAS match the pseudocode" {
    try vector.expectAll(vectors.Operands, Out, run, &vectors.vectors);
}

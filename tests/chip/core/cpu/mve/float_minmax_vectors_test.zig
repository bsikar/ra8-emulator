//! Covers src/chip/core/cpu/mve/float_minmax_vectors.zig.
const ra8 = @import("ra8");
const vector = ra8.core.conformance_vector;
const float_minmax = ra8.core.mve.float_minmax;
const vectors = ra8.core.mve.float_minmax_vectors;
const Out = ra8.core.mve.float_vectors.Out;

fn run(in: vectors.Operands) Out {
    var fpscr: ra8.core.fpu.fpscr.Fpscr = .{};
    const q = float_minmax.lanes(in.d, in.n, in.m, in.size, in.which, in.abs, in.mask, &fpscr);
    return .{ .q = q, .flags = ra8.core.fpu.case.flagsOf(fpscr) };
}

test "MVE VMAXNM/VMINNM and the A forms match the pseudocode" {
    try vector.expectAll(vectors.Operands, Out, run, &vectors.vectors);
}

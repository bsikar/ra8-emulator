//! Covers src/chip/core/cpu/mve/float_cvt_vectors.zig.
const ra8 = @import("ra8");
const vector = ra8.core.conformance_vector;
const float_cvt = ra8.core.mve.float_cvt;
const vectors = ra8.core.mve.float_cvt_vectors;
const Out = ra8.core.mve.float_vectors.Out;

fn run(in: vectors.Operands) Out {
    var fpscr: ra8.core.fpu.fpscr.Fpscr = .{ .ahp = in.ahp };
    const q = switch (in.dir) {
        .to_half => float_cvt.toHalf(in.d, in.m, in.top, in.mask, &fpscr),
        .from_half => float_cvt.fromHalf(in.d, in.m, in.top, in.mask, &fpscr),
    };
    return .{ .q = q, .flags = ra8.core.fpu.case.flagsOf(fpscr) };
}

test "MVE VCVTB and VCVTT match the pseudocode" {
    try vector.expectAll(vectors.Operands, Out, run, &vectors.vectors);
}

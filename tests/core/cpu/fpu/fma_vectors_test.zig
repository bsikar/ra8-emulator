const std = @import("std");
const ra8 = @import("ra8");
const format = ra8.core.fpu.format;
const fma = ra8.core.fpu.fma;
const case = ra8.core.fpu.case;
const vectors = ra8.core.fpu.fma_vectors;

fn run(comptime fmt: format.Format, encoding: []const u8, d: fmt.Bits(), n: fmt.Bits(), m: fmt.Bits(), fpscr: *ra8.core.fpu.fpscr.Fpscr) fmt.Bits() {
    if (std.mem.startsWith(u8, encoding, "VFMA.")) return fma.vfma(fmt, d, n, m, fpscr);
    if (std.mem.startsWith(u8, encoding, "VFMS.")) return fma.vfms(fmt, d, n, m, fpscr);
    if (std.mem.startsWith(u8, encoding, "VFNMA.")) return fma.vfnma(fmt, d, n, m, fpscr);
    if (std.mem.startsWith(u8, encoding, "VFNMS.")) return fma.vfnms(fmt, d, n, m, fpscr);
    unreachable;
}

fn expectVectors(comptime fmt: format.Format, vs: anytype) !void {
    for (vs) |v| {
        var fpscr = v.input.fpscr();
        const bits = run(fmt, v.encoding, v.input.d, v.input.n, v.input.m, &fpscr);
        const got = case.Result(fmt.Bits()){ .bits = bits, .flags = case.flagsOf(fpscr) };
        if (!std.meta.eql(got, v.expect)) {
            std.debug.print("{s} {s}: got {x} flags {x}, want {x} flags {x}\n", .{ v.encoding, v.name, got.bits, got.flags, v.expect.bits, v.expect.flags });
            return error.TestExpectedEqual;
        }
    }
}

test "VFMA.F32 matches FPMulAdd" {
    try expectVectors(format.single, &vectors.fma32);
}

test "VFMS, VFNMA and VFNMS .F32 match FPMulAdd with FPNeg" {
    try expectVectors(format.single, &vectors.others32);
}

test "the double-precision forms match" {
    try expectVectors(format.double, &vectors.all64);
}

test "every vector is counted in covered" {
    const total = vectors.fma32.len + vectors.others32.len + vectors.all64.len;
    try std.testing.expectEqual(total, vectors.covered.len);
}

const std = @import("std");
const ra8 = @import("ra8");
const vector = ra8.core.conformance_vector;
const fpu = ra8.core.fpu;
const case = fpu.case;
const vectors = fpu.select_vectors;
const Cond = fpu.select.Cond;

/// The condition a vector exercises, read from its encoding name
/// ("VSELEQ.F32 T1" -> .eq).
fn condOf(encoding: []const u8) Cond {
    const cc = encoding[4..6];
    if (std.mem.eql(u8, cc, "EQ")) return .eq;
    if (std.mem.eql(u8, cc, "VS")) return .vs;
    if (std.mem.eql(u8, cc, "GE")) return .ge;
    return .gt;
}

fn expectAll(comptime B: type, list: []const vector.Vector(case.Select(B), case.Result(B))) !void {
    for (list) |v| {
        const got = fpu.select.select(B, condOf(v.encoding), v.input.nzcv, v.input.a, v.input.b);
        std.testing.expectEqual(v.expect.bits, got) catch |err| {
            std.debug.print("conformance: {s} ({s})\n", .{ v.encoding, v.name });
            return err;
        };
        try std.testing.expectEqual(@as(u32, 0), v.expect.flags);
    }
}

test "VSEL .F32 matches the pseudocode" {
    try expectAll(u32, &vectors.select32);
}

test "VSEL .F64 matches the pseudocode" {
    try expectAll(u64, &vectors.select64);
}

test "every vector is counted in covered" {
    try std.testing.expectEqual(vectors.select32.len + vectors.select64.len, vectors.covered.len);
}

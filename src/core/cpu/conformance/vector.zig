//! A conformance vector: one encoding, one input, and the result the Arm ARM
//! (DDI0553) pseudocode says that encoding must produce. The pseudocode is the
//! oracle, Armv8.1-M included.
//!
//! A vector compares outputs bit for bit with `std.meta.eql`, so a float
//! result is carried as its bit pattern, never as an `f32` or `f64`: a NaN
//! payload or a signed zero is part of what the pseudocode specifies.
const std = @import("std");

/// One vector for an operation that takes `In` and produces `Out`.
pub fn Vector(comptime In: type, comptime Out: type) type {
    return struct {
        /// The encoding this vector exercises, spelled the way the coverage
        /// table lists it, for example "VADD (floating-point)".
        encoding: []const u8,
        /// What the vector checks, quoted when it fails.
        name: []const u8,
        input: In,
        expect: Out,
    };
}

pub const Error = error{ConformanceMismatch};

/// The index of the first vector whose result is not the expected one, or
/// null when every vector holds.
pub fn firstMismatch(
    comptime In: type,
    comptime Out: type,
    op: *const fn (In) Out,
    vectors: []const Vector(In, Out),
) ?usize {
    for (vectors, 0..) |v, i| {
        if (!std.meta.eql(op(v.input), v.expect)) return i;
    }
    return null;
}

/// Runs every vector through `op` and fails on the first mismatch, printing
/// the encoding, the vector's name, and what came back against what the
/// pseudocode expects.
pub fn expectAll(
    comptime In: type,
    comptime Out: type,
    op: *const fn (In) Out,
    vectors: []const Vector(In, Out),
) Error!void {
    const i = firstMismatch(In, Out, op, vectors) orelse return;
    const v = vectors[i];
    std.debug.print("conformance: {s} ({s}): got {any}, expected {any}\n", .{
        v.encoding,
        v.name,
        op(v.input),
        v.expect,
    });
    return error.ConformanceMismatch;
}

/// The encoding names a vector set covers, one per vector, in order, so a
/// suite can hand them to the coverage check without knowing `In` or `Out`.
pub fn encodingsOf(
    comptime In: type,
    comptime Out: type,
    comptime vectors: []const Vector(In, Out),
) [vectors.len][]const u8 {
    var names: [vectors.len][]const u8 = undefined;
    for (vectors, 0..) |v, i| names[i] = v.encoding;
    return names;
}

//! Conformance vectors for VRINTA, VRINTN, VRINTP, VRINTM, VRINTZ, VRINTR
//! and VRINTX, worked from FPRoundInt in the Arm ARM (DDI0553). They cover
//! each rounding and its ties, zero results keeping the operand's sign,
//! values that are already integral, denormals with and without FZ, NaN
//! handling, and IXC raised only by VRINTX.
const defs = @import("types.zig");

const case = defs.case;
const vector = defs.vector;
pub const V32 = defs.V32;
pub const V64 = defs.V64;

const rint32_01 = @import("rint32_01.zig");
const rint32_02 = @import("rint32_02.zig");

pub const rint32 = rint32_01.values ++
    rint32_02.values;

const rint64_01 = @import("rint64_01.zig");

pub const rint64 = rint64_01.values;

pub const claimed = [_][]const u8{
    "VRINTA",
    "VRINTN",
    "VRINTP",
    "VRINTM",
    "VRINTZ",
    "VRINTR",
    "VRINTX",
};

pub const covered = vector.encodingsOf(case.Integral(u32), case.Result(u32), &rint32) ++
    vector.encodingsOf(case.Integral(u64), case.Result(u64), &rint64);

//! Conformance vectors for VFMA, VFMS, VFNMA and VFNMS, worked from
//! FPMulAdd and FPNeg in the Arm ARM (DDI0553). Finite results were checked
//! against an exact rational model rounded per mode. They cover the single
//! rounding (where the chained forms would differ), three-way NaN priority,
//! the quiet-NaN addend with infinity times zero, signed zeros, overflow,
//! and terms far enough apart that one only decides the rounding.
const defs = @import("types.zig");

const case = defs.case;
const vector = defs.vector;
pub const V32 = defs.V32;
pub const V64 = defs.V64;

const fma32_01 = @import("fma32_01.zig");
const fma32_02 = @import("fma32_02.zig");

pub const fma32 = fma32_01.values ++
    fma32_02.values;

const others32_01 = @import("others32_01.zig");

pub const others32 = others32_01.values;

const all64_01 = @import("all64_01.zig");

pub const all64 = all64_01.values;

pub const claimed = [_][]const u8{
    "VFMA, VFMS (floating-point)",
    "VFNMA",
    "VFNMS",
};

pub const covered = vector.encodingsOf(case.Ternary(u32), case.Result(u32), &fma32) ++
    vector.encodingsOf(case.Ternary(u32), case.Result(u32), &others32) ++
    vector.encodingsOf(case.Ternary(u64), case.Result(u64), &all64);

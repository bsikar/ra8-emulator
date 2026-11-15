//! Conformance vectors for the MVE multiplies in int.mul.zig, worked from
//! the VMULH, VRMULH, VQDMULH, VQRDMULH, VMLA and VMLAS pseudocode in the
//! Arm ARM (DDI0553). The doubling vectors include the most negative value
//! squared, the one case that saturates. The VQ{R}DMLA{S}H vectors come from
//! /workspace/tools/mve_dmlah.py on the lane's box.
const defs = @import("types.zig");

const int = defs.int;
const vector = defs.vector;
pub const HighCase = defs.HighCase;
pub const ScalarCase = defs.ScalarCase;
pub const DoublingCase = defs.DoublingCase;

const high_01 = @import("high_01.zig");

pub const high = high_01.values;

const scalar_01 = @import("scalar_01.zig");

pub const scalar = scalar_01.values;

const doubling_01 = @import("doubling_01.zig");

pub const doubling = doubling_01.values;

pub const claimed = [_][]const u8{
    "VMULH T1",
    "VRMULH T1",
    "VQDMULH T1",
    "VQRDMULH T1",
    "VMLA T1",
    "VMLAS T1",
    "VQDMLAH T1",
    "VQRDMLAH T1",
    "VQDMLASH T1",
    "VQRDMLASH T1",
};

pub const covered = vector.encodingsOf(HighCase, int.Sat, &high) ++
    vector.encodingsOf(ScalarCase, u128, &scalar) ++
    vector.encodingsOf(DoublingCase, int.Sat, &doubling);

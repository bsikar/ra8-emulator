//! Conformance vectors for the MVE narrowing and widening ops in
//! int_width.zig, worked from the VMOVN, VQMOVN, VQMOVUN, VSHRN, VRSHRN,
//! VQSHRN, VQRSHRN, VQSHRUN, VMOVL and VSHLL pseudocode in the Arm ARM
//! (DDI0553). The destination is a distinct byte pattern so a narrowing op
//! that touches the half it should keep shows up.
const defs = @import("types.zig");

const int = defs.int;
const vector = defs.vector;
pub const NarrowCase = defs.NarrowCase;
pub const WidenCase = defs.WidenCase;

const narrowing_01 = @import("narrowing_01.zig");
const narrowing_02 = @import("narrowing_02.zig");

pub const narrowing = narrowing_01.values ++
    narrowing_02.values;

const widening_01 = @import("widening_01.zig");

pub const widening = widening_01.values;

pub const claimed = [_][]const u8{
    "VMOVN T1",
    "VQMOVN T1",
    "VQMOVUN T1",
    "VSHRN T1",
    "VRSHRN T1",
    "VQSHRN T1",
    "VQRSHRN T1",
    "VQSHRUN T1",
    "VMOVL T1",
    "VSHLL T1",
};

pub const covered = vector.encodingsOf(NarrowCase, int.Sat, &narrowing) ++
    vector.encodingsOf(WidenCase, u128, &widening);

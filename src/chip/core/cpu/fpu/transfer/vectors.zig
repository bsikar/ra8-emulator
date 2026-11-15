//! Conformance vectors for the FP loads and stores, worked from VLDR,
//! VSTR, VLDM, VSTM, VPUSH and VPOP in the Arm ARM (DDI0553): start
//! address, first S word, word count and writeback for every addressing
//! form, the FLDMX odd-imm8 step, literal alignment, wrapping, and each
//! UNDEFINED and UNPREDICTABLE case.
const defs = @import("types.zig");

const transfer = defs.transfer;
const vector = defs.vector;
pub const Many = defs.Many;
pub const One = defs.One;

const multiple_01 = @import("multiple_01.zig");
const multiple_02 = @import("multiple_02.zig");

pub const multiple = multiple_01.values ++
    multiple_02.values;

const single_01 = @import("single_01.zig");

pub const single = single_01.values;

pub const claimed = [_][]const u8{
    "VLDM",
    "VSTM",
    "VPUSH",
    "VPOP",
    "VLDR",
    "VSTR",
};

pub const covered = vector.encodingsOf(transfer.Multiple, transfer.Plan, &multiple) ++
    vector.encodingsOf(transfer.Single, transfer.Plan, &single);

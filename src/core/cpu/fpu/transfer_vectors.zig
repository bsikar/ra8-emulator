//! Conformance vectors for the FP loads and stores, worked from VLDR,
//! VSTR, VLDM, VSTM, VPUSH and VPOP in the Arm ARM (DDI0553): start
//! address, first S word, word count and writeback for every addressing
//! form, the FLDMX odd-imm8 step, literal alignment, wrapping, and each
//! UNDEFINED and UNPREDICTABLE case.
const vector = @import("../conformance/vector.zig");
const transfer = @import("transfer.zig");

pub const Many = vector.Vector(transfer.Multiple, transfer.Plan);
pub const One = vector.Vector(transfer.Single, transfer.Plan);

pub const multiple = [_]Many{
    .{ .encoding = "VLDM.F64 T1", .name = "IA without writeback", .input = .{ .p = 0, .u = 1, .w = 0, .rn = 1, .base = 0x2000_1000, .d = 0, .imm8 = 4, .double = true }, .expect = .{ .start = 0x2000_1000, .words = 4, .first = 0 } },
    .{ .encoding = "VLDM.F64 T1", .name = "IA with writeback", .input = .{ .p = 0, .u = 1, .w = 1, .rn = 1, .base = 0x2000_1000, .d = 2, .imm8 = 6, .double = true }, .expect = .{ .start = 0x2000_1000, .words = 6, .first = 4, .wback = 0x2000_1018 } },
    .{ .encoding = "VLDM.F64 T1", .name = "DB with writeback", .input = .{ .p = 1, .u = 0, .w = 1, .rn = 1, .base = 0x2000_1000, .d = 8, .imm8 = 16, .double = true }, .expect = .{ .start = 0x2000_0FC0, .words = 16, .first = 16, .wback = 0x2000_0FC0 } },
    .{ .encoding = "VLDM.F64 T1", .name = "all sixteen D registers", .input = .{ .p = 0, .u = 1, .w = 0, .rn = 2, .base = 0x2000_1000, .d = 0, .imm8 = 32, .double = true }, .expect = .{ .start = 0x2000_1000, .words = 32, .first = 0 } },
    .{ .encoding = "VLDM.F64 T1", .name = "seventeen registers", .input = .{ .p = 0, .u = 1, .w = 0, .rn = 2, .base = 0x2000_1000, .d = 0, .imm8 = 34, .double = true }, .expect = .{ .fault = .unpredictable } },
    .{ .encoding = "VLDM.F64 T1", .name = "an empty list", .input = .{ .p = 0, .u = 1, .w = 1, .rn = 1, .base = 0x2000_1000, .d = 0, .imm8 = 0, .double = true }, .expect = .{ .fault = .unpredictable } },
    .{ .encoding = "VLDM.F64 T1", .name = "imm8 1 is an empty double list", .input = .{ .p = 0, .u = 1, .w = 1, .rn = 1, .base = 0x2000_1000, .d = 0, .imm8 = 1, .double = true }, .expect = .{ .fault = .unpredictable } },
    .{ .encoding = "VLDM.F64 T1", .name = "past D15", .input = .{ .p = 0, .u = 1, .w = 0, .rn = 1, .base = 0x2000_1000, .d = 15, .imm8 = 4, .double = true }, .expect = .{ .fault = .unpredictable } },
    .{ .encoding = "VLDM.F64 T1", .name = "odd imm8 (FLDMX) steps Rn by imm8 words", .input = .{ .p = 0, .u = 1, .w = 1, .rn = 1, .base = 0x2000_1000, .d = 0, .imm8 = 5, .double = true }, .expect = .{ .start = 0x2000_1000, .words = 4, .first = 0, .wback = 0x2000_1014 } },
    .{ .encoding = "VLDM.F64 T1", .name = "Rn = PC", .input = .{ .p = 0, .u = 1, .w = 0, .rn = 15, .base = 0x2000_1000, .d = 0, .imm8 = 2, .double = true }, .expect = .{ .fault = .unpredictable } },
    .{ .encoding = "VLDM.F64 T1", .name = "P = U with W is UNDEFINED", .input = .{ .p = 1, .u = 1, .w = 1, .rn = 1, .base = 0x2000_1000, .d = 0, .imm8 = 2, .double = true }, .expect = .{ .fault = .undefined } },
    .{ .encoding = "VLDM.F64 T1", .name = "P = U = 0 with W is UNDEFINED", .input = .{ .p = 0, .u = 0, .w = 1, .rn = 1, .base = 0x2000_1000, .d = 0, .imm8 = 2, .double = true }, .expect = .{ .fault = .undefined } },
    .{ .encoding = "VLDM.F32 T2", .name = "IA from S3", .input = .{ .p = 0, .u = 1, .w = 0, .rn = 1, .base = 0x2000_1000, .d = 3, .imm8 = 5, .double = false }, .expect = .{ .start = 0x2000_1000, .words = 5, .first = 3 } },
    .{ .encoding = "VLDM.F32 T2", .name = "DB into S31", .input = .{ .p = 1, .u = 0, .w = 1, .rn = 1, .base = 0x2000_1000, .d = 31, .imm8 = 1, .double = false }, .expect = .{ .start = 0x2000_0FFC, .words = 1, .first = 31, .wback = 0x2000_0FFC } },
    .{ .encoding = "VLDM.F32 T2", .name = "past S31", .input = .{ .p = 0, .u = 1, .w = 0, .rn = 1, .base = 0x2000_1000, .d = 31, .imm8 = 2, .double = false }, .expect = .{ .fault = .unpredictable } },
    .{ .encoding = "VLDM.F32 T2", .name = "all thirty-two S registers", .input = .{ .p = 0, .u = 1, .w = 1, .rn = 1, .base = 0x2000_1000, .d = 0, .imm8 = 32, .double = false }, .expect = .{ .start = 0x2000_1000, .words = 32, .first = 0, .wback = 0x2000_1080 } },
    .{ .encoding = "VLDM.F32 T2", .name = "DB wraps below zero", .input = .{ .p = 1, .u = 0, .w = 1, .rn = 1, .base = 0x0000_0004, .d = 0, .imm8 = 4, .double = false }, .expect = .{ .start = 0xFFFF_FFF4, .words = 4, .first = 0, .wback = 0xFFFF_FFF4 } },
    .{ .encoding = "VSTM.F64 T1", .name = "IA with writeback", .input = .{ .p = 0, .u = 1, .w = 1, .rn = 4, .base = 0x2000_1000, .d = 1, .imm8 = 4, .double = true }, .expect = .{ .start = 0x2000_1000, .words = 4, .first = 2, .wback = 0x2000_1010 } },
    .{ .encoding = "VSTM.F64 T1", .name = "DB with writeback", .input = .{ .p = 1, .u = 0, .w = 1, .rn = 4, .base = 0x2000_1000, .d = 0, .imm8 = 2, .double = true }, .expect = .{ .start = 0x2000_0FF8, .words = 2, .first = 0, .wback = 0x2000_0FF8 } },
    .{ .encoding = "VSTM.F32 T2", .name = "DB with writeback", .input = .{ .p = 1, .u = 0, .w = 1, .rn = 4, .base = 0x2000_1000, .d = 10, .imm8 = 3, .double = false }, .expect = .{ .start = 0x2000_0FF4, .words = 3, .first = 10, .wback = 0x2000_0FF4 } },
    .{ .encoding = "VSTM.F32 T2", .name = "an empty list", .input = .{ .p = 0, .u = 1, .w = 0, .rn = 4, .base = 0x2000_1000, .d = 0, .imm8 = 0, .double = false }, .expect = .{ .fault = .unpredictable } },
    .{ .encoding = "VPUSH.F64 T1", .name = "D8 to D15 below SP", .input = .{ .p = 1, .u = 0, .w = 1, .rn = 13, .base = 0x2000_8000, .d = 8, .imm8 = 16, .double = true }, .expect = .{ .start = 0x2000_7FC0, .words = 16, .first = 16, .wback = 0x2000_7FC0 } },
    .{ .encoding = "VPUSH.F32 T2", .name = "S16 to S31 below SP", .input = .{ .p = 1, .u = 0, .w = 1, .rn = 13, .base = 0x2000_8000, .d = 16, .imm8 = 16, .double = false }, .expect = .{ .start = 0x2000_7FC0, .words = 16, .first = 16, .wback = 0x2000_7FC0 } },
    .{ .encoding = "VPOP.F64 T1", .name = "D8 to D15 from SP", .input = .{ .p = 0, .u = 1, .w = 1, .rn = 13, .base = 0x2000_8000, .d = 8, .imm8 = 16, .double = true }, .expect = .{ .start = 0x2000_8000, .words = 16, .first = 16, .wback = 0x2000_8040 } },
    .{ .encoding = "VPOP.F32 T2", .name = "one S register", .input = .{ .p = 0, .u = 1, .w = 1, .rn = 13, .base = 0x2000_8000, .d = 0, .imm8 = 1, .double = false }, .expect = .{ .start = 0x2000_8000, .words = 1, .first = 0, .wback = 0x2000_8004 } },
};

pub const single = [_]One{
    .{ .encoding = "VLDR.F64 T1", .name = "a non-PC base is not aligned", .input = .{ .u = 1, .rn = 1, .base = 0x2000_1001, .d = 1, .imm8 = 2, .double = true }, .expect = .{ .start = 0x2000_1009, .words = 2, .first = 2 } },
    .{ .encoding = "VLDR.F64 T1", .name = "the literal form aligns PC", .input = .{ .u = 0, .rn = 15, .base = 0x0000_1002, .d = 0, .imm8 = 1, .double = true }, .expect = .{ .start = 0x0000_0FFC, .words = 2, .first = 0 } },
    .{ .encoding = "VLDR.F64 T1", .name = "D16 does not exist", .input = .{ .u = 1, .rn = 1, .base = 0x2000_1000, .d = 16, .imm8 = 0, .double = true }, .expect = .{ .fault = .unpredictable } },
    .{ .encoding = "VLDR.F32 T2", .name = "the largest offset into S31", .input = .{ .u = 1, .rn = 0, .base = 0x0000_0100, .d = 31, .imm8 = 255, .double = false }, .expect = .{ .start = 0x0000_04FC, .words = 1, .first = 31 } },
    .{ .encoding = "VLDR.F32 T2", .name = "the literal form with no offset", .input = .{ .u = 1, .rn = 15, .base = 0x0000_0803, .d = 0, .imm8 = 0, .double = false }, .expect = .{ .start = 0x0000_0800, .words = 1, .first = 0 } },
    .{ .encoding = "VSTR.F64 T1", .name = "a subtracted offset", .input = .{ .u = 0, .rn = 2, .base = 0x0000_2000, .d = 1, .imm8 = 4, .double = true, .store = true }, .expect = .{ .start = 0x0000_1FF0, .words = 2, .first = 2 } },
    .{ .encoding = "VSTR.F32 T2", .name = "an added offset", .input = .{ .u = 1, .rn = 2, .base = 0x0000_2000, .d = 7, .imm8 = 1, .double = false, .store = true }, .expect = .{ .start = 0x0000_2004, .words = 1, .first = 7 } },
    .{ .encoding = "VSTR.F32 T2", .name = "a PC base", .input = .{ .u = 1, .rn = 15, .base = 0x0000_2000, .d = 0, .imm8 = 0, .double = false, .store = true }, .expect = .{ .fault = .unpredictable } },
};

pub const claimed = [_][]const u8{
    "VLDM.F64 T1",
    "VLDM.F32 T2",
    "VSTM.F64 T1",
    "VSTM.F32 T2",
    "VPUSH.F64 T1",
    "VPUSH.F32 T2",
    "VPOP.F64 T1",
    "VPOP.F32 T2",
    "VLDR.F64 T1",
    "VLDR.F32 T2",
    "VSTR.F64 T1",
    "VSTR.F32 T2",
};

pub const covered = vector.encodingsOf(transfer.Multiple, transfer.Plan, &multiple) ++
    vector.encodingsOf(transfer.Single, transfer.Plan, &single);

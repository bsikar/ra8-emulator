//! Conformance vectors for the MVE integer lane arithmetic in int.zig,
//! worked from the VADD, VSUB, VMUL, VQADD, VQSUB, VABD, VMAX, VMIN, VHADD,
//! VRHADD and VHSUB pseudocode
//! in the Arm ARM (DDI0553). The operands mix the lane edges: zero, one,
//! all ones, and the signed minimum and maximum of each width.
const defs = @import("types.zig");

const a = defs.a;
const b = defs.b;
const c = defs.c;
const VPlain = defs.VPlain;
const VSat = defs.VSat;

const int = defs.int;
const vector = defs.vector;
pub const Operands = defs.Operands;
pub const PairCase = defs.PairCase;

pub const add = [_]VPlain{
    .{
        .encoding = "VADD (vector) T1",
        .name = "i8 wraps",
        .input = .{ .a = a, .b = b, .size = .byte },
        .expect = 0x7FFFFF00_0100FE01_FF00FF00,
    },
    .{
        .encoding = "VADD (vector) T1",
        .name = "i8 edges",
        .input = .{ .a = a, .b = c, .size = .byte },
        .expect = 0x80010002_7F02FF03_FFFD7E7D_7EFE8001,
    },
    .{
        .encoding = "VADD (vector) T1",
        .name = "i16",
        .input = .{ .a = a, .b = b, .size = .half },
        .expect = 0x7FFF0000_0200FF01_00000000,
    },
    .{
        .encoding = "VADD (vector) T1",
        .name = "i32",
        .input = .{ .a = a, .b = c, .size = .word },
        .expect = 0x80010002_80030003_00FE7F7D_7FFE8001,
    },
};

pub const sub = [_]VPlain{
    .{
        .encoding = "VSUB (vector) T1",
        .name = "i8",
        .input = .{ .a = a, .b = c, .size = .byte },
        .expect = 0x80FF00FE_7FFCFFFB_01018083_80008001,
    },
    .{
        .encoding = "VSUB (vector) T1",
        .name = "i32 wraps",
        .input = .{ .a = a, .b = b, .size = .word },
        .expect = 0x7FFFFFFE_FFFDFFFF_FFFD0002,
    },
};

pub const mul = [_]VPlain{
    .{
        .encoding = "VMUL (vector) T1",
        .name = "i8 low byte",
        .input = .{ .a = a, .b = c, .size = .byte },
        .expect = 0xFD00FC_00028180_81010000,
    },
    .{
        .encoding = "VMUL (vector) T1",
        .name = "i16 low half",
        .input = .{ .a = a, .b = c, .size = .half },
        .expect = 0x80000000_7FFDFFFC_FE028180_80018000,
    },
    .{
        .encoding = "VMUL (vector) T1",
        .name = "i32 low word",
        .input = .{ .a = a, .b = b, .size = .word },
        .expect = 0x7FFFFFFF_407FBF80_0002FFFF,
    },
};

pub const qadd = [_]VSat{
    .{
        .encoding = "VQADD (vector) T1",
        .name = "s8 clamps",
        .input = .{ .a = a, .b = b, .size = .byte },
        .expect = .{ .value = 0x80000000_7FFFFF00_01007F80_FF00FF00, .saturated = true },
    },
    .{
        .encoding = "VQADD (vector) T1",
        .name = "s16 clamps",
        .input = .{ .a = a, .b = c, .size = .half },
        .expect = .{ .value = 0x80010002_7FFF0003_00FD7F7D_7FFE8001, .saturated = true },
    },
    .{
        .encoding = "VQADD (vector) T1",
        .name = "u32 clamps",
        .input = .{ .a = a, .b = b, .size = .word, .unsigned = true },
        .expect = .{ .value = 0xFFFFFFFF_80000000_0200FF01_FFFFFFFF, .saturated = true },
    },
    .{
        .encoding = "VQADD (vector) T1",
        .name = "s32 doubling",
        .input = .{ .a = c, .b = c, .size = .word },
        .expect = .{ .value = 0x20004_00060008_FFFDFFFA_7FFFFFFF, .saturated = true },
    },
};

pub const qsub = [_]VSat{
    .{
        .encoding = "VQSUB (vector) T1",
        .name = "s8 in range",
        .input = .{ .a = a, .b = b, .size = .byte },
        .expect = .{ .value = 0x7FFFFFFE_FFFE00FF_FFFE0102, .saturated = false },
    },
    .{
        .encoding = "VQSUB (vector) T1",
        .name = "u16 floors at 0",
        .input = .{ .a = a, .b = c, .size = .half, .unsigned = true },
        .expect = .{ .value = 0x7FFF0000_7FFCFFFB_00000000_80000000, .saturated = true },
    },
    .{
        .encoding = "VQSUB (vector) T1",
        .name = "s32 clamps",
        .input = .{ .a = a, .b = c, .size = .word },
        .expect = .{ .value = 0x80000000_7FFCFFFB_01007F83_80000000, .saturated = true },
    },
    .{
        .encoding = "VQSUB (vector) T1",
        .name = "u8 x - x",
        .input = .{ .a = c, .b = c, .size = .byte, .unsigned = true },
        .expect = .{ .value = 0, .saturated = false },
    },
};

const pair_01 = @import("pair_01.zig");

pub const pair = pair_01.values;

pub const claimed = [_][]const u8{
    "VADD (vector) T1",
    "VSUB (vector) T1",
    "VMUL (vector) T1",
    "VQADD (vector) T1",
    "VQSUB (vector) T1",
    "VABD (vector) T1",
    "VMAX T1",
    "VMIN T1",
    "VHADD (vector) T1",
    "VRHADD T1",
    "VHSUB (vector) T1",
};

pub const covered = vector.encodingsOf(Operands, u128, &add) ++
    vector.encodingsOf(Operands, u128, &sub) ++
    vector.encodingsOf(Operands, u128, &mul) ++
    vector.encodingsOf(Operands, int.Sat, &qadd) ++
    vector.encodingsOf(Operands, int.Sat, &qsub) ++
    vector.encodingsOf(PairCase, u128, &pair);

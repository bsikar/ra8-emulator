//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const a = defs.a;
const d = defs.d;
const m = defs.m;
const VNarrow = defs.VNarrow;

pub const values = [_]VNarrow{
    .{
        .encoding = "VMOVN T1",
        .name = "i16 bottom",
        .input = .{ .d = d, .m = a, .size = .byte, .half = .bottom, .spec = .{} },
        .expect = .{ .value = 0x11003300_55FF77FF_99FFBB80_DDFFFF01, .saturated = false },
    },
    .{
        .encoding = "VMOVN T1",
        .name = "i32 top",
        .input = .{ .d = d, .m = a, .size = .half, .half = .top, .spec = .{} },
        .expect = .{ .value = 0x00003344_FFFF7788_7F80BBCC_0001FF00, .saturated = false },
    },
    .{
        .encoding = "VQMOVN T1",
        .name = "s16 bottom",
        .input = .{ .d = d, .m = a, .size = .byte, .half = .bottom, .spec = .{ .saturate = true } },
        .expect = .{ .value = 0x11803300_557F77FF_997FBB7F_DDFFFF01, .saturated = true },
    },
    .{
        .encoding = "VQMOVN T1",
        .name = "u32 top",
        .input = .{
            .d = d,
            .m = a,
            .size = .half,
            .half = .top,
            .spec = .{ .saturate = true, .in_unsigned = true, .out_unsigned = true },
        },
        .expect = .{ .value = 0xFFFF3344_FFFF7788_FFFFBBCC_FFFFFF00, .saturated = true },
    },
    .{
        .encoding = "VQMOVUN T1",
        .name = "s16 top",
        .input = .{
            .d = d,
            .m = a,
            .size = .byte,
            .half = .top,
            .spec = .{ .saturate = true, .out_unsigned = true },
        },
        .expect = .{ .value = 0x00220044_FF660088_FFAAFFCC_00EE0100, .saturated = true },
    },
    .{
        .encoding = "VQMOVUN T1",
        .name = "s32 bottom",
        .input = .{
            .d = d,
            .m = m,
            .size = .half,
            .half = .bottom,
            .spec = .{ .saturate = true, .out_unsigned = true },
        },
        .expect = .{ .value = 0x11220000_5566FFFF_99AA0000_DDEE0080, .saturated = true },
    },
    .{
        .encoding = "VSHRN T1",
        .name = "i16 #4 bottom",
        .input = .{ .d = d, .m = a, .size = .byte, .half = .bottom, .spec = .{ .shift = 4 } },
        .expect = .{ .value = 0x11003300_55FF77FF_990FBBF8_DDFFFF00, .saturated = false },
    },
    .{
        .encoding = "VSHRN T1",
        .name = "i32 #16 top",
        .input = .{ .d = d, .m = m, .size = .half, .half = .top, .spec = .{ .shift = 16 } },
        .expect = .{ .value = 0xFFFF3344_00017788_FFFFBBCC_0000FF00, .saturated = false },
    },
    .{
        .encoding = "VRSHRN T1",
        .name = "i16 #1 top",
        .input = .{
            .d = d,
            .m = a,
            .size = .byte,
            .half = .top,
            .spec = .{ .shift = 1, .round = true },
        },
        .expect = .{ .value = 0x00220044_00660088_80AAC0CC_00EE0100, .saturated = false },
    },
    .{
        .encoding = "VRSHRN T1",
        .name = "i32 #8 bottom",
        .input = .{
            .d = d,
            .m = m,
            .size = .half,
            .half = .bottom,
            .spec = .{ .shift = 8, .round = true },
        },
        .expect = .{ .value = 0x1122FF80_55660180_99AAFFFF_DDEE0001, .saturated = false },
    },
    .{
        .encoding = "VQSHRN T1",
        .name = "s16 #1 bottom",
        .input = .{
            .d = d,
            .m = a,
            .size = .byte,
            .half = .bottom,
            .spec = .{ .shift = 1, .saturate = true },
        },
        .expect = .{ .value = 0x11803300_557F77FF_997FBB7F_DDFFFF00, .saturated = true },
    },
    .{
        .encoding = "VQSHRN T1",
        .name = "u32 #4 top",
        .input = .{
            .d = d,
            .m = m,
            .size = .half,
            .half = .top,
            .spec = .{ .shift = 4, .saturate = true, .in_unsigned = true, .out_unsigned = true },
        },
        .expect = .{ .value = 0xFFFF3344_17FF7788_FFFFBBCC_0008FF00, .saturated = true },
    },
    .{
        .encoding = "VQRSHRN T1",
        .name = "s32 #8 top",
        .input = .{
            .d = d,
            .m = m,
            .size = .half,
            .half = .top,
            .spec = .{ .shift = 8, .round = true, .saturate = true },
        },
        .expect = .{ .value = 0xFF803344_01807788_FFFFBBCC_0001FF00, .saturated = false },
    },
};

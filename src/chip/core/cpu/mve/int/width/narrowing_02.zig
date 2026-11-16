//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const a = defs.a;
const d = defs.d;
const m = defs.m;
const VNarrow = defs.VNarrow;

pub const values = [_]VNarrow{
    .{
        .encoding = "VQRSHRN T1",
        .name = "u16 #7 bottom",
        .input = .{
            .d = d,
            .m = a,
            .size = .byte,
            .half = .bottom,
            .spec = .{
                .shift = 7,
                .round = true,
                .saturate = true,
                .in_unsigned = true,
                .out_unsigned = true,
            },
        },
        .expect = .{ .value = 0x11FF3300_55FF77FF_9902BBFF_DDFFFF00, .saturated = true },
    },
    .{
        .encoding = "VQSHRUN T1",
        .name = "s16 #2 bottom",
        .input = .{
            .d = d,
            .m = a,
            .size = .byte,
            .half = .bottom,
            .spec = .{ .shift = 2, .saturate = true, .out_unsigned = true },
        },
        .expect = .{ .value = 0x11003300_55FF7700_993FBBFF_DD00FF00, .saturated = true },
    },
    .{
        .encoding = "VQSHRUN T1",
        .name = "s32 #1 top",
        .input = .{
            .d = d,
            .m = m,
            .size = .half,
            .half = .top,
            .spec = .{ .shift = 1, .saturate = true, .out_unsigned = true },
        },
        .expect = .{ .value = 0x00003344_BFFF7788_0000BBCC_0040FF00, .saturated = true },
    },
};

//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const a = defs.a;
const b = defs.b;
const c = defs.c;
const VHigh = defs.VHigh;

pub const values = [_]VHigh{
    .{
        .encoding = "VMULH T1",
        .name = "s8",
        .input = .{ .a = a, .b = b, .size = .byte, .high = .{} },
        .expect = .{ .value = 0x40000000_000000FF_00FF3F3F_00FF00FF, .saturated = false },
    },
    .{
        .encoding = "VMULH T1",
        .name = "u16",
        .input = .{ .a = a, .b = c, .size = .half, .high = .{ .unsigned = true } },
        .expect = .{ .value = 0x00010003_00FE7F7E_7FFE0000, .saturated = false },
    },
    .{
        .encoding = "VMULH T1",
        .name = "s32",
        .input = .{ .a = a, .b = c, .size = .word, .high = .{} },
        .expect = .{ .value = 0xFFFF7FFF_00018001_FFFFFF00_FFFF8000, .saturated = false },
    },
    .{
        .encoding = "VRMULH T1",
        .name = "s16",
        .input = .{ .a = a, .b = c, .size = .half, .high = .{ .round = true } },
        .expect = .{ .value = 0x00010000_0000FFFF_00000000, .saturated = false },
    },
    .{
        .encoding = "VRMULH T1",
        .name = "u8",
        .input = .{ .a = a, .b = b, .size = .byte, .high = .{ .unsigned = true, .round = true } },
        .expect = .{ .value = 0x40000000_00000001_00013F41_00010001, .saturated = false },
    },
    .{
        .encoding = "VRMULH T1",
        .name = "s32",
        .input = .{ .a = a, .b = b, .size = .word, .high = .{ .round = true } },
        .expect = .{ .value = 0x40000000_00000000_000100FE_FFFFFFFE, .saturated = false },
    },
    .{
        .encoding = "VQDMULH T1",
        .name = "s8",
        .input = .{ .a = a, .b = b, .size = .byte, .high = .{ .double = true } },
        .expect = .{ .value = 0x7F000000_000000FF_00FF7E7F_00FF00FF, .saturated = true },
    },
    .{
        .encoding = "VQDMULH T1",
        .name = "s16",
        .input = .{ .a = a, .b = c, .size = .half, .high = .{ .double = true } },
        .expect = .{ .value = 0xFFFF0000_0002FFFF_FFFFFFFD_FFFFFFFF, .saturated = false },
    },
    .{
        .encoding = "VQDMULH T1",
        .name = "s32",
        .input = .{ .a = a, .b = b, .size = .word, .high = .{ .double = true } },
        .expect = .{ .value = 0x7FFFFFFF_00000000_000201FC_FFFFFFFC, .saturated = true },
    },
    .{
        .encoding = "VQRDMULH T1",
        .name = "s16",
        .input = .{ .a = a, .b = c, .size = .half, .high = .{ .round = true, .double = true } },
        .expect = .{ .value = 0xFFFF0000_00030000_0000FFFD_FFFFFFFF, .saturated = false },
    },
    .{
        .encoding = "VQRDMULH T1",
        .name = "s8",
        .input = .{ .a = a, .b = c, .size = .byte, .high = .{ .round = true, .double = true } },
        .expect = .{ .value = 0x0000FF03_FF000000, .saturated = false },
    },
    .{
        .encoding = "VQRDMULH T1",
        .name = "s32",
        .input = .{ .a = c, .b = c, .size = .word, .high = .{ .round = true, .double = true } },
        .expect = .{ .value = 0x00000002_00000012_00000002_7FFF0001, .saturated = false },
    },
};

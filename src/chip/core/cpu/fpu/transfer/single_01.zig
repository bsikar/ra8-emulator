//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const One = defs.One;

pub const values = [_]One{
    .{
        .encoding = "VLDR",
        .name = "a non-PC base is not aligned",
        .input = .{ .u = 1, .rn = 1, .base = 0x2000_1001, .d = 1, .imm8 = 2, .double = true },
        .expect = .{ .start = 0x2000_1009, .words = 2, .first = 2 },
    },
    .{
        .encoding = "VLDR",
        .name = "the literal form aligns PC",
        .input = .{ .u = 0, .rn = 15, .base = 0x0000_1002, .d = 0, .imm8 = 1, .double = true },
        .expect = .{ .start = 0x0000_0FFC, .words = 2, .first = 0 },
    },
    .{
        .encoding = "VLDR",
        .name = "D16 does not exist",
        .input = .{ .u = 1, .rn = 1, .base = 0x2000_1000, .d = 16, .imm8 = 0, .double = true },
        .expect = .{ .fault = .unpredictable },
    },
    .{
        .encoding = "VLDR",
        .name = "the largest offset into S31",
        .input = .{ .u = 1, .rn = 0, .base = 0x0000_0100, .d = 31, .imm8 = 255, .double = false },
        .expect = .{ .start = 0x0000_04FC, .words = 1, .first = 31 },
    },
    .{
        .encoding = "VLDR",
        .name = "the literal form with no offset",
        .input = .{ .u = 1, .rn = 15, .base = 0x0000_0803, .d = 0, .imm8 = 0, .double = false },
        .expect = .{ .start = 0x0000_0800, .words = 1, .first = 0 },
    },
    .{
        .encoding = "VSTR",
        .name = "a subtracted offset",
        .input = .{
            .u = 0,
            .rn = 2,
            .base = 0x0000_2000,
            .d = 1,
            .imm8 = 4,
            .double = true,
            .store = true,
        },
        .expect = .{ .start = 0x0000_1FF0, .words = 2, .first = 2 },
    },
    .{
        .encoding = "VSTR",
        .name = "an added offset",
        .input = .{
            .u = 1,
            .rn = 2,
            .base = 0x0000_2000,
            .d = 7,
            .imm8 = 1,
            .double = false,
            .store = true,
        },
        .expect = .{ .start = 0x0000_2004, .words = 1, .first = 7 },
    },
    .{
        .encoding = "VSTR",
        .name = "a PC base",
        .input = .{
            .u = 1,
            .rn = 15,
            .base = 0x0000_2000,
            .d = 0,
            .imm8 = 0,
            .double = false,
            .store = true,
        },
        .expect = .{ .fault = .unpredictable },
    },
};

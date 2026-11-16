//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vcmp.u32 hi",
        .{
            .hw1 = 0xFE23,
            .hw2 = 0x0F85,
            .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF,
            .qm = 0x00000001_12345678_7FFFFFFF_80000000,
        },
        .{ .vpr = 0x0000F0F0 },
    ),
    vec(
        "vcmp.s32 ge",
        .{
            .hw1 = 0xFE23,
            .hw2 = 0x1F04,
            .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF,
            .qm = 0x00000001_12345678_7FFFFFFF_80000000,
        },
        .{ .vpr = 0x00000F0F },
    ),
    vec(
        "vcmp.s32 lt",
        .{
            .hw1 = 0xFE23,
            .hw2 = 0x1F84,
            .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF,
            .qm = 0x00000001_12345678_7FFFFFFF_80000000,
        },
        .{ .vpr = 0x0000F0F0 },
    ),
    vec(
        "vcmp.s32 gt",
        .{
            .hw1 = 0xFE23,
            .hw2 = 0x1F05,
            .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF,
            .qm = 0x00000001_12345678_7FFFFFFF_80000000,
        },
        .{ .vpr = 0x0000000F },
    ),
    vec(
        "vcmp.s32 le",
        .{
            .hw1 = 0xFE23,
            .hw2 = 0x1F85,
            .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF,
            .qm = 0x00000001_12345678_7FFFFFFF_80000000,
        },
        .{ .vpr = 0x0000FFF0 },
    ),
    vec(
        "vcmp eq of a register with itself is all ones",
        .{ .hw1 = 0xFE07, .hw2 = 0x0F06, .qn = 0xC040FF00_807F5555_F0901001_FF807F00 },
        .{ .vpr = 0x0000FFFF },
    ),
};

//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vcmp.i16 eq against r2",
        .{ .hw1 = 0xFE13, .hw2 = 0x0F42, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .rm = 0x1234 },
        .{ .vpr = 0x00000F00 },
    ),
    vec(
        "vcmp.i16 ne against r2",
        .{ .hw1 = 0xFE13, .hw2 = 0x0FC2, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .rm = 0x1234 },
        .{ .vpr = 0x0000F0FF },
    ),
    vec(
        "vcmp.u16 cs against r2",
        .{ .hw1 = 0xFE13, .hw2 = 0x0F62, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .rm = 0x1234 },
        .{ .vpr = 0x00003FFC },
    ),
    vec(
        "vcmp.u16 hi against r2",
        .{ .hw1 = 0xFE13, .hw2 = 0x0FE2, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .rm = 0x1234 },
        .{ .vpr = 0x000030FC },
    ),
    vec(
        "vcmp.s16 ge against r2",
        .{ .hw1 = 0xFE13, .hw2 = 0x1F42, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .rm = 0x1234 },
        .{ .vpr = 0x00000F0C },
    ),
    vec(
        "vcmp.s16 lt against r2",
        .{ .hw1 = 0xFE13, .hw2 = 0x1FC2, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .rm = 0x1234 },
        .{ .vpr = 0x0000F0F3 },
    ),
    vec(
        "vcmp.s16 gt against r2",
        .{ .hw1 = 0xFE13, .hw2 = 0x1F62, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .rm = 0x1234 },
        .{ .vpr = 0x0000000C },
    ),
    vec(
        "vcmp.s16 le against r2",
        .{ .hw1 = 0xFE13, .hw2 = 0x1FE2, .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000, .rm = 0x1234 },
        .{ .vpr = 0x0000FFF3 },
    ),
    vec(
        "vcmp.s8 ge against r12 uses its low bits",
        .{ .hw1 = 0xFE03, .hw2 = 0x1F4C, .qn = 0xC040FF00_807F5555_F0901001_FF807F00, .rm = 0xAB80 },
        .{ .vpr = 0x0000FFFF },
    ),
    vec(
        "vcmp.s32 ge against r12 uses its low bits",
        .{ .hw1 = 0xFE23, .hw2 = 0x1F4C, .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF, .rm = 0x80000000 },
        .{ .vpr = 0x0000FFFF },
    ),
    vec(
        "vcmp.i32 ne q7 against lr",
        .{ .hw1 = 0xFE2F, .hw2 = 0x0FCE, .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF, .rm = 0x12345678 },
        .{ .vpr = 0x0000F0FF },
    ),
};

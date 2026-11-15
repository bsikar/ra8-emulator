//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vcmp.i8 eq",
        .{
            .hw1 = 0xFE03,
            .hw2 = 0x0F04,
            .qn = 0xC040FF00_807F5555_F0901001_FF807F00,
            .qm = 0x40C000FF_807F5456_0F101002_FF7F8000,
        },
        .{ .vpr = 0x00000C29 },
    ),
    vec(
        "vcmp.i8 ne",
        .{
            .hw1 = 0xFE03,
            .hw2 = 0x0F84,
            .qn = 0xC040FF00_807F5555_F0901001_FF807F00,
            .qm = 0x40C000FF_807F5456_0F101002_FF7F8000,
        },
        .{ .vpr = 0x0000F3D6 },
    ),
    vec(
        "vcmp.u8 cs",
        .{
            .hw1 = 0xFE03,
            .hw2 = 0x0F05,
            .qn = 0xC040FF00_807F5555_F0901001_FF807F00,
            .qm = 0x40C000FF_807F5456_0F101002_FF7F8000,
        },
        .{ .vpr = 0x0000AEED },
    ),
    vec(
        "vcmp.u8 hi",
        .{
            .hw1 = 0xFE03,
            .hw2 = 0x0F85,
            .qn = 0xC040FF00_807F5555_F0901001_FF807F00,
            .qm = 0x40C000FF_807F5456_0F101002_FF7F8000,
        },
        .{ .vpr = 0x0000A2C4 },
    ),
    vec(
        "vcmp.s8 ge",
        .{
            .hw1 = 0xFE03,
            .hw2 = 0x1F04,
            .qn = 0xC040FF00_807F5555_F0901001_FF807F00,
            .qm = 0x40C000FF_807F5456_0F101002_FF7F8000,
        },
        .{ .vpr = 0x00005E2B },
    ),
    vec(
        "vcmp.s8 lt",
        .{
            .hw1 = 0xFE03,
            .hw2 = 0x1F84,
            .qn = 0xC040FF00_807F5555_F0901001_FF807F00,
            .qm = 0x40C000FF_807F5456_0F101002_FF7F8000,
        },
        .{ .vpr = 0x0000A1D4 },
    ),
    vec(
        "vcmp.s8 gt",
        .{
            .hw1 = 0xFE03,
            .hw2 = 0x1F05,
            .qn = 0xC040FF00_807F5555_F0901001_FF807F00,
            .qm = 0x40C000FF_807F5456_0F101002_FF7F8000,
        },
        .{ .vpr = 0x00005202 },
    ),
    vec(
        "vcmp.s8 le",
        .{
            .hw1 = 0xFE03,
            .hw2 = 0x1F85,
            .qn = 0xC040FF00_807F5555_F0901001_FF807F00,
            .qm = 0x40C000FF_807F5456_0F101002_FF7F8000,
        },
        .{ .vpr = 0x0000ADFD },
    ),
    vec(
        "vcmp.i16 eq",
        .{
            .hw1 = 0xFE13,
            .hw2 = 0x0F04,
            .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000,
            .qm = 0xF0000F00_12351234_00017FFF_80000000,
        },
        .{ .vpr = 0x00000303 },
    ),
    vec(
        "vcmp.i16 ne",
        .{
            .hw1 = 0xFE13,
            .hw2 = 0x0F84,
            .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000,
            .qm = 0xF0000F00_12351234_00017FFF_80000000,
        },
        .{ .vpr = 0x0000FCFC },
    ),
    vec(
        "vcmp.u16 cs",
        .{
            .hw1 = 0xFE13,
            .hw2 = 0x0F05,
            .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000,
            .qm = 0xF0000F00_12351234_00017FFF_80000000,
        },
        .{ .vpr = 0x000033F3 },
    ),
    vec(
        "vcmp.u16 hi",
        .{
            .hw1 = 0xFE13,
            .hw2 = 0x0F85,
            .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000,
            .qm = 0xF0000F00_12351234_00017FFF_80000000,
        },
        .{ .vpr = 0x000030F0 },
    ),
    vec(
        "vcmp.s16 ge",
        .{
            .hw1 = 0xFE13,
            .hw2 = 0x1F04,
            .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000,
            .qm = 0xF0000F00_12351234_00017FFF_80000000,
        },
        .{ .vpr = 0x0000C30F },
    ),
    vec(
        "vcmp.s16 lt",
        .{
            .hw1 = 0xFE13,
            .hw2 = 0x1F84,
            .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000,
            .qm = 0xF0000F00_12351234_00017FFF_80000000,
        },
        .{ .vpr = 0x00003CF0 },
    ),
    vec(
        "vcmp.s16 gt",
        .{
            .hw1 = 0xFE13,
            .hw2 = 0x1F05,
            .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000,
            .qm = 0xF0000F00_12351234_00017FFF_80000000,
        },
        .{ .vpr = 0x0000C00C },
    ),
    vec(
        "vcmp.s16 le",
        .{
            .hw1 = 0xFE13,
            .hw2 = 0x1F85,
            .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000,
            .qm = 0xF0000F00_12351234_00017FFF_80000000,
        },
        .{ .vpr = 0x00003FF3 },
    ),
    vec(
        "vcmp.i32 eq",
        .{
            .hw1 = 0xFE23,
            .hw2 = 0x0F04,
            .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF,
            .qm = 0x00000001_12345678_7FFFFFFF_80000000,
        },
        .{ .vpr = 0x00000F00 },
    ),
    vec(
        "vcmp.i32 ne",
        .{
            .hw1 = 0xFE23,
            .hw2 = 0x0F84,
            .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF,
            .qm = 0x00000001_12345678_7FFFFFFF_80000000,
        },
        .{ .vpr = 0x0000F0FF },
    ),
    vec(
        "vcmp.u32 cs",
        .{
            .hw1 = 0xFE23,
            .hw2 = 0x0F05,
            .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF,
            .qm = 0x00000001_12345678_7FFFFFFF_80000000,
        },
        .{ .vpr = 0x0000FFF0 },
    ),
};

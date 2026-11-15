//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vpt.s32 ge opens a one-instruction block",
        .{
            .hw1 = 0xFE63,
            .hw2 = 0x1F04,
            .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF,
            .qm = 0x00000001_12345678_7FFFFFFF_80000000,
        },
        .{ .vpr = 0x00880F0F },
    ),
    vec(
        "vptt.i16 ne opens a two-instruction block",
        .{
            .hw1 = 0xFE13,
            .hw2 = 0x8F84,
            .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000,
            .qm = 0xF0000F00_12351234_00017FFF_80000000,
        },
        .{ .vpr = 0x0044FCFC },
    ),
    vec(
        "vpteee.u8 hi against r2",
        .{ .hw1 = 0xFE43, .hw2 = 0xCFE2, .qn = 0xC040FF00_807F5555_F0901001_FF807F00, .rm = 0x40 },
        .{ .vpr = 0x00EEAFCE },
    ),
    vec(
        "vpttte.u32 cs keeps mask 0001",
        .{
            .hw1 = 0xFE23,
            .hw2 = 0x2F05,
            .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF,
            .qm = 0x00000001_12345678_7FFFFFFF_80000000,
        },
        .{ .vpr = 0x0011FFF0 },
    ),
    vec(
        "vcmp in a vpt block ands the compare with p0",
        .{
            .hw1 = 0xFE13,
            .hw2 = 0x0F04,
            .qn = 0x0F00F000_12341234_FFFF8000_7FFF0000,
            .qm = 0xF0000F00_12351234_00017FFF_80000000,
            .vpr = 0x00880FF0,
        },
        .{ .vpr = 0x00000300 },
    ),
    vec(
        "the loop tail clears p0 past the tail",
        .{
            .hw1 = 0xFE03,
            .hw2 = 0x1F05,
            .qn = 0xC040FF00_807F5555_F0901001_FF807F00,
            .qm = 0x40C000FF_807F5456_0F101002_FF7F8000,
            .vpr = 0x0000FFFF,
            .ltpsize = 0,
            .lr = 6,
        },
        .{ .vpr = 0x00000002 },
    ),
    vec(
        "eci a0a1 keeps the done beats of p0",
        .{
            .hw1 = 0xFE03,
            .hw2 = 0x1F85,
            .qn = 0xC040FF00_807F5555_F0901001_FF807F00,
            .qm = 0x40C000FF_807F5456_0F101002_FF7F8000,
            .vpr = 0x0000A5A5,
            .it = 0x20,
        },
        .{ .vpr = 0x0000ADA5 },
    ),
    vec(
        "vpt with eci a0a1a2 opens only mask23",
        .{
            .hw1 = 0xFE63,
            .hw2 = 0x0F04,
            .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF,
            .qm = 0x00000001_12345678_7FFFFFFF_80000000,
            .vpr = 0x00001234,
            .it = 0x40,
        },
        .{ .vpr = 0x00800234 },
    ),
    vec(
        "vpt with eci a0 opens both masks",
        .{
            .hw1 = 0xFE63,
            .hw2 = 0x0F04,
            .qn = 0xFFFFFFFF_12345678_80000000_7FFFFFFF,
            .qm = 0x00000001_12345678_7FFFFFFF_80000000,
            .it = 0x10,
        },
        .{ .vpr = 0x00880F00 },
    ),
};

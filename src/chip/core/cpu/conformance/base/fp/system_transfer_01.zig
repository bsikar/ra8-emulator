//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("system_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vmrs r1, fpscr",
        .{ .hw1 = 0xEEF1, .hw2 = 0x1A10, .fpscr = 0x6004_0001 },
        .{ .fpscr = 0x6004_0001, .r1 = 0x6004_0001 },
    ),
    vec(
        "vmrs apsr_nzcv, fpscr keeps q and thumb",
        .{ .hw1 = 0xEEF1, .hw2 = 0xFA10, .fpscr = 0x6004_0001, .xpsr = 0x0900_0000 },
        .{ .fpscr = 0x6004_0001, .xpsr = 0x6900_0000 },
    ),
    vec(
        "vmsr fpscr, r1 keeps implemented bits",
        .{ .hw1 = 0xEEE1, .hw2 = 0x1A10, .r1 = 0xFFFF_FFFF },
        .{ .fpscr = 0xFFCF_009F, .r1 = 0xFFFF_FFFF },
    ),
    vec("vmsr fpscr, r1 with zero", .{ .hw1 = 0xEEE1, .hw2 = 0x1A10, .r1 = 0 }, .{ .fpscr = 0, .r1 = 0 }),
    vec(
        "vmrs r1, vpr",
        .{ .hw1 = 0xEEFC, .hw2 = 0x1A10, .vpr = 0x00AB_1234 },
        .{ .r1 = 0x00AB_1234, .vpr = 0x00AB_1234 },
    ),
    vec(
        "vmsr vpr, r1 drops the top byte",
        .{ .hw1 = 0xEEEC, .hw2 = 0x1A10, .r1 = 0xFFFF_FFFF },
        .{ .r1 = 0xFFFF_FFFF, .vpr = 0x00FF_FFFF },
    ),
    vec("vmrs r1, p0", .{ .hw1 = 0xEEFD, .hw2 = 0x1A10, .vpr = 0x00AB_1234 }, .{ .r1 = 0x1234, .vpr = 0x00AB_1234 }),
    vec(
        "vmsr p0, r1 keeps the masks",
        .{ .hw1 = 0xEEED, .hw2 = 0x1A10, .r1 = 0xDEAD_BEEF, .vpr = 0x00AB_1234 },
        .{ .r1 = 0xDEAD_BEEF, .vpr = 0x00AB_BEEF },
    ),
    vec(
        "vmrs r1, fpscr_nzcvqc",
        .{ .hw1 = 0xEEF2, .hw2 = 0x1A10, .fpscr = 0x6804_0001 },
        .{ .fpscr = 0x6804_0001, .r1 = 0x6800_0000 },
    ),
    vec(
        "vmsr fpscr_nzcvqc, r1",
        .{ .hw1 = 0xEEE2, .hw2 = 0x1A10, .r1 = 0xF800_00FF, .fpscr = 0x0004_0001 },
        .{ .fpscr = 0xF804_0001, .r1 = 0xF800_00FF },
    ),
};

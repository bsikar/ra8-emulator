//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("maxnmv_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vmaxnmv.f32 mixed signs from a zero start",
        .{ .hw1 = 0xEEEE, .hw2 = 0x2F02, .qm = 0xBF000000_40200000_C0400000_3F800000, .rda = 0x0 },
        .{ .rda = 0x40200000, .fpscr = 0x00040000 },
    ),
    vec(
        "vmaxnmv.f32 quiet nan, infinity, flushed denormal",
        .{ .hw1 = 0xEEEE, .hw2 = 0x2F02, .qm = 0x80000000_00000001_FF800000_7FC00001, .rda = 0x3F000000 },
        .{ .rda = 0x3F000000, .fpscr = 0x00040080 },
    ),
    vec(
        "vmaxnmv.f32 snan lane is quietened with ioc then loses",
        .{ .hw1 = 0xEEEE, .hw2 = 0x2F02, .qm = 0x7FC00001_7F800000_3F800000_7F800001, .rda = 0xC0000000 },
        .{ .rda = 0x7F800000, .fpscr = 0x00040001 },
    ),
    vec(
        "vmaxnmv.f16 mixed with extremes",
        .{ .hw1 = 0xFEEE, .hw2 = 0x2F02, .qm = 0x80000001_FBFF7BFF_B8004100_C2003C00, .rda = 0xFFFF3800 },
        .{ .rda = 0x7BFF, .fpscr = 0x00040000 },
    ),
    vec(
        "vmaxnmv.f16 nans and kept denormals",
        .{ .hw1 = 0xFEEE, .hw2 = 0x2F02, .qm = 0xC0007E00_00008001_FC003C00_7C017E01, .rda = 0x8000 },
        .{ .rda = 0x3C00, .fpscr = 0x00040001 },
    ),
    vec(
        "vminnmv.f32 mixed signs from a zero start",
        .{ .hw1 = 0xEEEE, .hw2 = 0x2F82, .qm = 0xBF000000_40200000_C0400000_3F800000, .rda = 0x0 },
        .{ .rda = 0xC0400000, .fpscr = 0x00040000 },
    ),
    vec(
        "vminnmv.f32 quiet nan, infinity, flushed denormal",
        .{ .hw1 = 0xEEEE, .hw2 = 0x2F82, .qm = 0x80000000_00000001_FF800000_7FC00001, .rda = 0x3F000000 },
        .{ .rda = 0xFF800000, .fpscr = 0x00040080 },
    ),
    vec(
        "vminnmv.f32 snan lane is quietened with ioc then loses",
        .{ .hw1 = 0xEEEE, .hw2 = 0x2F82, .qm = 0x7FC00001_7F800000_3F800000_7F800001, .rda = 0xC0000000 },
        .{ .rda = 0xC0000000, .fpscr = 0x00040001 },
    ),
    vec(
        "vminnmv.f16 mixed with extremes",
        .{ .hw1 = 0xFEEE, .hw2 = 0x2F82, .qm = 0x80000001_FBFF7BFF_B8004100_C2003C00, .rda = 0xFFFF3800 },
        .{ .rda = 0xFBFF, .fpscr = 0x00040000 },
    ),
    vec(
        "vminnmv.f16 nans and kept denormals",
        .{ .hw1 = 0xFEEE, .hw2 = 0x2F82, .qm = 0xC0007E00_00008001_FC003C00_7C017E01, .rda = 0x8000 },
        .{ .rda = 0xFC00, .fpscr = 0x00040001 },
    ),
    vec(
        "vmaxnmav.f32 mixed signs from a zero start",
        .{ .hw1 = 0xEEEC, .hw2 = 0x2F02, .qm = 0xBF000000_40200000_C0400000_3F800000, .rda = 0x0 },
        .{ .rda = 0x40400000, .fpscr = 0x00040000 },
    ),
    vec(
        "vmaxnmav.f32 quiet nan, infinity, flushed denormal",
        .{ .hw1 = 0xEEEC, .hw2 = 0x2F02, .qm = 0x80000000_00000001_FF800000_7FC00001, .rda = 0x3F000000 },
        .{ .rda = 0x7F800000, .fpscr = 0x00040080 },
    ),
    vec(
        "vmaxnmav.f32 snan lane is quietened with ioc then loses",
        .{ .hw1 = 0xEEEC, .hw2 = 0x2F02, .qm = 0x7FC00001_7F800000_3F800000_7F800001, .rda = 0xC0000000 },
        .{ .rda = 0x7F800000, .fpscr = 0x00040001 },
    ),
    vec(
        "vmaxnmav.f16 mixed with extremes",
        .{ .hw1 = 0xFEEC, .hw2 = 0x2F02, .qm = 0x80000001_FBFF7BFF_B8004100_C2003C00, .rda = 0xFFFF3800 },
        .{ .rda = 0x7BFF, .fpscr = 0x00040000 },
    ),
    vec(
        "vmaxnmav.f16 nans and kept denormals",
        .{ .hw1 = 0xFEEC, .hw2 = 0x2F02, .qm = 0xC0007E00_00008001_FC003C00_7C017E01, .rda = 0x8000 },
        .{ .rda = 0x7C00, .fpscr = 0x00040001 },
    ),
    vec(
        "vminnmav.f32 mixed signs from a zero start",
        .{ .hw1 = 0xEEEC, .hw2 = 0x2F82, .qm = 0xBF000000_40200000_C0400000_3F800000, .rda = 0x0 },
        .{ .rda = 0x0, .fpscr = 0x00040000 },
    ),
    vec(
        "vminnmav.f32 quiet nan, infinity, flushed denormal",
        .{ .hw1 = 0xEEEC, .hw2 = 0x2F82, .qm = 0x80000000_00000001_FF800000_7FC00001, .rda = 0x3F000000 },
        .{ .rda = 0x0, .fpscr = 0x00040080 },
    ),
    vec(
        "vminnmav.f32 snan lane is quietened with ioc then loses",
        .{ .hw1 = 0xEEEC, .hw2 = 0x2F82, .qm = 0x7FC00001_7F800000_3F800000_7F800001, .rda = 0xC0000000 },
        .{ .rda = 0xC0000000, .fpscr = 0x00040001 },
    ),
};

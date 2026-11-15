//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("maxnmv_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vminnmav.f16 mixed with extremes",
        .{ .hw1 = 0xFEEC, .hw2 = 0x2F82, .qm = 0x80000001_FBFF7BFF_B8004100_C2003C00, .rda = 0xFFFF3800 },
        .{ .rda = 0x0, .fpscr = 0x00040000 },
    ),
    vec(
        "vminnmav.f16 nans and kept denormals",
        .{ .hw1 = 0xFEEC, .hw2 = 0x2F82, .qm = 0xC0007E00_00008001_FC003C00_7C017E01, .rda = 0x8000 },
        .{ .rda = 0x8000, .fpscr = 0x00040001 },
    ),
    vec(
        "vmaxnmv.f32 a quiet nan in rda loses to the lanes",
        .{ .hw1 = 0xEEEE, .hw2 = 0x2F02, .qm = 0xBF000000_40200000_C0400000_3F800000, .rda = 0x7FC00001 },
        .{ .rda = 0x40200000, .fpscr = 0x00040000 },
    ),
    vec(
        "vminnmv.f32 an snan in rda is quietened with ioc",
        .{ .hw1 = 0xEEEE, .hw2 = 0x2F82, .qm = 0xBF000000_40200000_C0400000_3F800000, .rda = 0x7F800001 },
        .{ .rda = 0xC0400000, .fpscr = 0x00040001 },
    ),
    vec(
        "vmaxnmav.f32 takes the lane magnitude but keeps a negative rda",
        .{ .hw1 = 0xEEEC, .hw2 = 0x2F02, .qm = 0x80000000_80000000_80000000_80000000, .rda = 0xBF800000 },
        .{ .rda = 0x0, .fpscr = 0x00040000 },
    ),
    vec(
        "vminnmv.f16 ignores the top half of rda and zero-extends",
        .{ .hw1 = 0xFEEE, .hw2 = 0x2F82, .qm = 0x80000001_FBFF7BFF_B8004100_C2003C00, .rda = 0xABCD7C00 },
        .{ .rda = 0xFBFF, .fpscr = 0x00040000 },
    ),
    vec(
        "vmaxnmv.f32 into r12 from q7",
        .{ .hw1 = 0xEEEE, .hw2 = 0xCF0E, .qm = 0xBF000000_40200000_C0400000_3F800000, .rda = 0xFF800000 },
        .{ .rda = 0x40200000, .fpscr = 0x00040000 },
    ),
    vec(
        "vmaxnmv.f32 into lr",
        .{ .hw1 = 0xEEEE, .hw2 = 0xEF02, .qm = 0xBF000000_40200000_C0400000_3F800000, .rda = 0x0 },
        .{ .rda = 0x40200000, .fpscr = 0x00040000 },
    ),
    vec(
        "flags add to the cumulative bits already set",
        .{
            .hw1 = 0xEEEE,
            .hw2 = 0x2F02,
            .qm = 0x7FC00001_7F800000_3F800000_7F800001,
            .rda = 0x0,
            .fpscr = 0x00040010,
        },
        .{ .rda = 0x7F800000, .fpscr = 0x00040011 },
    ),
};

//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("shift_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "qc already set stays set",
        .{
            .hw1 = 0xEF22,
            .hw2 = 0x0454,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0x00000004_00000003_00000002_00000001,
            .qm = 0x00000004_00000003_00000002_00000001,
            .qc = 1,
        },
        .{ .qd = 0x00000040_00000018_00000008_00000002, .qc = 1 },
    ),
};

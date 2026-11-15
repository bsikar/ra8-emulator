//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("pair_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vmax.s16 q7, q6, q5",
        .{
            .hw1 = 0xEF1C,
            .hw2 = 0xE64A,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xEDCB1234_C0004000_0001FFFF_80007FFF,
            .qm = 0x80005678_40004000_FFFF0002_80000001,
        },
        .{ .qd = 0xEDCB5678_40004000_00010002_80007FFF },
    ),
    vec(
        "vabd of a register with itself is zero",
        .{
            .hw1 = 0xFF06,
            .hw2 = 0x6746,
            .qd = 0xDEADBEEF_CAFEF00D_01234567_89ABCDEF,
            .qn = 0xFE023C81_7EAA5500_F010C040_01FF807F,
        },
        .{ .qd = 0x00000000_00000000_00000000_00000000 },
    ),
};

//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("fma_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "qn equal to qm squares each lane into the accumulator",
        .{
            .hw1 = 0xEF08,
            .hw2 = 0x0C58,
            .qd = 0x42C80000_322BCC77_BE800000_3F800000,
            .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000,
        },
        .{ .qd = 0x42C80000_322BCC77_BE800000_3F800000, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "qd equal to qm accumulates onto its own multiplier",
        .{
            .hw1 = 0xEF26,
            .hw2 = 0xAC5A,
            .qd = 0x42C80000_322BCC77_BE800000_3F800000,
            .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000,
        },
        .{ .qd = 0x00000000_00000000_00000000_00000000, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "q7 from q6 and q5 at f16",
        .{
            .hw1 = 0xEF3C,
            .hw2 = 0xEC5A,
            .qd = 0x8000FC00_0002FB53_56401419_B4003C00,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .qm = 0x7C000001_211F5CB0_C70034CD_38004200,
        },
        .{ .qd = 0xFC00FC00_868CFC00_5790A76C_3A00C300, .fpscr = 0x00040014, .vpr = 0x00000000 },
    ),
};

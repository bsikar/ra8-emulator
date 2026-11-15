//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("gather64_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vstrd.64 with qd equal to qm stores its own offsets",
        .{ .hw1 = 0xEC81, .hw2 = 0xAFDA, .base = 0x20000200, .qd = 0x00000022_00000030_00000011_00000018 },
        .{
            .qd = 0x00000000_00000000_00000000_00000000,
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_00000000_00000000,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vstrd.64 the second doubleword overwrites the first",
        .{
            .hw1 = 0xEC81,
            .hw2 = 0x4FD6,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_00000008_00000000_00000008,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000200,
            .mem = .{
                0x8899AABB_CCDDEEFF_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
};

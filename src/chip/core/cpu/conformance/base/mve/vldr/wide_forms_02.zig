//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("wide_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vstrh.32 at an odd address faults unaligned and writes nothing",
        .{ .hw1 = 0xED89, .hw2 = 0x4F00, .base = 0x20000203, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 },
        .{
            .fault = .unaligned,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000203,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vstrb.32 from q7 through r0",
        .{ .hw1 = 0xED80, .hw2 = 0xEF14, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_BBFF4488_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
};

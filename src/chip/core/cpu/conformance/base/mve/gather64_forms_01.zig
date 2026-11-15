//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("gather64_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vldrd.u64 unscaled gathers two doublewords",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x4FD6,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_00000008_00000000_00000018,
        },
        .{
            .qd = 0xFADDC0A3_86694C2F_CAAD9073_56391CFF,
            .rn = 0x20000200,
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
        "vldrd.u64 ignores the odd word of each offset",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x4FD6,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0xFFFFFFFF_00000010_0000DEAD_00000030,
        },
        .{
            .qd = 0xE2C5A88B_6E513417_8265482B_0EF1D4B7,
            .rn = 0x20000200,
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
        "vldrd.u64 uxtw #3 scales each offset by 8",
        .{
            .hw1 = 0xFC94,
            .hw2 = 0x4FD7,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_00000002_00000000_00000007,
        },
        .{
            .qd = 0xE2C5A88B_6E513417_6A4D3013_F6D9BC9F,
            .rn = 0x20000200,
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
        "vldrd.u64 from an sp base into q7, offsets in q0",
        .{
            .hw1 = 0xFC9D,
            .hw2 = 0xEFD0,
            .base = 0x20000210,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_00000000_00000000_00000020,
        },
        .{
            .qd = 0xE2C5A88B_6E513417_8265482B_0EF1D4B7,
            .rn = 0x20000210,
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
        "vldrd.u64 at a word-aligned offset is allowed",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x4FD6,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_0000002C_00000000_00000004,
        },
        .{
            .qd = 0x0EF1D4B7_9A7D6043_86694C2F_12F5D8BB,
            .rn = 0x20000200,
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
        "vldrd.u64 at an odd offset faults unaligned and changes nothing",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x4FD6,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_0000000A_00000000_00000000,
        },
        .{
            .fault = .unaligned,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000200,
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
        "vldrd.u64 whose odd beat runs past the window faults unmapped",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x4FD6,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_3FFFFDFC_00000000_00000000,
        },
        .{
            .fault = .unmapped,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000200,
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
        "vldrd.u64 uxtw #3 offset that wraps past 4 GiB",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x4FD7,
            .base = 0x20000210,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_1FFFFFFF_00000000_20000000,
        },
        .{
            .qd = 0xFADDC0A3_86694C2F_E2C5A88B_6E513417,
            .rn = 0x20000210,
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
        "vstrd.64 unscaled scatters two doublewords",
        .{
            .hw1 = 0xEC81,
            .hw2 = 0x4FD6,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_00000000_00000000_00000028,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_8899AABB_CCDDEEFF,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x11223344_55667788_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vstrd.64 uxtw #3",
        .{
            .hw1 = 0xEC82,
            .hw2 = 0x4FD7,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_00000006_00000000_00000001,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000200,
            .mem = .{
                0x11223344_55667788_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8899AABB_CCDDEEFF,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vstrd.64 faults on the second doubleword and keeps the first",
        .{
            .hw1 = 0xEC81,
            .hw2 = 0x4FD6,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_00000022_00000000_00000010,
        },
        .{
            .fault = .unaligned,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_11223344_55667788,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
};

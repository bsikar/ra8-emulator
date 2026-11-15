//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("gather64_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vpt mask keeps only the upper doubleword of a gather",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x4FD6,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_00000008_00000000_00000018,
            .vpr = 0x0088FF00,
        },
        .{
            .qd = 0xFADDC0A3_86694C2F_00000000_00000000,
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x0000FF00,
        },
    ),
    vec(
        "a doubleword with only its low beat predicated loads one word",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x4FD6,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_00000008_00000000_00000018,
            .vpr = 0x00880F0F,
        },
        .{
            .qd = 0x00000000_86694C2F_00000000_56391CFF,
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000F0F,
        },
    ),
    vec(
        "a doubleword with only its high beat predicated loads one word",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x4FD6,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_00000008_00000000_00000018,
            .vpr = 0x0088F0F0,
        },
        .{
            .qd = 0xFADDC0A3_00000000_CAAD9073_00000000,
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x0000F0F0,
        },
    ),
    vec(
        "an inactive doubleword with a misaligned offset cannot fault",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x4FD6,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_0000000A_00000000_00000018,
            .vpr = 0x008800FF,
        },
        .{
            .qd = 0x00000000_00000000_CAAD9073_56391CFF,
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x000000FF,
        },
    ),
    vec(
        "a scatter with the low beat of each doubleword predicated",
        .{
            .hw1 = 0xEC81,
            .hw2 = 0x4FD6,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_00000008_00000000_00000028,
            .vpr = 0x00880F0F,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_CCDDEEFF_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_55667788_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000F0F,
        },
    ),
    vec(
        "the loop tail on vldrd at ltpsize 3 stops after the first doubleword",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x4FD6,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_00000008_00000000_00000018,
            .lr = 1,
            .fpscr = 0x00030000,
        },
        .{
            .qd = 0x00000000_00000000_CAAD9073_56391CFF,
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
        "the loop tail on vstrd at ltpsize 2 stops after beat 2",
        .{
            .hw1 = 0xEC81,
            .hw2 = 0x4FD6,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_00000008_00000000_00000028,
            .lr = 3,
            .fpscr = 0x00020000,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_CCDDEEFF_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x11223344_55667788_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "eci a0a1 keeps the first doubleword of qd",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x4FD6,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_00000008_00000000_00000018,
            .it = 0x20,
        },
        .{
            .qd = 0xFADDC0A3_86694C2F_11223344_55667788,
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
        "eci a0a1a2 scatters only beat 3",
        .{
            .hw1 = 0xEC81,
            .hw2 = 0x4FD6,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_00000008_00000000_00000028,
            .it = 0x40,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000200,
            .mem = .{
                0x8899AABB_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
};

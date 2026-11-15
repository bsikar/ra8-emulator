//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("imm_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vpt mask keeps word lanes 2 and 3, writeback still moves every base",
        .{
            .hw1 = 0xFDB6,
            .hw2 = 0x5E01,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x20000230_20000204_20000218_20000200,
            .vpr = 0x0088FF00,
        },
        .{
            .qd = 0x8265482B_86694C2F_00000000_00000000,
            .qm = 0x20000234_20000208_2000021C_20000204,
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
        "an inactive lane at an odd base cannot fault",
        .{
            .hw1 = 0xFD96,
            .hw2 = 0x5E00,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x20000208_20000204_20000206_20000200,
            .vpr = 0x0088FF0F,
        },
        .{
            .qd = 0x86694C2F_12F5D8BB_00000000_9E816447,
            .qm = 0x20000208_20000204_20000206_20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x0000FF0F,
        },
    ),
    vec(
        "a doubleword with only its high beat predicated",
        .{
            .hw1 = 0xFD96,
            .hw2 = 0x5F00,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0000BEEF_20000220_0000DEAD_20000200,
            .vpr = 0x0088F0F0,
        },
        .{
            .qd = 0xB295785B_00000000_12F5D8BB_00000000,
            .qm = 0x0000BEEF_20000220_0000DEAD_20000200,
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
        "vstrw.32 with lanes 0 and 3 predicated",
        .{
            .hw1 = 0xFDA6,
            .hw2 = 0x5E01,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x20000230_20000204_20000218_20000200,
            .vpr = 0x0088F00F,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x20000234_20000208_2000021C_20000204,
            .mem = .{
                0xFADDC0A3_86694C2F_55667788_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8899AABB_0EF1D4B7,
            },
            .vpr = 0x0000F00F,
        },
    ),
    vec(
        "the loop tail on vldrw stops after lane 1, writeback moves every base",
        .{
            .hw1 = 0xFDB6,
            .hw2 = 0x5E01,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x20000230_20000204_20000218_20000200,
            .lr = 2,
            .fpscr = 0x00020000,
        },
        .{
            .qd = 0x00000000_00000000_CAAD9073_12F5D8BB,
            .qm = 0x20000234_20000208_2000021C_20000204,
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
        "the loop tail on vstrd stops after the first doubleword",
        .{
            .hw1 = 0xFD86,
            .hw2 = 0x5F00,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0000BEEF_20000220_0000DEAD_20000200,
            .lr = 1,
            .fpscr = 0x00030000,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0000BEEF_20000220_0000DEAD_20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_11223344_55667788,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "eci a0a1 keeps the done beats of qd and of the written-back qm",
        .{
            .hw1 = 0xFDB6,
            .hw2 = 0x5E01,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x20000230_20000204_20000218_20000200,
            .it = 0x20,
        },
        .{
            .qd = 0x8265482B_86694C2F_11223344_55667788,
            .qm = 0x20000234_20000208_20000218_20000200,
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
        "eci a0a1a2 scatters only beat 3 and writes back only its base",
        .{
            .hw1 = 0xFDA6,
            .hw2 = 0x5E01,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x20000230_20000204_20000218_20000200,
            .it = 0x40,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x20000234_20000204_20000218_20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8899AABB_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
};

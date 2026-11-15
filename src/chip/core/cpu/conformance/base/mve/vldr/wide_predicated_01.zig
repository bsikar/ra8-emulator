//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("wide_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vpt mask keeps word lanes 2 and 3 of vldrh.s32",
        .{
            .hw1 = 0xED99,
            .hw2 = 0x4F00,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .vpr = 0x0088FF00,
        },
        .{
            .qd = 0x000012F5_FFFFD8BB_00000000_00000000,
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
        "every other half lane of vldrb.u16 predicated",
        .{
            .hw1 = 0xFD91,
            .hw2 = 0x4E80,
            .base = 0x20000210,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .vpr = 0x00883333,
        },
        .{
            .qd = 0x000000C5_0000008B_00000051_00000017,
            .rn = 0x20000210,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00003333,
        },
    ),
    vec(
        "a half predicated past its first byte is not loaded",
        .{
            .hw1 = 0xED91,
            .hw2 = 0x4E80,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .vpr = 0x0088AAAA,
        },
        .{
            .qd = 0x00000000_00000000_00000000_00000000,
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x0000AAAA,
        },
    ),
    vec(
        "every lane off reaches no memory, so a misaligned base cannot fault",
        .{
            .hw1 = 0xEDB9,
            .hw2 = 0x4F00,
            .base = 0x20000201,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .vpr = 0x00880000,
        },
        .{
            .qd = 0x00000000_00000000_00000000_00000000,
            .rn = 0x20000201,
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
        "vstrb.16 with half lanes 0, 2, 4 and 6 predicated",
        .{
            .hw1 = 0xED81,
            .hw2 = 0x4E80,
            .base = 0x20000220,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .vpr = 0x00883333,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000220,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B2BB78FF_3E440488,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00003333,
        },
    ),
    vec(
        "vstrh.32 with lanes 0 and 3 predicated, writeback still happens",
        .{
            .hw1 = 0xECA9,
            .hw2 = 0x4F04,
            .base = 0x20000210,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .vpr = 0x0088F00F,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000218,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_AABBA88B_6E517788,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x0000F00F,
        },
    ),
    vec(
        "the loop tail on vldrb.s32 stops after lane 2",
        .{
            .hw1 = 0xED91,
            .hw2 = 0x4F00,
            .base = 0x20000210,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .lr = 3,
            .fpscr = 0x00020000,
        },
        .{
            .qd = 0x00000000_00000051_00000034_00000017,
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
        "the loop tail on vstrb.16 stops after lane 5",
        .{
            .hw1 = 0xED81,
            .hw2 = 0x4E80,
            .base = 0x20000230,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .lr = 5,
            .fpscr = 0x00010000,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000230,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_826548FF_22446688,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "eci a0a1 keeps the done beats of qd on vldrb.u16",
        .{
            .hw1 = 0xFCB1,
            .hw2 = 0x4E84,
            .base = 0x20000220,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .it = 0x20,
        },
        .{
            .qd = 0x00B20095_0078005B_11223344_55667788,
            .rn = 0x20000224,
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
        "eci a0a1a2 stores only beat 3 of vstrh.32",
        .{
            .hw1 = 0xED89,
            .hw2 = 0x4F00,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .it = 0x40,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_AABBD8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
};

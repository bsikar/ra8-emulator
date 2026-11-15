//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("vld_il_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vst21.32 with writeback adds 32",
        .{
            .hw1 = 0xFCA1,
            .hw2 = 0x1F20,
            .base = 0x20000200,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
        },
        .{
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
            .rn = 0x20000220,
            .mem = .{
                0x8796A5B4_11223344_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_4B5A6978_CCDDEEFF,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vst20.16 at an odd base faults unaligned and writes nothing",
        .{
            .hw1 = 0xFC81,
            .hw2 = 0x1E80,
            .base = 0x20000201,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
        },
        .{
            .fault = .unaligned,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
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
        "vst40.16 from q0 to q3",
        .{
            .hw1 = 0xFC81,
            .hw2 = 0x1E81,
            .base = 0x20000200,
            .q = .{
                0x8899AABB_CCDDEEFF_11223344_55667788,
                0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0,
                0x13579BDF_2468ACE0_FDB97531_0ECA8642,
                0xA5A5A5A5_5A5A5A5A_C3C3C3C3_3C3C3C3C,
            },
        },
        .{
            .q = .{
                0x8899AABB_CCDDEEFF_11223344_55667788,
                0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0,
                0x13579BDF_2468ACE0_FDB97531_0ECA8642,
                0xA5A5A5A5_5A5A5A5A_C3C3C3C3_3C3C3C3C,
            },
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_3C3C8642_E1F07788,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x5A5A2468_4B5ACCDD_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vst41.8 from q4 to q7",
        .{
            .hw1 = 0xFC82,
            .hw2 = 0x9E21,
            .base = 0x20000200,
            .q = .{
                0x8899AABB_CCDDEEFF_11223344_55667788,
                0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0,
                0x13579BDF_2468ACE0_FDB97531_0ECA8642,
                0xA5A5A5A5_5A5A5A5A_C3C3C3C3_3C3C3C3C,
            },
        },
        .{
            .q = .{
                0x8899AABB_CCDDEEFF_11223344_55667788,
                0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0,
                0x13579BDF_2468ACE0_FDB97531_0ECA8642,
                0xA5A5A5A5_5A5A5A5A_C3C3C3C3_3C3C3C3C,
            },
            .rn = 0x20000200,
            .mem = .{
                0x3C0EC355_3CCAD266_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_A59B2DAA_A5DF3CBB,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vst42.32 from q1 to q4",
        .{
            .hw1 = 0xFC83,
            .hw2 = 0x3F41,
            .base = 0x20000200,
            .q = .{
                0x8899AABB_CCDDEEFF_11223344_55667788,
                0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0,
                0x13579BDF_2468ACE0_FDB97531_0ECA8642,
                0xA5A5A5A5_5A5A5A5A_C3C3C3C3_3C3C3C3C,
            },
        },
        .{
            .q = .{
                0x8899AABB_CCDDEEFF_11223344_55667788,
                0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0,
                0x13579BDF_2468ACE0_FDB97531_0ECA8642,
                0xA5A5A5A5_5A5A5A5A_C3C3C3C3_3C3C3C3C,
            },
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_8796A5B4_11223344,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0xA5A5A5A5_13579BDF_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vst43.16 with writeback adds 64",
        .{
            .hw1 = 0xFCA4,
            .hw2 = 0x1EE1,
            .base = 0x20000200,
            .q = .{
                0x8899AABB_CCDDEEFF_11223344_55667788,
                0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0,
                0x13579BDF_2468ACE0_FDB97531_0ECA8642,
                0xA5A5A5A5_5A5A5A5A_C3C3C3C3_3C3C3C3C,
            },
        },
        .{
            .q = .{
                0x8899AABB_CCDDEEFF_11223344_55667788,
                0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0,
                0x13579BDF_2468ACE0_FDB97531_0ECA8642,
                0xA5A5A5A5_5A5A5A5A_C3C3C3C3_3C3C3C3C,
            },
            .rn = 0x20000240,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xC3C3FDB9_87961122_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_5A5AACE0_6978EEFF,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vst40.32 below the ram faults unmapped",
        .{
            .hw1 = 0xFCA1,
            .hw2 = 0x1F01,
            .base = 0x1FFFFFF0,
            .q = .{
                0x8899AABB_CCDDEEFF_11223344_55667788,
                0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0,
                0x13579BDF_2468ACE0_FDB97531_0ECA8642,
                0xA5A5A5A5_5A5A5A5A_C3C3C3C3_3C3C3C3C,
            },
        },
        .{
            .fault = .unmapped,
            .q = .{
                0x8899AABB_CCDDEEFF_11223344_55667788,
                0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0,
                0x13579BDF_2468ACE0_FDB97531_0ECA8642,
                0xA5A5A5A5_5A5A5A5A_C3C3C3C3_3C3C3C3C,
            },
            .rn = 0x1FFFFFF0,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
};

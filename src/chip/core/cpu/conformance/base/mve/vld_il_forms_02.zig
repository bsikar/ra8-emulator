//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("vld_il_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vld42.32 into q2 to q5",
        .{
            .hw1 = 0xFC94,
            .hw2 = 0x5F41,
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
                0x8899AABB_CCDDEEFF_6E513417_55667788,
                0x0F1E2D3C_4B5A6978_E2C5A88B_C3D2E1F0,
                0xF6D9BC9F_2468ACE0_FDB97531_0ECA8642,
                0x6A4D3013_5A5A5A5A_C3C3C3C3_3C3C3C3C,
            },
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
        "vld43.8 with writeback adds 64",
        .{
            .hw1 = 0xFCB5,
            .hw2 = 0x3E61,
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
                0x8899AABB_CCDD5BE7_73FF3344_55667788,
                0x0F1E2D3C_4B5A7804_901CA5B4_C3D2E1F0,
                0x13579BDF_24689521_AD397531_0ECA8642,
                0xA5A5A5A5_5A5AB23E_CA56C3C3_3C3C3C3C,
            },
            .rn = 0x20000240,
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
        "vld43.32 into q4 to q7",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x9F61,
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
                0x8899AABB_3E2104E7_11223344_55667788,
                0x0F1E2D3C_B295785B_8796A5B4_C3D2E1F0,
                0x13579BDF_2468ACE0_56391CFF_0ECA8642,
                0xA5A5A5A5_5A5A5A5A_CAAD9073_3C3C3C3C,
            },
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
        "vld20.8 at an odd base needs only byte alignment",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x3E00,
            .base = 0x20000201,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
        },
        .{
            .q = .{ 0xCA90561C_CCDDEEFF_11223344_12D89E64, 0xE7AD7339_4B5A6978_8796A5B4_2FF5BB81, 0, 0 },
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
        "vld20.16 at an odd base faults unaligned and changes nothing",
        .{
            .hw1 = 0xFCB1,
            .hw2 = 0x3E80,
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
        "vld41.32 at a halfword base faults unaligned",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x1F21,
            .base = 0x20000202,
            .q = .{
                0x8899AABB_CCDDEEFF_11223344_55667788,
                0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0,
                0x13579BDF_2468ACE0_FDB97531_0ECA8642,
                0xA5A5A5A5_5A5A5A5A_C3C3C3C3_3C3C3C3C,
            },
        },
        .{
            .fault = .unaligned,
            .q = .{
                0x8899AABB_CCDDEEFF_11223344_55667788,
                0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0,
                0x13579BDF_2468ACE0_FDB97531_0ECA8642,
                0xA5A5A5A5_5A5A5A5A_C3C3C3C3_3C3C3C3C,
            },
            .rn = 0x20000202,
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
        "vld40.8 whose beat 2 runs past the ram faults unmapped and changes nothing",
        .{
            .hw1 = 0xFCB1,
            .hw2 = 0x1E01,
            .base = 0x200003E0,
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
            .rn = 0x200003E0,
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
        "vst20.8 from q1 and q2",
        .{
            .hw1 = 0xFC81,
            .hw2 = 0x3E00,
            .base = 0x20000200,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
        },
        .{
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_C355D266_E177F088,
                0x0F881E99_2DAA3CBB_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
};

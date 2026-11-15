//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("vld_il_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "a vpr outside a vpt block leaves vld20 whole and vpr alone",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x1E80,
            .base = 0x20000200,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
            .vpr = 0x00005A5A,
        },
        .{
            .q = .{ 0x90731CFF_CCDDEEFF_11223344_D8BB6447, 0xCAAD5639_4B5A6978_8796A5B4_12F59E81, 0, 0 },
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00005A5A,
        },
    ),
    vec(
        "eci a0 skips beat 0 of vld20",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x3E00,
            .base = 0x20000200,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
            .it = 0x10,
        },
        .{
            .q = .{ 0xAD7339FF_CCDDEEFF_11223344_F5BB7788, 0xCA90561C_4B5A6978_8796A5B4_12D8E1F0, 0, 0 },
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
        "eci a0a1 skips beats 0 and 1 of vld41 and still writes back",
        .{
            .hw1 = 0xFCB1,
            .hw2 = 0x1EA1,
            .base = 0x20000200,
            .q = .{
                0x8899AABB_CCDDEEFF_11223344_55667788,
                0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0,
                0x13579BDF_2468ACE0_FDB97531_0ECA8642,
                0xA5A5A5A5_5A5A5A5A_C3C3C3C3_3C3C3C3C,
            },
            .it = 0x20,
        },
        .{
            .q = .{
                0x8899D4B7_CCDDEEFF_11223344_55667788,
                0x0F1E0EF1_4B5A6978_8796A5B4_C3D2E1F0,
                0x1357482B_2468ACE0_FDB97531_0ECA8642,
                0xA5A58265_5A5A5A5A_C3C3C3C3_3C3C3C3C,
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
        "eci a0a1a2 stores only beat 3 of vst42",
        .{
            .hw1 = 0xFC81,
            .hw2 = 0x1F41,
            .base = 0x20000200,
            .q = .{
                0x8899AABB_CCDDEEFF_11223344_55667788,
                0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0,
                0x13579BDF_2468ACE0_FDB97531_0ECA8642,
                0xA5A5A5A5_5A5A5A5A_C3C3C3C3_3C3C3C3C,
            },
            .it = 0x40,
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
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0xA5A5A5A5_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "eci a0a1 skips a beat that would fault",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x3E00,
            .base = 0x200003E8,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
            .it = 0x20,
        },
        .{
            .fault = .unmapped,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
            .rn = 0x200003E8,
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

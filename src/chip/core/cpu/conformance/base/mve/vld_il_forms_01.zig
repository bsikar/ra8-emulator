//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("vld_il_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vld20.8 into q1 and q2",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x3E00,
            .base = 0x20000200,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
        },
        .{
            .q = .{ 0xAD7339FF_CCDDEEFF_11223344_F5BB8147, 0xCA90561C_4B5A6978_8796A5B4_12D89E64, 0, 0 },
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
        "vld21.8 into q1 and q2",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x3E20,
            .base = 0x20000200,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
        },
        .{
            .q = .{ 0x8899AABB_C58B5117_DDA3692F_55667788, 0x0F1E2D3C_E2A86E34_FAC0864C_C3D2E1F0, 0, 0 },
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
        "vld20.16 into q0 and q1",
        .{
            .hw1 = 0xFC92,
            .hw2 = 0x1E80,
            .base = 0x20000200,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
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
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vld21.16 with writeback adds 32",
        .{
            .hw1 = 0xFCB2,
            .hw2 = 0x1EA0,
            .base = 0x20000200,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
        },
        .{
            .q = .{ 0x8899AABB_A88B3417_C0A34C2F_55667788, 0x0F1E2D3C_E2C56E51_FADD8669_C3D2E1F0, 0, 0 },
            .rn = 0x20000220,
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
        "vld20.32 into q6 and q7",
        .{
            .hw1 = 0xFC93,
            .hw2 = 0xDF00,
            .base = 0x20000200,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
        },
        .{
            .q = .{ 0x56391CFF_CCDDEEFF_11223344_9E816447, 0xCAAD9073_4B5A6978_8796A5B4_12F5D8BB, 0, 0 },
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
        "vld21.32 from an sp base",
        .{
            .hw1 = 0xFC9D,
            .hw2 = 0x5F20,
            .base = 0x20000210,
            .q = .{ 0x8899AABB_CCDDEEFF_11223344_55667788, 0x0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0, 0, 0 },
        },
        .{
            .q = .{ 0x8899AABB_3E2104E7_56391CFF_55667788, 0x0F1E2D3C_B295785B_CAAD9073_C3D2E1F0, 0, 0 },
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
        "vld40.8 into q4 to q7",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x9E01,
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
                0x8899AABB_43CFEEFF_11223344_5566BB47,
                0x0F1E2D3C_60EC6978_8796A5B4_C3D2D864,
                0x13579BDF_7D09ACE0_FDB97531_0ECAF581,
                0xA5A5A5A5_9A265A5A_C3C3C3C3_3C3C129E,
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
        "vld41.16 into q0 to q3",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x1EA1,
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
                0x8899D4B7_CCDDEEFF_11223344_4C2F7788,
                0x0F1E0EF1_4B5A6978_8796A5B4_8669E1F0,
                0x1357482B_2468ACE0_FDB97531_C0A38642,
                0xA5A58265_5A5A5A5A_C3C3C3C3_FADD3C3C,
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
};

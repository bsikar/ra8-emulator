//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vldrb.u8 gathers bytes at byte offsets",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x4E06,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0B14080C_061E053F_0409020F_01070300,
        },
        .{
            .qd = 0x868B2FA3_F5ADD86A_BB4C81FA_64129E47,
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
        "vldrb.s16 sign-extends each byte",
        .{
            .hw1 = 0xEC91,
            .hw2 = 0x4E86,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0008003E_001E0001_000F0003_00070000,
        },
        .{
            .qd = 0x002F004D_FFAD0064_FFFAFF9E_00120047,
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
        "vldrb.u16 zero-extends each byte",
        .{
            .hw1 = 0xFC94,
            .hw2 = 0x4E86,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0008003E_001E0001_000F0003_00070000,
        },
        .{
            .qd = 0x002F004D_00AD0064_00FA009E_00120047,
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
        "vldrb.s32 reads the offset at word width",
        .{
            .hw1 = 0xEC91,
            .hw2 = 0x4F06,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0000003B_00000006_0000000D_00000000,
        },
        .{
            .qd = 0xFFFFFFF6_FFFFFFF5_FFFFFFC0_00000047,
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
        "vldrb.u32 from an sp base",
        .{
            .hw1 = 0xFC9D,
            .hw2 = 0x4F06,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0000003B_00000006_0000000D_00000000,
        },
        .{
            .qd = 0x000000F6_000000F5_000000C0_00000047,
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
        "vldrh.u16 unscaled at even offsets",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x4E96,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0008000E_000A0006_001E0002_00040000,
        },
        .{
            .qd = 0x4C2FFADD_866912F5_CAAD9E81_D8BB6447,
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
        "vldrh.u16 uxtw #1 scales each offset by 2",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x4E97,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00040009_00070003_000F0001_00020000,
        },
        .{
            .qd = 0x4C2F6E51_FADD12F5_CAAD9E81_D8BB6447,
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
        "vldrh.s32 unscaled sign-extends",
        .{
            .hw1 = 0xEC92,
            .hw2 = 0x4F16,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0000003C_00000004_0000000C_00000000,
        },
        .{
            .qd = 0x00003013_FFFFD8BB_FFFFC0A3_00006447,
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
        "vldrh.u32 uxtw #1",
        .{
            .hw1 = 0xFC92,
            .hw2 = 0x4F17,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0000001F_00000002_00000006_00000000,
        },
        .{
            .qd = 0x00006A4D_0000D8BB_0000C0A3_00006447,
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
        "vldrw.u32 unscaled",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x4F46,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0000003C_00000004_0000000C_00000000,
        },
        .{
            .qd = 0x6A4D3013_12F5D8BB_FADDC0A3_9E816447,
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
        "vldrw.u32 uxtw #2 into q7 from r12, offsets in q0",
        .{
            .hw1 = 0xFC9C,
            .hw2 = 0xEF41,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000007_0000000F_00000000_00000003,
        },
        .{
            .qd = 0xCAAD9073_6A4D3013_9E816447_FADDC0A3,
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

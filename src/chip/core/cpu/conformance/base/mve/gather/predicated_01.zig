//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vpt mask keeps word lanes 2 and 3 of vldrw",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x4F46,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0000003C_00000004_0000000C_00000000,
            .vpr = 0x0088FF00,
        },
        .{
            .qd = 0x6A4D3013_12F5D8BB_00000000_00000000,
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
        "every other byte lane of vldrb.u8 predicated",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x4E06,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0B14080C_061E053F_0409020F_01070300,
            .vpr = 0x00885555,
        },
        .{
            .qd = 0x008B00A3_00AD006A_004C00FA_00120047,
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00005555,
        },
    ),
    vec(
        "a half predicated past its first byte is not loaded",
        .{
            .hw1 = 0xEC91,
            .hw2 = 0x4E86,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0008003E_001E0001_000F0003_00070000,
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
        "an inactive lane with a misaligned offset cannot fault",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x4F46,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000008_00000009_00000004_00000000,
            .vpr = 0x0088F0FF,
        },
        .{
            .qd = 0x86694C2F_00000000_12F5D8BB_9E816447,
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x0000F0FF,
        },
    ),
    vec(
        "vstrh.16 with half lanes 0, 2, 4 and 6 predicated",
        .{
            .hw1 = 0xEC81,
            .hw2 = 0x4E96,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0008000E_000A0006_001E0002_00040000,
            .vpr = 0x00883333,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000200,
            .mem = .{
                0xAABBC0A3_86694C2F_EEFFD8BB_33447788,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00003333,
        },
    ),
    vec(
        "the loop tail on vldrh.s32 stops after lane 2",
        .{
            .hw1 = 0xEC91,
            .hw2 = 0x4F16,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0000003C_00000004_0000000C_00000000,
            .lr = 3,
            .fpscr = 0x00020000,
        },
        .{
            .qd = 0x00000000_FFFFD8BB_FFFFC0A3_00006447,
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
        "the loop tail on vstrb.8 stops after lane 9",
        .{
            .hw1 = 0xEC81,
            .hw2 = 0x4E06,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0B14080C_061E053F_0409020F_01070300,
            .lr = 9,
            .fpscr = 0x00000000,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000200,
            .mem = .{
                0x44DDC0A3_8669222F_66F5D811_77335588,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0xFF4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "eci a0a1 keeps the done beats of qd on a gather",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x4E96,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0008000E_000A0006_001E0002_00040000,
            .it = 0x20,
        },
        .{
            .qd = 0x4C2FFADD_866912F5_11223344_55667788,
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
            .hw2 = 0x4F46,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0000003C_00000004_0000000C_00000000,
            .it = 0x40,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x8899AABB_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
};

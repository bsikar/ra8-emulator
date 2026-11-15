//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vldrw.u32 at an odd offset faults unaligned and changes nothing",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x4F46,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000008_00000009_00000004_00000000,
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
        "vldrh.u16 with an offset that wraps faults unmapped",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x4E96,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x000C000A_00080006_0004FE00_00020000,
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
        "vldrw.u32 offset large enough to wrap past 4 GiB lands back in the window",
        .{
            .hw1 = 0xFC91,
            .hw2 = 0x4F47,
            .base = 0x20000210,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000002_3FFFFFFC_40000000_00000000,
        },
        .{
            .qd = 0x56391CFF_9E816447_6E513417_6E513417,
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
        "vstrb.8 scatters bytes",
        .{
            .hw1 = 0xEC81,
            .hw2 = 0x4E06,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0B14080C_061E053F_0409020F_01070300,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000200,
            .mem = .{
                0x44DDC0BB_886922AA_66CCEE11_77335588,
                0xCADD9073_56391CFF_E2C5A899_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0xFF4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vstrb.16 keeps the low byte of each half",
        .{
            .hw1 = 0xEC81,
            .hw2 = 0x4E86,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0008003E_001E0001_000F0003_00070000,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000200,
            .mem = .{
                0x22DDC0A3_86694C99_66F5D8BB_4481FF88,
                0xCADD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6ABB3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vstrb.32 keeps the low byte of each word",
        .{
            .hw1 = 0xEC81,
            .hw2 = 0x4F06,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0000003B_00000006_0000000D_00000000,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000200,
            .mem = .{
                0xFADD44A3_86694C2F_12FFD8BB_9E816488,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_BBD9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vstrh.16 uxtw #1",
        .{
            .hw1 = 0xEC81,
            .hw2 = 0x4E97,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00010006_00140004_00090002_0000001F,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000200,
            .mem = .{
                0xFADDAABB_8669EEFF_12F53344_88995566,
                0xCAAD9073_56391CFF_E2C5A88B_11223417,
                0x9A7D6043_2609CCDD_B295785B_3E2104E7,
                0x77883013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vstrh.32 unscaled keeps the low half",
        .{
            .hw1 = 0xEC81,
            .hw2 = 0x4F16,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0000003C_00000004_0000000C_00000000,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000200,
            .mem = .{
                0xFADD3344_86694C2F_12F5EEFF_9E817788,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4DAABB_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vstrw.32 uxtw #2",
        .{
            .hw1 = 0xEC81,
            .hw2 = 0x4F47,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000009_00000004_00000000_0000000F,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_11223344,
                0xCAAD9073_56391CFF_E2C5A88B_CCDDEEFF,
                0x9A7D6043_2609ECCF_8899AABB_3E2104E7,
                0x55667788_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vstrw.32 faults at element 2 and keeps elements 0 and 1",
        .{
            .hw1 = 0xEC81,
            .hw2 = 0x4F46,
            .base = 0x20000200,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000004_00000016_00000000_00000008,
        },
        .{
            .fault = .unaligned,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_55667788_12F5D8BB_11223344,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vstrw.32 with qd equal to qm stores its own offsets",
        .{ .hw1 = 0xEC81, .hw2 = 0xAF4A, .base = 0x20000200, .qd = 0x00000038_00000004_00000020_00000010 },
        .{
            .qd = 0x00000000_00000000_00000000_00000000,
            .rn = 0x20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_00000000,
                0xCAAD9073_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
};

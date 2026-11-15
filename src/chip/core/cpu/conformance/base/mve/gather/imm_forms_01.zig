//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("imm_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vldrw.u32 adds imm7 times 4 to each base",
        .{
            .hw1 = 0xFD96,
            .hw2 = 0x5E02,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x20000230_20000204_20000218_20000200,
        },
        .{
            .qd = 0xF6D9BC9F_FADDC0A3_3E2104E7_86694C2F,
            .qm = 0x20000230_20000204_20000218_20000200,
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
        "vldrw.u32 subtracts imm7 times 4",
        .{
            .hw1 = 0xFD16,
            .hw2 = 0x5E01,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x20000234_20000208_2000021C_20000204,
        },
        .{
            .qd = 0x0EF1D4B7_12F5D8BB_56391CFF_9E816447,
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
        "vldrw.u32 writeback replaces each base with its address",
        .{
            .hw1 = 0xFDB6,
            .hw2 = 0x5E03,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x20000230_20000204_20000218_20000200,
        },
        .{
            .qd = 0x6A4D3013_6E513417_B295785B_FADDC0A3,
            .qm = 0x2000023C_20000210_20000224_2000020C,
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
        "vldrw.u32 with no offset into q7 from q0",
        .{
            .hw1 = 0xFD90,
            .hw2 = 0xFE00,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x20000230_20000204_20000218_20000200,
        },
        .{
            .qd = 0x0EF1D4B7_12F5D8BB_56391CFF_9E816447,
            .qm = 0x20000230_20000204_20000218_20000200,
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
        "vldrw.u32 at the largest imm7",
        .{
            .hw1 = 0xFD96,
            .hw2 = 0x5E7F,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x20000040_20000020_20000010_20000004,
        },
        .{
            .qd = 0x6A4D3013_CAAD9073_FADDC0A3_9E816447,
            .qm = 0x20000040_20000020_20000010_20000004,
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
        "vldrw.u32 at an odd base faults unaligned and changes nothing",
        .{
            .hw1 = 0xFDB6,
            .hw2 = 0x5E00,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x20000208_20000204_20000206_20000200,
        },
        .{
            .fault = .unaligned,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x20000208_20000204_20000206_20000200,
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
        "vldrw.u32 subtract below the ram faults unmapped and keeps qm",
        .{
            .hw1 = 0xFD36,
            .hw2 = 0x5E01,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x20000208_20000204_20000000_20000208,
        },
        .{
            .fault = .unmapped,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x20000208_20000204_20000000_20000208,
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
        "vldrd.u64 adds imm7 times 8 and ignores the odd base words",
        .{
            .hw1 = 0xFD96,
            .hw2 = 0x5F01,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0000BEEF_20000220_0000DEAD_20000200,
        },
        .{
            .qd = 0x9A7D6043_2609ECCF_FADDC0A3_86694C2F,
            .qm = 0x0000BEEF_20000220_0000DEAD_20000200,
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
        "vldrd.u64 writeback moves only the even words",
        .{
            .hw1 = 0xFDB6,
            .hw2 = 0x5F02,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0000BEEF_20000220_0000DEAD_20000200,
        },
        .{
            .qd = 0x8265482B_0EF1D4B7_E2C5A88B_6E513417,
            .qm = 0x0000BEEF_20000230_0000DEAD_20000210,
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
        "vldrd.u64 at a word-aligned base is allowed",
        .{
            .hw1 = 0xFD96,
            .hw2 = 0x5F00,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_20000234_00000000_20000204,
        },
        .{
            .qd = 0xF6D9BC9F_8265482B_86694C2F_12F5D8BB,
            .qm = 0x00000000_20000234_00000000_20000204,
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
        "vldrd.u64 whose odd beat runs past the ram faults unmapped",
        .{
            .hw1 = 0xFD96,
            .hw2 = 0x5F00,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_200003FC_00000000_20000200,
        },
        .{
            .fault = .unmapped,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_200003FC_00000000_20000200,
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
        "vldrd.u64 with a base that wraps past 4 GiB faults unmapped",
        .{
            .hw1 = 0xFDB6,
            .hw2 = 0x5F01,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_FFFFFFF8_00000000_20000200,
        },
        .{
            .fault = .unmapped,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_FFFFFFF8_00000000_20000200,
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

//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("imm_types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vstrw.32 scatters each word",
        .{
            .hw1 = 0xFD86,
            .hw2 = 0x5E01,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x20000230_20000204_20000218_20000200,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x20000230_20000204_20000218_20000200,
            .mem = .{
                0xFADDC0A3_CCDDEEFF_55667788_9E816447,
                0x11223344_56391CFF_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8899AABB_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vstrw.32 subtract with writeback",
        .{
            .hw1 = 0xFD26,
            .hw2 = 0x5E02,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x20000238_20000210_20000220_20000208,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x20000230_20000208_20000218_20000200,
            .mem = .{
                0xFADDC0A3_CCDDEEFF_12F5D8BB_55667788,
                0xCAAD9073_11223344_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_8899AABB,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vstrw.32 faults at element 2 and keeps elements 0 and 1 but not the writeback",
        .{
            .hw1 = 0xFDA6,
            .hw2 = 0x5E00,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x20000230_20000222_20000210_20000200,
        },
        .{
            .fault = .unaligned,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x20000230_20000222_20000210_20000200,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_55667788,
                0xCAAD9073_56391CFF_E2C5A88B_11223344,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vstrw.32 with qd equal to qm stores the old bases and writes back",
        .{ .hw1 = 0xFDAA, .hw2 = 0xBE01, .qd = 0x20000230_20000204_20000218_20000200 },
        .{
            .fault = .unmapped,
            .qd = 0x00000000_00000000_00000000_00000000,
            .qm = 0x00000000_00000000_00000000_00000000,
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
        "vstrd.64 scatters two doublewords",
        .{
            .hw1 = 0xFD86,
            .hw2 = 0x5F01,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_20000200_00000000_20000210,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x00000000_20000200_00000000_20000210,
            .mem = .{
                0x8899AABB_CCDDEEFF_12F5D8BB_9E816447,
                0x11223344_55667788_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
    vec(
        "vstrd.64 with writeback",
        .{
            .hw1 = 0xFDA6,
            .hw2 = 0x5F03,
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0000BEEF_20000220_0000DEAD_20000200,
        },
        .{
            .qd = 0x8899AABB_CCDDEEFF_11223344_55667788,
            .qm = 0x0000BEEF_20000238_0000DEAD_20000218,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0x11223344_55667788_E2C5A88B_6E513417,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x8899AABB_CCDDEEFF_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
};

//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vldrb.8 pre offset add",
        .{ .hw1 = 0xED91, .hw2 = 0x5E03, .base = 0x20000200, .qd = 0x11112222_33334444_55556666_77778888 },
        .{
            .qd = 0x513417FA_DDC0A386_694C2F12_F5D8BB9E,
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
        "vldrb.8 post index with writeback",
        .{ .hw1 = 0xECB1, .hw2 = 0x5E7F, .base = 0x20000210, .qd = 0x11112222_33334444_55556666_77778888 },
        .{
            .qd = 0xCAAD9073_56391CFF_E2C5A88B_6E513417,
            .rn = 0x2000028F,
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
        "vldrb.8 at an odd address needs no alignment",
        .{ .hw1 = 0xED93, .hw2 = 0x5E00, .base = 0x20000221, .qd = 0x11112222_33334444_55556666_77778888 },
        .{
            .qd = 0xB79A7D60_432609EC_CFB29578_5B3E2104,
            .rn = 0x20000221,
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
        "vldrh.16 pre index subtract with writeback",
        .{ .hw1 = 0xED31, .hw2 = 0x5E84, .base = 0x20000230, .qd = 0x11112222_33334444_55556666_77778888 },
        .{
            .qd = 0x8265482B_0EF1D4B7_9A7D6043_2609ECCF,
            .rn = 0x20000228,
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
        "vldrh.16 imm 0",
        .{ .hw1 = 0xED94, .hw2 = 0x5E80, .base = 0x20000202, .qd = 0x11112222_33334444_55556666_77778888 },
        .{
            .qd = 0x3417FADD_C0A38669_4C2F12F5_D8BB9E81,
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
        "vldrw.32 post index with writeback",
        .{ .hw1 = 0xECB1, .hw2 = 0x5F02, .base = 0x20000220, .qd = 0x11112222_33334444_55556666_77778888 },
        .{
            .qd = 0x9A7D6043_2609ECCF_B295785B_3E2104E7,
            .rn = 0x20000228,
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
        "vldrw.32 from sp without writeback",
        .{ .hw1 = 0xED9D, .hw2 = 0x5F01, .base = 0x20000224, .qd = 0x11112222_33334444_55556666_77778888 },
        .{
            .qd = 0x8265482B_0EF1D4B7_9A7D6043_2609ECCF,
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
        "vldrw.32 into q7 from r12",
        .{ .hw1 = 0xED1C, .hw2 = 0xFF03, .base = 0x20000230, .qd = 0x11112222_33334444_55556666_77778888 },
        .{
            .qd = 0x0EF1D4B7_9A7D6043_2609ECCF_B295785B,
            .rn = 0x20000230,
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
        "vldrw.32 with a subtract that wraps faults unmapped and changes nothing",
        .{ .hw1 = 0xED31, .hw2 = 0x5F03, .base = 0x00000004, .qd = 0x11112222_33334444_55556666_77778888 },
        .{
            .fault = .unmapped,
            .qd = 0x11112222_33334444_55556666_77778888,
            .rn = 0x00000004,
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
        "vldrw.32 at a halfword address faults unaligned and changes nothing",
        .{ .hw1 = 0xEDB1, .hw2 = 0x5F00, .base = 0x20000202, .qd = 0x11112222_33334444_55556666_77778888 },
        .{
            .fault = .unaligned,
            .qd = 0x11112222_33334444_55556666_77778888,
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
        "vldrh.16 at an odd address faults unaligned",
        .{ .hw1 = 0xECB1, .hw2 = 0x5E81, .base = 0x20000201, .qd = 0x11112222_33334444_55556666_77778888 },
        .{
            .fault = .unaligned,
            .qd = 0x11112222_33334444_55556666_77778888,
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
        "vstrb.8 pre index subtract",
        .{ .hw1 = 0xED01, .hw2 = 0x5E10, .base = 0x20000220, .qd = 0x11112222_33334444_55556666_77778888 },
        .{
            .qd = 0x11112222_33334444_55556666_77778888,
            .rn = 0x20000220,
            .mem = .{
                0xFADDC0A3_86694C2F_12F5D8BB_9E816447,
                0x11112222_33334444_55556666_77778888,
                0x9A7D6043_2609ECCF_B295785B_3E2104E7,
                0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7,
            },
            .vpr = 0x00000000,
        },
    ),
};

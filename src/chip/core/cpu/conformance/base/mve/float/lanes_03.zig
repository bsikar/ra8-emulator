//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const V = defs.V;
const vec = defs.vec;

pub const values = [_]V{
    vec(
        "vadd.f16 with fz16 flushes subnormals",
        .{
            .hw1 = 0xEF12,
            .hw2 = 0x0D44,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x14196400_80000010_3C007E01_00007C00,
            .qm = 0x14195400_44003800_7C013C00_BC003C00,
            .fpscr = 0x000C0000,
        },
        .{ .qd = 0x18196440_44003800_7E007E00_BC007C00, .fpscr = 0x000C0001, .vpr = 0x00000000 },
    ),
    vec(
        "vabd.f16 with fz16 flushes subnormals",
        .{
            .hw1 = 0xFF32,
            .hw2 = 0x0D44,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .qm = 0x7C000001_211F5CB0_C70034CD_38004200,
            .fpscr = 0x000C0000,
        },
        .{ .qd = 0x7C003800_00000000_49003267_41003E00, .fpscr = 0x000C0000, .vpr = 0x00000000 },
    ),
    vec(
        "fz, dn and rmode in fpscr are ignored and flags accumulate",
        .{
            .hw1 = 0xFF02,
            .hw2 = 0x0D54,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000,
            .qm = 0xC0E00000_3E99999A_3F000000_40400000,
            .fpscr = 0x03C40010,
        },
        .{ .qd = 0xC1A80000_3CF5C290_BF800000_40900000, .fpscr = 0x03C40010, .vpr = 0x00000000 },
    ),
    vec(
        "qn equal to qm squares each lane",
        .{
            .hw1 = 0xFF08,
            .hw2 = 0x0D58,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000,
        },
        .{ .qd = 0x00000000_00000000_00000000_00000000, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "vsub with qn equal to qm gives +0 or the default nan",
        .{
            .hw1 = 0xEF28,
            .hw2 = 0x0D48,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x00000000_7F800000_7149F2CA_7149F2CA,
        },
        .{ .qd = 0x00000000_00000000_00000000_00000000, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "qd equal to qm overwrites its own operand",
        .{
            .hw1 = 0xFF26,
            .hw2 = 0xAD4A,
            .qd = 0x42C80000_322BCC77_BE800000_3F800000,
            .qn = 0x40400000_3DCCCCCD_C0000000_3FC00000,
        },
        .{ .qd = 0x40400000_3DCCCCCD_40000000_3FC00000, .fpscr = 0x00040000, .vpr = 0x00000000 },
    ),
    vec(
        "q7 from q6 and q5 at f16",
        .{
            .hw1 = 0xEF3C,
            .hw2 = 0xED4A,
            .qd = 0x11112222_33334444_55556666_77778888,
            .qn = 0x4000B800_211F5CB0_42002E66_C0003E00,
            .qm = 0x7C000001_211F5CB0_C70034CD_38004200,
        },
        .{ .qd = 0xFC00B800_00000000_4900B267_C100BE00, .fpscr = 0x00040010, .vpr = 0x00000000 },
    ),
};

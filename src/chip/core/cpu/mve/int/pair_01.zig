//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const a = defs.a;
const b = defs.b;
const c = defs.c;
const pc = defs.pc;
const VPair = defs.VPair;

pub const values = [_]VPair{
    .{
        .encoding = "VABD (vector) T1",
        .name = "s8",
        .input = pc(.abd, a, b, .byte, false),
        .expect = 0x7F010102_01020001_01020102,
    },
    .{
        .encoding = "VABD (vector) T1",
        .name = "u16",
        .input = pc(.abd, a, c, .half, true),
        .expect = 0x7FFF0002_7FFCFFFB_FEFF807D_80007FFF,
    },
    .{
        .encoding = "VABD (vector) T1",
        .name = "s32 full width",
        .input = pc(.abd, a, c, .word, false),
        .expect = 0x80010002_7FFCFFFB_01007F83_80007FFF,
    },
    .{
        .encoding = "VMAX T1",
        .name = "s8",
        .input = pc(.max, a, b, .byte, false),
        .expect = 0x80000000_7F000001_01017F81_00010001,
    },
    .{
        .encoding = "VMAX T1",
        .name = "u8",
        .input = pc(.max, a, b, .byte, true),
        .expect = 0x80000000_7FFFFFFF_01FF7F81_FFFFFFFF,
    },
    .{
        .encoding = "VMAX T1",
        .name = "s32",
        .input = pc(.max, a, c, .word, false),
        .expect = 0x10002_7FFFFFFF_00FF7F80_7FFF8000,
    },
    .{
        .encoding = "VMIN T1",
        .name = "s16",
        .input = pc(.min, a, c, .half, false),
        .expect = 0x80000000_0003FFFF_FFFEFFFD_FFFF8000,
    },
    .{
        .encoding = "VMIN T1",
        .name = "u16",
        .input = pc(.min, a, c, .half, true),
        .expect = 0x10000_00030004_00FF7F80_7FFF0001,
    },
    .{
        .encoding = "VMIN T1",
        .name = "u32",
        .input = pc(.min, a, b, .word, true),
        .expect = 0x80000000_00000001_00FF7F80_0001FFFF,
    },
    .{
        .encoding = "VHADD (vector) T1",
        .name = "s8",
        .input = pc(.hadd, a, b, .byte, false),
        .expect = 0x80000000_3FFFFF00_00007F80_FF00FF00,
    },
    .{
        .encoding = "VHADD (vector) T1",
        .name = "u32 keeps the carry",
        .input = pc(.hadd, a, c, .word, true),
        .expect = 0x40008001_40018001_807F3FBE_BFFF4000,
    },
    .{
        .encoding = "VRHADD T1",
        .name = "s16",
        .input = pc(.rhadd, a, b, .half, false),
        .expect = 0x80000000_40000000_01007F81_00000000,
    },
    .{
        .encoding = "VRHADD T1",
        .name = "u8 rounds up",
        .input = pc(.rhadd, a, c, .byte, true),
        .expect = 0x40010001_40818082_80FFBFBF_BFFF4001,
    },
    .{
        .encoding = "VHSUB (vector) T1",
        .name = "s16",
        .input = pc(.hsub, a, c, .half, false),
        .expect = 0xBFFFFFFF_3FFEFFFD_00803FC1_C0004000,
    },
    .{
        .encoding = "VHSUB (vector) T1",
        .name = "u32 borrows",
        .input = pc(.hsub, a, b, .word, true),
        .expect = 0x3FFFFFFF_FFFEFFFF_7FFE8001,
    },
};

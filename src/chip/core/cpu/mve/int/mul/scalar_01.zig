//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const a = defs.a;
const c = defs.c;
const d = defs.d;
const VScalar = defs.VScalar;

pub const values = [_]VScalar{
    .{
        .encoding = "VMLA T1",
        .name = "i8",
        .input = .{ .da = d, .n = a, .scalar = 0x103, .size = .byte, .form = .vmla },
        .expect = 0x91223344_D2637485_99A7384C_DAEBFF03,
    },
    .{
        .encoding = "VMLA T1",
        .name = "i16",
        .input = .{ .da = d, .n = a, .scalar = 0xFFFF8001, .size = .half, .form = .vmla },
        .expect = 0x91223344_5565F787_1AA93B4C_5DED7F01,
    },
    .{
        .encoding = "VMLA T1",
        .name = "i32",
        .input = .{ .da = d, .n = c, .scalar = 0xFFFFFFFF, .size = .word, .form = .vmla },
        .expect = 0x11213342_55637784_99ABBBCF_5DEF7F00,
    },
    .{
        .encoding = "VMLAS T1",
        .name = "i8",
        .input = .{ .da = d, .n = a, .scalar = 0x7F, .size = .byte, .form = .vmlas },
        .expect = 0xFF7F7F7F_AA1908F7_7FD5447F_A2917F7F,
    },
    .{
        .encoding = "VMLAS T1",
        .name = "i16",
        .input = .{ .da = d, .n = c, .scalar = 0x1234, .size = .half, .form = .vmlas },
        .expect = 0x235678BC_1266F054_DEE0DED0_34461234,
    },
    .{
        .encoding = "VMLAS T1",
        .name = "i32",
        .input = .{ .da = d, .n = a, .scalar = 0x80000000, .size = .word, .form = .vmlas },
        .expect = 0x80000000_2A998878_18BC1A00_5EEEFF00,
    },
};

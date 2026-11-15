//! Ordered instruction-vector cases; values are unchanged from the parent group.
const defs = @import("types.zig");

const a = defs.a;
const m = defs.m;
const VWiden = defs.VWiden;

pub const values = [_]VWiden{
    .{
        .encoding = "VMOVL T1",
        .name = "s8 bottom",
        .input = .{ .m = a, .size = .byte, .half = .bottom, .unsigned = false, .left = 0 },
        .expect = 0xFFFFFFFF_FFFFFF80_FFFF0001,
    },
    .{
        .encoding = "VMOVL T1",
        .name = "u16 top",
        .input = .{ .m = a, .size = .half, .half = .top, .unsigned = true, .left = 0 },
        .expect = 0x00008000_00007FFF_000000FF_0000FFFF,
    },
    .{
        .encoding = "VMOVL T1",
        .name = "s16 top",
        .input = .{ .m = m, .size = .half, .half = .top, .unsigned = false, .left = 0 },
        .expect = 0xFFFFFFFF_00000001_FFFFFFFF_00000000,
    },
    .{
        .encoding = "VSHLL T1",
        .name = "u8 top #8",
        .input = .{ .m = a, .size = .byte, .half = .top, .unsigned = true, .left = 8 },
        .expect = 0x80000000_7F00FF00_00007F00_FF000000,
    },
    .{
        .encoding = "VSHLL T1",
        .name = "s16 bottom #3",
        .input = .{ .m = a, .size = .half, .half = .bottom, .unsigned = false, .left = 3 },
        .expect = 0xFFFFFFF8_0003FC00_00000008,
    },
    .{
        .encoding = "VSHLL T1",
        .name = "s8 bottom #7",
        .input = .{ .m = m, .size = .byte, .half = .bottom, .unsigned = false, .left = 7 },
        .expect = 0xFF800000_0080FF80_FF803F80_0000C000,
    },
};

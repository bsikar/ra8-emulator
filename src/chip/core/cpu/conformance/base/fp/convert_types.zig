//! Types and constructors shared by the adjacent instruction-vector case groups.

pub const vector = @import("../../vector.zig");

pub const fpscr_reset: u32 = 0x0004_0000;

pub const dst_reset: u64 = 0xFFFF_FFFF_FFFF_FFFF;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// The source, written after the destination is preset; fixed-point
    /// forms convert in place, so their source register is the destination.
    src: u64 = 0,
    src_reg: u5 = 1,
    src_wide: bool = false,
    dst_reg: u5 = 0,
    dst_wide: bool = false,
    fpscr: u32 = fpscr_reset,
};

/// Whether the group claims the encoding, the destination and FPSCR after.
pub const Out = struct {
    claimed: bool = true,
    dst: u64,
    fpscr: u32 = fpscr_reset,
};

pub const V = vector.Vector(In, Out);

pub const group = "fp_convert";

pub const none: Out = .{ .claimed = false, .dst = 0, .fpscr = 0 };

pub fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub fn raised(bits: u32) u32 {
    return fpscr_reset | bits;
}

pub const ioc: u32 = 1 << 0;

pub const ofc: u32 = 1 << 2;

pub const ixc: u32 = 1 << 4;

//! Floating-point conversion fixtures: instruction halfwords, raw operand bits, and expected status.
//! FPSCR is the floating-point status/control register.

pub const vector = @import("../../vector.zig");

/// LTPSIZE (tail-predication element size) has its reset encoding; exception flags start clear.
pub const fpscr_reset: u32 = 0x0004_0000;

/// The runner presets the destination before writing the source operand.
pub const dst_reset: u64 = 0xFFFF_FFFF_FFFF_FFFF;

pub const In = struct {
    /// Instruction halfwords in fetch order; size is the instruction length in bytes.
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// Raw source register bits, written after the destination is preset; fixed-point
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

/// A case that must reject the encoding instead of producing a conversion result.
pub fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

/// Expected FPSCR with these cumulative exception flags added to the reset controls.
pub fn raised(bits: u32) u32 {
    return fpscr_reset | bits;
}

/// Invalid Operation cumulative exception flag (FPSCR.IOC).
pub const ioc: u32 = 1 << 0;

/// Overflow cumulative exception flag (FPSCR.OFC).
pub const ofc: u32 = 1 << 2;

/// Inexact cumulative exception flag (FPSCR.IXC).
pub const ixc: u32 = 1 << 4;

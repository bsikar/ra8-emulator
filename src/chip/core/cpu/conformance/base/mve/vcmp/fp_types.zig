//! MVE floating-point comparison fixtures: operands in, predicate/status flags out.

pub const vector = @import("../../../vector.zig");

pub const In = struct {
    /// First and second instruction halfwords, in fetch order.
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// Raw Q-register bits; the instruction selects the lane size and interpretation.
    qn: u128 = 0,
    qm: u128 = 0,
    rm: u32 = 0,
    /// Vector Predicate Register bits.
    vpr: u32 = 0,
    /// Packed If-Then (IT) or interrupted-instruction continuation (ECI) state.
    it: u8 = 0,
    lr: u32 = 0,
    fpscr: u32 = 0x0004_0000,
};

pub const Out = struct {
    claimed: bool = true,
    vpr: u32,
    fpscr: u32,
    it: u8 = 0,
};

pub const V = vector.Vector(In, Out);

pub const group = "mve_vcmp_fp";

pub const none: Out = .{ .claimed = false, .vpr = 0, .fpscr = 0 };

pub fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

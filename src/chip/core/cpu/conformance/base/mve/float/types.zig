//! MVE floating-point fixtures: encoded instructions and before/after register state.

pub const vector = @import("../../../vector.zig");

pub const In = struct {
    /// First and second instruction halfwords, in fetch order.
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// Raw Q-register bits; the instruction selects the lane size and interpretation.
    qd: u128 = 0,
    qn: u128 = 0,
    qm: u128 = 0,
    /// Vector Predicate Register bits.
    vpr: u32 = 0,
    /// Packed If-Then (IT) or interrupted-instruction continuation (ECI) state.
    it: u8 = 0,
    lr: u32 = 0,
    fpscr: u32 = 0x0004_0000,
};

pub const Out = struct {
    claimed: bool = true,
    qd: u128,
    fpscr: u32,
    vpr: u32 = 0,
    it: u8 = 0,
};

pub const V = vector.Vector(In, Out);

pub const group = "mve_float";

pub const none: Out = .{ .claimed = false, .qd = 0, .fpscr = 0 };

pub fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

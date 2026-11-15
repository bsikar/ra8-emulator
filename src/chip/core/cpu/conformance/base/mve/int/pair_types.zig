//! MVE pairwise integer fixtures, including predication and saturation status.

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
    ltpsize: u3 = 4,
    lr: u32 = 0,
    /// FPSCR.QC, the cumulative saturation flag.
    qc: u1 = 0,
};

pub const Out = struct {
    claimed: bool = true,
    qd: u128,
    vpr: u32 = 0,
    it: u8 = 0,
    qc: u1 = 0,
};

pub const V = vector.Vector(In, Out);

pub const group = "mve_int_pair";

pub const none: Out = .{ .claimed = false, .qd = 0 };

pub fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

//! Types and constructors shared by the adjacent instruction-vector case groups.

pub const vector = @import("../../../vector.zig");

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    qm: u128 = 0,
    rda: u32 = 0,
    vpr: u32 = 0,
    lr: u32 = 0,
    fpscr: u32 = 0x0004_0000,
};

pub const Out = struct {
    claimed: bool = true,
    rda: u32,
    fpscr: u32,
    vpr: u32 = 0,
};

pub const V = vector.Vector(In, Out);

pub const group = "mve_float_maxnmv";

pub const none: Out = .{ .claimed = false, .rda = 0, .fpscr = 0 };

pub fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

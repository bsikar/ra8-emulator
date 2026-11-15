//! Types and constructors shared by the adjacent instruction-vector case groups.

pub const vector = @import("../../../vector.zig");

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    qda: u128 = 0,
    qn: u128 = 0,
    rm: u32 = 0,
    vpr: u32 = 0,
    it: u8 = 0,
    ltpsize: u3 = 4,
    lr: u32 = 0,
    qc: u1 = 0,
};

pub const Out = struct {
    claimed: bool = true,
    qda: u128,
    vpr: u32 = 0,
    it: u8 = 0,
    qc: u1 = 0,
};

pub const V = vector.Vector(In, Out);

pub const group = "mve_int_vqdmlah";

pub const none: Out = .{ .claimed = false, .qda = 0 };

pub fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

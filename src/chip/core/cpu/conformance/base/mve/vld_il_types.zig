//! Types and constructors shared by the adjacent instruction-vector case groups.

pub const vector = @import("../../vector.zig");

pub const Fault = enum { none, unaligned, unmapped, other };

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    base: u32,
    q: [4]u128 = .{ 0, 0, 0, 0 },
    vpr: u32 = 0,
    it: u8 = 0,
};

pub const Out = struct {
    claimed: bool = true,
    fault: Fault = .none,
    q: [4]u128 = .{ 0, 0, 0, 0 },
    rn: u32 = 0,
    mem: [4]u128 = .{ 0, 0, 0, 0 },
    vpr: u32 = 0,
};

/// Where the observed RAM window starts, and what each of its 64 bytes holds
/// before a vector runs.
pub const window: u32 = 0x2000_0200;

pub fn fill(i: usize) u8 {
    return @truncate(i *% 0x1D +% 0x47);
}

pub const V = vector.Vector(In, Out);

pub const group = "mve_vld_il";

pub const none: Out = .{ .claimed = false };

pub fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

//! Interleaved MVE load/store fixtures over four Q registers and a 64-byte RAM window.

pub const vector = @import("../../vector.zig");

pub const Fault = enum { none, unaligned, unmapped, other };

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// Initial base-register address for the memory transfer.
    base: u32,
    q: [4]u128 = .{ 0, 0, 0, 0 },
    vpr: u32 = 0,
    it: u8 = 0,
};

pub const Out = struct {
    claimed: bool = true,
    fault: Fault = .none,
    q: [4]u128 = .{ 0, 0, 0, 0 },
    /// Base-register value after any addressing-mode writeback.
    rn: u32 = 0,
    mem: [4]u128 = .{ 0, 0, 0, 0 },
    vpr: u32 = 0,
};

/// Start address of the 64-byte RAM window checked by the runner.
pub const window: u32 = 0x2000_0200;

/// Distinct initial bytes expose lane/addressing mistakes in the memory result.
pub fn fill(i: usize) u8 {
    return @truncate(i *% 0x1D +% 0x47);
}

pub const V = vector.Vector(In, Out);

pub const group = "mve_vld_il";

pub const none: Out = .{ .claimed = false };

pub fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

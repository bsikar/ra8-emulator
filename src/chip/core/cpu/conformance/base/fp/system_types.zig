//! Types and constructors shared by the adjacent instruction-vector case groups.

pub const vector = @import("../../vector.zig");

pub const fpscr_reset: u32 = 0x0004_0000;

pub const r1_in: u32 = 0x1111_1111;

pub const xpsr_in: u32 = 0x0100_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// S0 and S1, or D0 and D1 when `double` is set.
    a: u64 = 0,
    b: u64 = 0,
    double: bool = false,
    fpscr: u32 = fpscr_reset,
    r1: u32 = r1_in,
    xpsr: u32 = xpsr_in,
    vpr: u32 = 0,
    secure: bool = true,
    sfpa: bool = false,
};

pub const Fault = enum { none, undefined_instr, other };

pub const Out = struct {
    claimed: bool = true,
    fault: Fault = .none,
    fpscr: u32 = fpscr_reset,
    r1: u32 = r1_in,
    xpsr: u32 = xpsr_in,
    vpr: u32 = 0,
    sfpa: bool = false,
};

pub const V = vector.Vector(In, Out);

pub const group = "fp_system";

pub const none: Out = .{ .claimed = false, .fpscr = 0, .r1 = 0, .xpsr = 0 };

pub fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub fn flags(nzcv: u4, ioc: bool) u32 {
    return (@as(u32, nzcv) << 28) | fpscr_reset | @intFromBool(ioc);
}

pub const less: u4 = 0b1000;

pub const equal: u4 = 0b0110;

pub const greater: u4 = 0b0010;

pub const unordered: u4 = 0b0011;

pub const one: u64 = 0x3F80_0000;

pub const two: u64 = 0x4000_0000;

pub const qnan: u64 = 0x7FC0_0000;

pub const snan: u64 = 0x7F80_0001;

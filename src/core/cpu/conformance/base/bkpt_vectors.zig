//! Conformance vectors for the decode group `bkpt` (RA8EMU-279): BKPT (T1).
//! Each expected value is worked from the Arm ARM (DDI0553): every imm8
//! raises a debug event instead of retiring.
const vector = @import("../vector.zig");

pub const In = struct {
    hw1: u16,
};

/// Whether the group claims the encoding, and whether it breaks.
pub const Out = struct {
    claimed: bool = true,
    breakpoint: bool = false,
};

const V = vector.Vector(In, Out);
const group = "bkpt";

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = [_]V{
    vec("bkpt #0", .{ .hw1 = 0xBE00 }, .{ .breakpoint = true }),
    vec("bkpt #0xAB (semihosting)", .{ .hw1 = 0xBEAB }, .{ .breakpoint = true }),
    vec("nop is not bkpt", .{ .hw1 = 0xBF00 }, .{ .claimed = false }),
};

pub const covered = vector.encodingsOf(In, Out, &all);

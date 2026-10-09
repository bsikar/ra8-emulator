//! Conformance vectors for the decode group `it` (RA8EMU-279): IT (T1).
//! Each expected value is worked from the Arm ARM (DDI0553): ITSTATE
//! becomes firstcond:mask, replacing whatever block was open; mask 0b0000
//! is a hint and not an IT; firstcond 0b1111 is UNPREDICTABLE and the M85
//! model makes it UNDEFINED, leaving ITSTATE alone.
const vector = @import("../vector.zig");

/// The instruction and the ITSTATE beforehand.
pub const In = struct {
    hw1: u16,
    it: u8 = 0,
};

/// Whether the group claims the encoding, whether it is UNDEFINED, and
/// ITSTATE afterwards (zero when unclaimed).
pub const Out = struct {
    claimed: bool = true,
    undefined: bool = false,
    it: u8 = 0,
};

const V = vector.Vector(In, Out);
const group = "it";

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = [_]V{
    vec("it eq", .{ .hw1 = 0xBF08 }, .{ .it = 0x08 }),
    vec("itte ne", .{ .hw1 = 0xBF1C }, .{ .it = 0x1C }),
    vec("itttt gt", .{ .hw1 = 0xBFC1 }, .{ .it = 0xC1 }),
    vec("it al", .{ .hw1 = 0xBFE8 }, .{ .it = 0xE8 }),
    vec("an IT inside a block starts anew", .{ .hw1 = 0xBF08, .it = 0x44 }, .{ .it = 0x08 }),
    vec("firstcond 0b1111 is UNDEFINED", .{ .hw1 = 0xBFF8, .it = 0x44 }, .{ .undefined = true, .it = 0x44 }),
    vec("mask 0b0000 (NOP) is a hint", .{ .hw1 = 0xBF00 }, .{ .claimed = false }),
    vec("mask 0b0000 (YIELD) is a hint", .{ .hw1 = 0xBF10 }, .{ .claimed = false }),
};

pub const covered = vector.encodingsOf(In, Out, &all);

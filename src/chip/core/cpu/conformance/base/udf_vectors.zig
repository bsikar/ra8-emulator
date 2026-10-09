//! Conformance vectors for the decode group `udf` (RA8EMU-279): UDF T1 and
//! T2. Each expected value is worked from the Arm ARM (DDI0553): every
//! imm8 and imm16 is UNDEFINED and nothing retires, so the PC stays on the
//! next-instruction value the step left; the neighbouring SVC and the
//! non-UDF wide encodings are not claimed.
const vector = @import("../vector.zig");

/// The instruction, both halfwords, and its size in bytes.
pub const In = struct {
    hw1: u16,
    hw2: u16 = 0,
    size: u8 = 2,
};

/// Whether the group claims the encoding, and whether it is UNDEFINED.
pub const Out = struct {
    claimed: bool = true,
    undefined: bool = false,
};

const V = vector.Vector(In, Out);
const group = "udf";
const undef: Out = .{ .undefined = true };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = [_]V{
    vec("udf #0 (T1)", .{ .hw1 = 0xDE00 }, undef),
    vec("udf #255 (T1)", .{ .hw1 = 0xDEFF }, undef),
    vec("udf.w #0 (T2)", .{ .hw1 = 0xF7F0, .hw2 = 0xA000, .size = 4 }, undef),
    vec("udf.w #65535 (T2)", .{ .hw1 = 0xF7FF, .hw2 = 0xAFFF, .size = 4 }, undef),
    vec("svc is not udf", .{ .hw1 = 0xDF00 }, .{ .claimed = false }),
    vec("hw2 0x8xxx is not udf.w", .{ .hw1 = 0xF7F0, .hw2 = 0x8000, .size = 4 }, .{ .claimed = false }),
};

pub const covered = vector.encodingsOf(In, Out, &all);

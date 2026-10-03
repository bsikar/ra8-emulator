//! Conformance vectors for the decode group `svc` (RA8EMU-279): SVC (T1).
//! Each expected value is worked from the Arm ARM (DDI0553): every imm8
//! raises exception 11 (SVCall) once the instruction retires, so the PC is
//! the next instruction and no register or flag changes.
const vector = @import("../vector.zig");

/// The instruction and NZCV beforehand.
pub const In = struct {
    hw1: u16,
    nzcv: u4 = 0,
};

/// Whether the group claims the encoding, the exception it raises (zero
/// for none), the PC and NZCV afterwards.
pub const Out = struct {
    claimed: bool = true,
    raised: u32 = 0,
    pc: u32 = 0,
    nzcv: u4 = 0,
};

pub const address: u32 = 0x1000;
pub const next: u32 = address + 2;

const V = vector.Vector(In, Out);
const group = "svc";

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = [_]V{
    vec("svc #0 raises SVCall", .{ .hw1 = 0xDF00 }, .{ .raised = 11, .pc = next }),
    vec("svc #255 raises SVCall, NZCV kept", .{ .hw1 = 0xDFFF, .nzcv = 0xF }, .{ .raised = 11, .pc = next, .nzcv = 0xF }),
    vec("udf is not svc", .{ .hw1 = 0xDE00 }, .{ .claimed = false }),
};

pub const covered = vector.encodingsOf(In, Out, &all);

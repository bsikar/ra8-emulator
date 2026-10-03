//! Conformance vectors for the decode group `cps` (RA8EMU-279): CPSIE and
//! CPSID (T1). Each expected value is worked from the Arm ARM (DDI0553):
//! only privileged code (Handler mode, or Thread mode with CONTROL.nPRIV
//! clear) changes PRIMASK or FAULTMASK; FAULTMASK is not raised from NMI
//! (exception 2) or HardFault (3) but may be cleared there; an encoding
//! with neither I nor F, or with bit 3 set, is not CPS.
const vector = @import("../vector.zig");

/// The instruction, PRIMASK and FAULTMASK beforehand, IPSR, and
/// CONTROL.nPRIV.
pub const In = struct {
    hw1: u16,
    primask: u1 = 0,
    faultmask: u1 = 0,
    ipsr: u9 = 0,
    npriv: bool = false,
};

/// Whether the group claims the encoding, then PRIMASK and FAULTMASK.
pub const Out = struct {
    claimed: bool = true,
    primask: u1 = 0,
    faultmask: u1 = 0,
};

const V = vector.Vector(In, Out);
const group = "cps";

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = [_]V{
    vec("cpsid i", .{ .hw1 = 0xB672 }, .{ .primask = 1 }),
    vec("cpsie i", .{ .hw1 = 0xB662, .primask = 1, .faultmask = 1 }, .{ .faultmask = 1 }),
    vec("cpsid f", .{ .hw1 = 0xB671 }, .{ .faultmask = 1 }),
    vec("cpsie f", .{ .hw1 = 0xB661, .primask = 1, .faultmask = 1 }, .{ .primask = 1 }),
    vec("cpsid if", .{ .hw1 = 0xB673 }, .{ .primask = 1, .faultmask = 1 }),
    vec("cpsie if", .{ .hw1 = 0xB663, .primask = 1, .faultmask = 1 }, .{}),
    vec("unprivileged Thread mode is a NOP", .{ .hw1 = 0xB673, .npriv = true }, .{}),
    vec("Handler mode is privileged whatever nPRIV says", .{ .hw1 = 0xB672, .ipsr = 5, .npriv = true }, .{ .primask = 1 }),
    vec("cpsid if in HardFault sets only PRIMASK", .{ .hw1 = 0xB673, .ipsr = 3 }, .{ .primask = 1 }),
    vec("cpsid f in NMI leaves FAULTMASK", .{ .hw1 = 0xB671, .ipsr = 2 }, .{}),
    vec("cpsie f in HardFault clears FAULTMASK", .{ .hw1 = 0xB661, .faultmask = 1, .ipsr = 3 }, .{}),
    vec("neither I nor F is not CPS", .{ .hw1 = 0xB670 }, .{ .claimed = false }),
    vec("bit 3 set is not CPS", .{ .hw1 = 0xB67A }, .{ .claimed = false }),
};

pub const covered = vector.encodingsOf(In, Out, &all);

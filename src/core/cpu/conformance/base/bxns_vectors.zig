//! Conformance vectors for the decode group `bxns` (RA8EMU-279): BXNS Rm
//! (T1). Expected values are worked from the Arm ARM (DDI0553): from Secure
//! state a target with bit 0 clear switches to Non-secure (the banked MSP
//! comes in) and branches there; a target with bit 0 set stays Secure and
//! is an ordinary BX; from Non-secure state BXNS is UNDEFINED. Rm of SP or
//! PC is left unclaimed, as are the neighbouring BX, BLX and BLXNS.
const vector = @import("../vector.zig");

/// The PC before the instruction, the Secure MSP in use, and the
/// Non-secure MSP waiting in the other bank.
pub const start_pc: u32 = 0x1002;
pub const secure_msp: u32 = 0x2000_0800;
pub const ns_msp: u32 = 0x2000_0400;

pub const In = struct {
    hw1: u16,
    size: u8 = 2,
    secure: bool = true,
    target: u32 = 0,
};

/// How the instruction ended.
pub const Fault = enum { none, undefined, other };

/// Whether the group claims the encoding, how it ended, and the PC, SP and
/// security state afterwards.
pub const Out = struct {
    claimed: bool = true,
    fault: Fault = .none,
    pc: u32 = start_pc,
    sp: u32 = secure_msp,
    secure: bool = true,
};

const V = vector.Vector(In, Out);
const group = "bxns";
const none: Out = .{ .claimed = false, .pc = 0, .sp = 0, .secure = false };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn toNs(pc: u32) Out {
    return .{ .pc = pc, .sp = ns_msp, .secure = false };
}

pub const all = [_]V{
    vec("bxns r0 to an even target goes Non-secure", .{ .hw1 = 0x4704, .target = 0x2000_0100 }, toNs(0x2000_0100)),
    vec("bxns r1 keeps a halfword-aligned target", .{ .hw1 = 0x470C, .target = 0x0800_0102 }, toNs(0x0800_0102)),
    vec("bxns r12", .{ .hw1 = 0x4764, .target = 0x0010_0000 }, toNs(0x0010_0000)),
    vec("bxns lr", .{ .hw1 = 0x4774, .target = 0x3000_0000 }, toNs(0x3000_0000)),
    vec("bxns to an odd target stays Secure like bx", .{ .hw1 = 0x470C, .target = 0x0800_0201 }, .{ .pc = 0x0800_0200 }),
    vec("bxns lr to an odd target stays Secure", .{ .hw1 = 0x4774, .target = 0x0000_4001 }, .{ .pc = 0x0000_4000 }),
    vec("bxns from Non-secure is undefined", .{ .hw1 = 0x4704, .secure = false, .target = 0x2000_0100 }, .{ .fault = .undefined, .secure = false }),
    vec("bxns sp is unclaimed", .{ .hw1 = 0x476C }, none),
    vec("bxns pc is unclaimed", .{ .hw1 = 0x477C }, none),
    vec("bx r0 belongs to bx", .{ .hw1 = 0x4700 }, none),
    vec("blx r0 belongs to blx", .{ .hw1 = 0x4780 }, none),
    vec("blxns r0 belongs to blxns", .{ .hw1 = 0x4784 }, none),
    vec("nonzero low bits are not bxns", .{ .hw1 = 0x4705 }, none),
    vec("the 32-bit space is unclaimed", .{ .hw1 = 0x4704, .size = 4 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);

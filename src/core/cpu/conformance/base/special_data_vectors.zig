//! Conformance vectors for the decode group `special_data` (RA8EMU-279):
//! 16-bit ADD and MOV with any register (T2/T1), CMP with a high register
//! (T2), BX and BLX. Each expected value is worked from the Arm ARM
//! (DDI0553): R15 reads as the instruction address plus 4, ADD and MOV to
//! the PC use ALUWritePC (bit 0 dropped, state kept), BX and BLX take
//! EPSR.T from bit 0, BLX sets LR to the next address with bit 0 set, only
//! CMP touches NZCV, and the UNPREDICTABLE forms stay unclaimed.
const vector = @import("../vector.zig");

/// The instruction at `address`, the values for its first register
/// (D:Rd or N:Rn) and second register (Rm, written after the first), and
/// NZCV beforehand. A register that is R15 takes no value.
pub const In = struct {
    hw1: u16,
    first: u32 = 0,
    second: u32 = 0,
    nzcv: u4 = 0,
};

/// Whether the group claims the encoding, then the first register (zero
/// when it is R15), PC, LR, NZCV and EPSR.T afterwards. All zero when
/// unclaimed.
pub const Out = struct {
    claimed: bool = true,
    first: u32 = 0,
    pc: u32 = 0,
    lr: u32 = 0,
    nzcv: u4 = 0,
    thumb: bool = false,
};

/// Where every vector's instruction sits; the PC starts at the next one.
pub const address: u32 = 0x1000;
pub const next: u32 = address + 2;

const V = vector.Vector(In, Out);
const group = "special_data";
const none: Out = .{ .claimed = false };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = [_]V{
    vec("add r0, r1 keeps NZCV", .{ .hw1 = 0x4408, .first = 5, .second = 7, .nzcv = 0xF }, .{ .first = 12, .pc = next, .nzcv = 0xF, .thumb = true }),
    vec("add r8, r9 wraps", .{ .hw1 = 0x44C8, .first = 0xFFFF_FFFF, .second = 2 }, .{ .first = 1, .pc = next, .thumb = true }),
    vec("add r0, pc reads address + 4", .{ .hw1 = 0x4478, .first = 0x10 }, .{ .first = 0x1014, .pc = next, .thumb = true }),
    vec("add pc, r1 drops bit 0 and keeps T", .{ .hw1 = 0x448F, .second = 0x101 }, .{ .pc = 0x1104, .thumb = true }),
    vec("add pc, pc is unclaimed", .{ .hw1 = 0x44FF }, none),
    vec("cmp r0, r8: lower", .{ .hw1 = 0x4540, .first = 1, .second = 2 }, .{ .first = 1, .pc = next, .nzcv = 0b1000, .thumb = true }),
    vec("cmp r8, r9: equal", .{ .hw1 = 0x45C8, .first = 5, .second = 5 }, .{ .first = 5, .pc = next, .nzcv = 0b0110, .thumb = true }),
    vec("cmp r0, r1 (both low) is unclaimed", .{ .hw1 = 0x4508 }, none),
    vec("cmp r0, pc is unclaimed", .{ .hw1 = 0x4578 }, none),
    vec("mov r0, r1 keeps NZCV", .{ .hw1 = 0x4608, .second = 0xDEAD_BEEF, .nzcv = 0xF }, .{ .first = 0xDEAD_BEEF, .pc = next, .nzcv = 0xF, .thumb = true }),
    vec("mov r12, r0", .{ .hw1 = 0x4684, .first = 0x5555, .second = 0x1234 }, .{ .first = 0x1234, .pc = next, .thumb = true }),
    vec("mov r0, pc reads address + 4", .{ .hw1 = 0x4678 }, .{ .first = 0x1004, .pc = next, .thumb = true }),
    vec("mov pc, r1 drops bit 0 and keeps T", .{ .hw1 = 0x468F, .second = 0x2001 }, .{ .pc = 0x2000, .thumb = true }),
    vec("bx r1 to Thumb", .{ .hw1 = 0x4708, .second = 0x3001 }, .{ .pc = 0x3000, .thumb = true }),
    vec("bx r1 with bit 0 clear clears T", .{ .hw1 = 0x4708, .second = 0x3000 }, .{ .pc = 0x3000, .thumb = false }),
    vec("blx r2 links the next address", .{ .hw1 = 0x4790, .second = 0x4001 }, .{ .pc = 0x4000, .lr = next | 1, .thumb = true }),
    vec("blx pc is unclaimed", .{ .hw1 = 0x47F8 }, none),
    vec("bx with bits [2:0] set is unclaimed", .{ .hw1 = 0x4701 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);

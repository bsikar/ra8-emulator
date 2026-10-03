//! Conformance vectors for the decode group `cbz` (RA8EMU-279): CBZ and
//! CBNZ (T1). Each expected value is worked from the Arm ARM (DDI0553): the
//! target is the instruction address plus 4 plus i:imm5:'0' (0 to 126),
//! taken when Rn is zero (CBZ) or not (CBNZ), with NZCV untouched.
const vector = @import("../vector.zig");

/// The instruction at `address`, the value in Rn ([2:0]) and NZCV.
pub const In = struct {
    hw1: u16,
    rn: u32,
    nzcv: u4 = 0,
};

/// Whether the group claims the encoding, then PC and NZCV afterwards.
pub const Out = struct {
    claimed: bool = true,
    pc: u32 = 0,
    nzcv: u4 = 0,
};

pub const address: u32 = 0x1000;
pub const next: u32 = address + 2;

const V = vector.Vector(In, Out);
const group = "cbz";

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = [_]V{
    vec("cbz r0, +0 taken lands at address + 4", .{ .hw1 = 0xB100, .rn = 0, .nzcv = 0xF }, .{ .pc = 0x1004, .nzcv = 0xF }),
    vec("cbz r0 not taken", .{ .hw1 = 0xB100, .rn = 1 }, .{ .pc = next }),
    vec("cbz r3, +126 is the furthest", .{ .hw1 = 0xB3FB, .rn = 0 }, .{ .pc = 0x1082 }),
    vec("cbnz r0, +2 taken", .{ .hw1 = 0xB908, .rn = 1 }, .{ .pc = 0x1006 }),
    vec("cbnz r0 not taken on zero", .{ .hw1 = 0xB908, .rn = 0, .nzcv = 0x4 }, .{ .pc = next, .nzcv = 0x4 }),
    vec("cbnz r7, +64 on bit 31 alone", .{ .hw1 = 0xBB07, .rn = 0x8000_0000 }, .{ .pc = 0x1044 }),
    vec("push is not cbz", .{ .hw1 = 0xB500, .rn = 0 }, .{ .claimed = false }),
};

pub const covered = vector.encodingsOf(In, Out, &all);

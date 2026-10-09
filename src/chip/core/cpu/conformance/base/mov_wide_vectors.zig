//! Conformance vectors for the decode group `mov_wide` (RA8EMU-280): MOVW
//! (MOV T3) and MOVT (T1). Expected values are worked from the Arm ARM
//! (DDI0553): imm16 is imm4:i:imm3:imm8, MOVW zero-extends it into Rd,
//! MOVT writes it to Rd[31:16] and keeps Rd[15:0], and neither touches the
//! flags. Rd of SP or PC is UNPREDICTABLE and left unclaimed, as are a set
//! hw2[15] and the neighbouring ADDW/SUBW encodings.
const vector = @import("../vector.zig");

/// The flags held before the instruction (N and C), which must survive.
pub const flags: u32 = 0xA000_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16 = 0,
    size: u8 = 4,
    /// Rd (hw2[11:8]) before the instruction.
    rd: u32 = 0xDEAD_BEEF,
};

/// Whether the group claims the encoding, then Rd and the NZCV flags after.
pub const Out = struct {
    claimed: bool = true,
    rd: u32 = 0,
    flags: u32 = flags,
};

const V = vector.Vector(In, Out);
const group = "mov_wide";
const none: Out = .{ .claimed = false, .flags = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = [_]V{
    vec("movw r0, #0", .{ .hw1 = 0xF240, .hw2 = 0x0000 }, .{ .rd = 0 }),
    vec("movw r0, #0xffff sets every imm field", .{ .hw1 = 0xF64F, .hw2 = 0x70FF }, .{ .rd = 0xFFFF }),
    vec("movw r3, #0x1234", .{ .hw1 = 0xF241, .hw2 = 0x2334 }, .{ .rd = 0x1234 }),
    vec("movw r12, #0x8000 from imm4", .{ .hw1 = 0xF248, .hw2 = 0x0C00 }, .{ .rd = 0x8000 }),
    vec("movw lr, #0x800 from i", .{ .hw1 = 0xF640, .hw2 = 0x0E00 }, .{ .rd = 0x0800 }),
    vec("movw r2, #0x700 from imm3", .{ .hw1 = 0xF240, .hw2 = 0x7200 }, .{ .rd = 0x0700 }),
    vec("movw r1, #0xff from imm8", .{ .hw1 = 0xF240, .hw2 = 0x01FF }, .{ .rd = 0x00FF }),
    vec("movt r0, #0x1234 keeps the low half", .{ .hw1 = 0xF2C1, .hw2 = 0x2034 }, .{ .rd = 0x1234_BEEF }),
    vec("movt r5, #0 clears the high half", .{ .hw1 = 0xF2C0, .hw2 = 0x0500, .rd = 0xFFFF_FFFF }, .{ .rd = 0x0000_FFFF }),
    vec("movt r7, #0xffff", .{ .hw1 = 0xF6CF, .hw2 = 0x77FF, .rd = 0x0000_1234 }, .{ .rd = 0xFFFF_1234 }),
    vec("movt r9, #0x8000", .{ .hw1 = 0xF2C8, .hw2 = 0x0900, .rd = 0x5555_AAAA }, .{ .rd = 0x8000_AAAA }),
    vec("movw sp is unclaimed", .{ .hw1 = 0xF240, .hw2 = 0x0D00 }, none),
    vec("movw pc is unclaimed", .{ .hw1 = 0xF240, .hw2 = 0x0F00 }, none),
    vec("movt sp is unclaimed", .{ .hw1 = 0xF2C0, .hw2 = 0x0D00 }, none),
    vec("a set hw2[15] is unclaimed", .{ .hw1 = 0xF240, .hw2 = 0x8000 }, none),
    vec("addw belongs to imm_arith", .{ .hw1 = 0xF200, .hw2 = 0x0000 }, none),
    vec("subw belongs to imm_arith", .{ .hw1 = 0xF2A0, .hw2 = 0x0000 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xF240, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);

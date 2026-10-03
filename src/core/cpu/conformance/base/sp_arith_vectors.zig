//! Conformance vectors for the decode group `sp_arith` (RA8EMU-279): ADD
//! and SUB SP, SP, #imm7 (T2/T1), ADD Rd, SP, #imm8 (T1) and ADR (T1).
//! Expected values are worked from the Arm ARM (DDI0553): imm7 and imm8
//! are scaled by 4, the sums wrap modulo 2^32, ADR adds to Align(PC, 4)
//! with PC reading as the address plus 4, and none of them touch the flags.
const vector = @import("../vector.zig");

/// The halfword, its size and address, SP, which low register to read
/// back, and the flags beforehand. Every low register starts at `fill`.
pub const In = struct {
    hw1: u16,
    size: u8 = 2,
    address: u32 = 0x1000,
    sp: u32 = 0x2000_0400,
    rd: u4 = 0,
    nzcv: u4 = 0,
};

/// The value every low register holds before the instruction runs.
pub const fill: u32 = 0x5555_5555;

/// Whether the group claims the encoding, then SP, the chosen low register
/// and the flags afterwards (all zero when unclaimed).
pub const Out = struct {
    claimed: bool = true,
    sp: u32 = 0x2000_0400,
    rd: u32 = fill,
    nzcv: u4 = 0,
};

const V = vector.Vector(In, Out);
const group = "sp_arith";
const none: Out = .{ .claimed = false, .sp = 0, .rd = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = [_]V{
    vec("add sp, #0", .{ .hw1 = 0xB000 }, .{}),
    vec("add sp, #4", .{ .hw1 = 0xB001 }, .{ .sp = 0x2000_0404 }),
    vec("add sp, #508", .{ .hw1 = 0xB07F }, .{ .sp = 0x2000_05FC }),
    vec("add sp wraps modulo 2^32", .{ .hw1 = 0xB002, .sp = 0xFFFF_FFFC }, .{ .sp = 0x0000_0004 }),
    vec("add sp leaves the flags", .{ .hw1 = 0xB001, .nzcv = 0xF }, .{ .sp = 0x2000_0404, .nzcv = 0xF }),
    vec("sub sp, #0", .{ .hw1 = 0xB080 }, .{}),
    vec("sub sp, #4", .{ .hw1 = 0xB081 }, .{ .sp = 0x2000_03FC }),
    vec("sub sp, #508", .{ .hw1 = 0xB0FF }, .{ .sp = 0x2000_0204 }),
    vec("sub sp wraps modulo 2^32", .{ .hw1 = 0xB082, .sp = 0x0000_0004 }, .{ .sp = 0xFFFF_FFFC }),
    vec("sub sp leaves the flags", .{ .hw1 = 0xB081, .nzcv = 0x6 }, .{ .sp = 0x2000_03FC, .nzcv = 0x6 }),
    vec("add r0, sp, #0", .{ .hw1 = 0xA800 }, .{ .rd = 0x2000_0400 }),
    vec("add r7, sp, #4", .{ .hw1 = 0xAF01, .rd = 7 }, .{ .rd = 0x2000_0404 }),
    vec("add r3, sp, #1020", .{ .hw1 = 0xABFF, .rd = 3 }, .{ .rd = 0x2000_07FC }),
    vec("add rd, sp wraps and leaves the flags", .{ .hw1 = 0xAA02, .rd = 2, .sp = 0xFFFF_FFFC, .nzcv = 0x9 }, .{ .sp = 0xFFFF_FFFC, .rd = 0x0000_0004, .nzcv = 0x9 }),
    vec("adr r0, #0 at a word-aligned address", .{ .hw1 = 0xA000 }, .{ .rd = 0x0000_1004 }),
    vec("adr r0, #0 at a halfword address aligns PC down", .{ .hw1 = 0xA000, .address = 0x1002 }, .{ .rd = 0x0000_1004 }),
    vec("adr r7, #4", .{ .hw1 = 0xA701, .rd = 7 }, .{ .rd = 0x0000_1008 }),
    vec("adr r5, #1020 from a halfword address", .{ .hw1 = 0xA5FF, .rd = 5, .address = 0x1002 }, .{ .rd = 0x0000_1400 }),
    vec("adr leaves the flags", .{ .hw1 = 0xA101, .rd = 1, .nzcv = 0xF }, .{ .rd = 0x0000_1008, .nzcv = 0xF }),
    vec("ldr rt, [sp] belongs to the loads", .{ .hw1 = 0x9800 }, none),
    vec("cbz belongs to cbz", .{ .hw1 = 0xB100 }, none),
    vec("sxth belongs to extend", .{ .hw1 = 0xB200 }, none),
    vec("the 32-bit space is unclaimed", .{ .hw1 = 0xB001, .size = 4 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);

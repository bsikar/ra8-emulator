//! Conformance vectors for the decode group `push_pop` (RA8EMU-279): PUSH
//! and POP T1 on the Main stack in Thread mode. Expected values are worked
//! from the Arm ARM (DDI0553): registers go lowest-numbered at the lowest
//! address, PUSH stores below SP and lowers it by four per register, POP
//! loads from SP and raises it, POP into PC interworks on bit 0, and a
//! PUSH whose lowest address would fall under MSPLIM writes nothing and
//! leaves SP alone. An empty list is UNPREDICTABLE and left unclaimed.
const vector = @import("../vector.zig");

/// Where SP starts, and the window PUSH writes into just below it.
pub const stack_top: u32 = 0x2000_0300;
pub const window: u32 = stack_top - 16;

/// Before the instruction: rN holds `reg_base + N` for r0..r12, LR holds
/// `lr`, and the four words at SP hold `stack`.
pub const reg_base: u32 = 0x1000_0000;
pub const lr: u32 = 0x0000_2001;

pub const In = struct {
    hw1: u16,
    size: u8 = 2,
    sp: u32 = stack_top,
    msplim: u32 = 0,
    stack: [4]u32 = .{ 0xC000_0000, 0xC000_0001, 0xC000_0002, 0xC000_0003 },
};

/// How the instruction ended.
pub const Fault = enum { none, unaligned, stack_overflow, other };

/// Whether the group claims the encoding, how it ended, then SP, the four
/// words of the window, r0..r7, LR, PC and EPSR.T afterwards.
pub const Out = struct {
    claimed: bool = true,
    fault: Fault = .none,
    sp: u32 = stack_top,
    below: [4]u32 = .{ 0, 0, 0, 0 },
    low: [8]u32 = initial_low,
    lr: u32 = lr,
    pc: u32 = 0x1004,
    thumb: bool = true,
};

pub const initial_low: [8]u32 = .{ reg_base, reg_base + 1, reg_base + 2, reg_base + 3, reg_base + 4, reg_base + 5, reg_base + 6, reg_base + 7 };

const V = vector.Vector(In, Out);
const group = "push_pop";
const none: Out = .{ .claimed = false };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn r(n: u32) u32 {
    return reg_base + n;
}

fn low(changes: []const struct { u3, u32 }) [8]u32 {
    var out = initial_low;
    for (changes) |c| out[c[0]] = c[1];
    return out;
}

pub const all = [_]V{
    vec("push {r0}", .{ .hw1 = 0xB401 }, .{ .sp = stack_top - 4, .below = .{ 0, 0, 0, r(0) } }),
    vec("push {r0-r3}", .{ .hw1 = 0xB40F }, .{ .sp = stack_top - 16, .below = .{ r(0), r(1), r(2), r(3) } }),
    vec("push {r1, r3, r7} packs in register order", .{ .hw1 = 0xB48A }, .{ .sp = stack_top - 12, .below = .{ 0, r(1), r(3), r(7) } }),
    vec("push {r4, lr}", .{ .hw1 = 0xB510 }, .{ .sp = stack_top - 8, .below = .{ 0, 0, r(4), lr } }),
    vec("push {lr} alone", .{ .hw1 = 0xB500 }, .{ .sp = stack_top - 4, .below = .{ 0, 0, 0, lr } }),
    vec("push {r0-r7, lr} puts LR highest", .{ .hw1 = 0xB5FF }, .{ .sp = stack_top - 36, .below = .{ r(5), r(6), r(7), lr } }),
    vec("push landing exactly on MSPLIM", .{ .hw1 = 0xB401, .msplim = stack_top - 4 }, .{ .sp = stack_top - 4, .below = .{ 0, 0, 0, r(0) } }),
    vec("push under MSPLIM writes nothing", .{ .hw1 = 0xB403, .msplim = stack_top - 4 }, .{ .fault = .stack_overflow }),
    vec("pop {r0}", .{ .hw1 = 0xBC01 }, .{ .sp = stack_top + 4, .low = low(&.{.{ 0, 0xC000_0000 }}) }),
    vec("pop {r0-r3}", .{ .hw1 = 0xBC0F }, .{ .sp = stack_top + 16, .low = .{ 0xC000_0000, 0xC000_0001, 0xC000_0002, 0xC000_0003, r(4), r(5), r(6), r(7) } }),
    vec("pop {r2, r5} fills in register order", .{ .hw1 = 0xBC24 }, .{ .sp = stack_top + 8, .low = low(&.{ .{ 2, 0xC000_0000 }, .{ 5, 0xC000_0001 } }) }),
    vec("pop {pc} interworks to Thumb", .{ .hw1 = 0xBD00, .stack = .{ 0x0000_4001, 0, 0, 0 } }, .{ .sp = stack_top + 4, .pc = 0x0000_4000 }),
    vec("pop {r4, pc} loads PC last", .{ .hw1 = 0xBD10, .stack = .{ 0x1111_1111, 0x0000_5003, 0, 0 } }, .{ .sp = stack_top + 8, .low = low(&.{.{ 4, 0x1111_1111 }}), .pc = 0x0000_5002 }),
    vec("pop {pc} with bit 0 clear clears EPSR.T", .{ .hw1 = 0xBD00, .stack = .{ 0x0000_4000, 0, 0, 0 } }, .{ .sp = stack_top + 4, .pc = 0x0000_4000, .thumb = false }),
    vec("an empty push list is unclaimed", .{ .hw1 = 0xB400 }, none),
    vec("an empty pop list is unclaimed", .{ .hw1 = 0xBC00 }, none),
    vec("the 32-bit space is unclaimed", .{ .hw1 = 0xB401, .size = 4 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);

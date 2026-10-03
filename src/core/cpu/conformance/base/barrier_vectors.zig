//! Conformance vectors for the decode group `barrier` (RA8EMU-278): DSB,
//! DMB and ISB (T1) with any 4-bit option, SSBB and PSSBB (DSB options 0000
//! and 0100) included. The Arm ARM (DDI0553) gives them no architectural
//! effect on registers or flags; on a core that runs one access at a time in
//! program order and fetches every instruction fresh they are all already
//! satisfied, so each vector checks the core state survives untouched. The
//! other op values under F3BF 8Fx_ (CLREX among them), a clear hw2 bit 15
//! or 8, the hint space and the 16-bit space are left unclaimed.
const vector = @import("../vector.zig");

/// The flags held before the instruction (N, C and Q), which must survive.
pub const flags: u32 = 0xA800_0000;
/// What r0 and r12 hold before the instruction, which must survive.
pub const seed: u32 = 0x1234_5678;

pub const In = struct {
    hw1: u16 = 0xF3BF,
    hw2: u16,
    size: u8 = 4,
};

/// Whether the group claims the encoding, then r0, r12 and NZCVQ after.
pub const Out = struct {
    claimed: bool = true,
    r0: u32 = seed,
    r12: u32 = seed,
    flags: u32 = flags,
};

const V = vector.Vector(In, Out);
const group = "barrier";
const none: Out = .{ .claimed = false, .r0 = 0, .r12 = 0, .flags = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn ok(name: []const u8, hw2: u16) V {
    return vec(name, .{ .hw2 = hw2 }, .{});
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = [_]V{
    ok("dsb sy changes nothing", 0x8F4F),
    ok("dsb ish changes nothing", 0x8F4B),
    ok("dsb oshst changes nothing", 0x8F42),
    ok("ssbb (dsb option 0000) changes nothing", 0x8F40),
    ok("pssbb (dsb option 0100) changes nothing", 0x8F44),
    ok("dmb sy changes nothing", 0x8F5F),
    ok("dmb ish changes nothing", 0x8F5B),
    ok("dmb ishst changes nothing", 0x8F5A),
    ok("dmb option 0000 changes nothing", 0x8F50),
    ok("isb sy changes nothing", 0x8F6F),
    ok("isb option 0000 changes nothing", 0x8F60),
    ok("isb option 1010 changes nothing", 0x8F6A),
    bad("op 0000 is unclaimed", 0xF3BF, 0x8F0F),
    bad("op 0001 is unclaimed", 0xF3BF, 0x8F1F),
    bad("clrex belongs to the exclusives", 0xF3BF, 0x8F2F),
    bad("op 0011 is unclaimed", 0xF3BF, 0x8F3F),
    bad("op 0111 is unclaimed", 0xF3BF, 0x8F7F),
    bad("op 1000 is unclaimed", 0xF3BF, 0x8F8F),
    bad("hw2 bit 8 clear is unclaimed", 0xF3BF, 0x8E4F),
    bad("hw2 bit 15 clear is unclaimed", 0xF3BF, 0x0F4F),
    bad("hw2 bit 13 set is unclaimed", 0xF3BF, 0xAF4F),
    bad("hw1 F3BE is unclaimed", 0xF3BE, 0x8F4F),
    bad("the hint space is unclaimed", 0xF3AF, 0x8000),
    vec("the 16-bit space is unclaimed", .{ .hw2 = 0x8F4F, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);

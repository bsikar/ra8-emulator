//! Conformance vectors for the decode group `hint` (RA8EMU-279): NOP,
//! YIELD, WFE, WFI and SEV in both widths, the reserved hints, and BTI. Each
//! expected value is worked from the Arm ARM (DDI0553): SEV sets the event
//! register; WFE clears it when set and otherwise waits, which with no
//! exception source may complete at once, as may WFI; reserved hint numbers
//! (DBG, ESB and CSDB included) execute as NOPs; BTI clears EPSR.B on an
//! Armv8.1-M core. The wide PACBTI, PAC and AUT numbers belong to the
//! PACBTI group, and a narrow encoding with a nonzero mask is IT.
const vector = @import("../vector.zig");

/// The instruction, its size, the event register and EPSR.B beforehand.
pub const In = struct {
    hw1: u16,
    hw2: u16 = 0,
    size: u8 = 2,
    event: bool = false,
    bti: bool = false,
};

/// Whether the group claims the encoding, then the event register, whether
/// the core is left waiting, and EPSR.B afterwards (all zero when
/// unclaimed).
pub const Out = struct {
    claimed: bool = true,
    event: bool = false,
    waiting: bool = false,
    bti: bool = false,
};

const V = vector.Vector(In, Out);
const group = "hint";
const none: Out = .{ .claimed = false };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn wide(hw2: u16, event: bool, bti: bool) In {
    return .{ .hw1 = 0xF3AF, .hw2 = hw2, .size = 4, .event = event, .bti = bti };
}

pub const all = [_]V{
    vec("nop", .{ .hw1 = 0xBF00 }, .{}),
    vec("yield keeps the event register", .{ .hw1 = 0xBF10, .event = true }, .{ .event = true }),
    vec("wfe with the event set clears it", .{ .hw1 = 0xBF20, .event = true }, .{}),
    vec("wfe with nothing to wake it completes", .{ .hw1 = 0xBF20 }, .{}),
    vec("wfi with nothing to wake it completes", .{ .hw1 = 0xBF30 }, .{}),
    vec("sev sets the event register", .{ .hw1 = 0xBF40 }, .{ .event = true }),
    vec("narrow hint 5 is a reserved NOP", .{ .hw1 = 0xBF50, .event = true }, .{ .event = true }),
    vec("narrow hint 15 is a reserved NOP", .{ .hw1 = 0xBFF0 }, .{}),
    vec("a nonzero mask is IT, not a hint", .{ .hw1 = 0xBF08 }, none),
    vec("nop.w", wide(0x8000, false, false), .{}),
    vec("wfe.w with the event set clears it", wide(0x8002, true, false), .{}),
    vec("sev.w sets the event register", wide(0x8004, false, false), .{ .event = true }),
    vec("esb.w is a NOP", wide(0x8010, true, false), .{ .event = true }),
    vec("csdb.w is a NOP", wide(0x8014, false, false), .{}),
    vec("dbg.w #0 is a NOP", wide(0x80F0, false, false), .{}),
    vec("bti.w clears EPSR.B", wide(0x800F, false, true), .{}),
    vec("pacbti.w belongs to PACBTI", wide(0x800D, false, false), none),
    vec("pac.w belongs to PACBTI", wide(0x801D, false, false), none),
    vec("aut.w belongs to PACBTI", wide(0x802D, false, false), none),
    vec("hw2 0x81xx is not a hint", wide(0x8100, false, false), none),
};

pub const covered = vector.encodingsOf(In, Out, &all);

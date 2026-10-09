//! Conformance vectors for the decode group `blxns` (RA8EMU-279). The
//! encoding is the Arm ARM's (DDI0553) BLXNS T1. With bit 0 of Rm clear the
//! core becomes Non-secure, so SP is the Non-secure bank's (RA8EMU-32); with
//! it set the call is a BLX that stays Secure, LR holding the address after
//! it with the Thumb bit. A Non-secure call pushes the return frame on the
//! Secure stack and leaves FNC_RETURN in LR (RA8EMU-171), and SP moves to
//! the Non-secure table's initial stack only when VTOR_NS is set and the
//! table can be read. Rm of SP or PC, BXNS, BLX and the 32-bit space are
//! left unclaimed.
const vector = @import("../vector.zig");

/// The halfword, the register holding the target and its value, SP, and
/// the Non-secure vector table: VTOR_NS (zero when clear), whether the
/// table is mapped, and its initial stack.
pub const In = struct {
    hw1: u16,
    size: u8 = 2,
    rm: u4 = 0,
    target: u32 = 0x2000_0180,
    sp: u32 = 0x2000_0400,
    vtor_ns: u32 = 0,
    table_mapped: bool = true,
    ns_sp: u32 = 0,
};

/// Whether the group claims the encoding, then PC, LR, SP and the security
/// state afterwards (all zero when unclaimed). The BLXNS sits at 0x1000.
pub const Out = struct {
    claimed: bool = true,
    pc: u32 = 0,
    lr: u32 = 0,
    sp: u32 = 0,
    secure: bool = false,
};

const V = vector.Vector(In, Out);
const group = "blxns";
const none: Out = .{ .claimed = false };
const ret: u32 = 0x1003;
const fnc: u32 = 0xFEFF_FFFF;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = [_]V{
    vec("blxns r0 with VTOR_NS clear runs on the Non-secure bank's stack", .{ .hw1 = 0x4784 }, .{ .pc = 0x2000_0180, .lr = fnc }),
    vec("blxns r2 takes the Non-secure initial stack", .{ .hw1 = 0x4794, .rm = 2, .target = 0x0020_0400, .vtor_ns = 0x0020_0000, .ns_sp = 0x2002_0000 }, .{ .pc = 0x0020_0400, .lr = fnc, .sp = 0x2002_0000 }),
    vec("an unreadable Non-secure table leaves the bank's stack", .{ .hw1 = 0x4794, .rm = 2, .target = 0x0020_0400, .vtor_ns = 0x0020_0000, .table_mapped = false }, .{ .pc = 0x0020_0400, .lr = fnc }),
    vec("bit 0 of the target set is a BLX that stays Secure", .{ .hw1 = 0x47A4, .rm = 4, .target = 0x0001_2345 }, .{ .pc = 0x0001_2344, .lr = ret, .sp = 0x2000_0400, .secure = true }),
    vec("blxns r12", .{ .hw1 = 0x47E4, .rm = 12, .target = 0x0000_8000 }, .{ .pc = 0x0000_8000, .lr = fnc }),
    vec("blxns lr branches to the old LR and overwrites it", .{ .hw1 = 0x47F4, .rm = 14, .target = 0x0000_9000 }, .{ .pc = 0x0000_9000, .lr = fnc }),
    vec("blxns sp is unclaimed", .{ .hw1 = 0x47EC }, none),
    vec("blxns pc is unclaimed", .{ .hw1 = 0x47FC }, none),
    vec("bxns r0 is unclaimed", .{ .hw1 = 0x4704 }, none),
    vec("blx r0 is unclaimed", .{ .hw1 = 0x4780 }, none),
    vec("the 32-bit space is unclaimed", .{ .hw1 = 0x4784, .size = 4 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);

//! Conformance vectors for the decode group `tt` (RA8EMU-278): TT, TTT, TTA
//! and TTAT (T1). Expected values are worked from the Arm ARM (DDI0553),
//! TT_RESP: Rd gets the response for the address in Rn. With no MPU the
//! MPU half is the default map (MREGION and MRVALID zero, R and RW set),
//! and with no attribution source every address answers Secure, with S set
//! only when the TT runs in Secure state. A source's word keeps its
//! security fields; the MPU-owned fields it carries are replaced, and an
//! address it marks Non-secure (NSR) gets NSR and NSRW from R and RW. Rn =
//! PC, Rd = SP or PC, hw2[5:0] not zero, hw2[15:12] not all ones, other
//! hw1 values and the 16-bit space are left unclaimed.
const vector = @import("../vector.zig");

/// Rn holds `target`; Rd holds `rd_in` before the run.
pub const target: u32 = 0x2000_0100;
pub const rd_in: u32 = 0xDEAD_BEEF;
/// TT_RESP R and RW, and with S for a Secure answer.
const r_rw: u32 = 0x000C_0000;
const secure_word: u32 = 0x004C_0000;

pub const In = struct {
    hw1: u16 = 0xE841,
    hw2: u16 = 0xF000,
    size: u8 = 4,
    /// Run in Non-secure state.
    ns: bool = false,
    /// Run unprivileged in Thread mode.
    unprivileged: bool = false,
    /// Attach an attribution source that answers `resp`.
    source: bool = false,
    resp: u32 = 0,
};

/// Which security state the core asked the source about.
pub const Asked = enum { not_asked, secure, non_secure };

/// Whether the group claims the encoding, Rd after, and what the source was
/// asked.
pub const Out = struct {
    claimed: bool = true,
    rd: u32 = secure_word,
    asked: Asked = .not_asked,
};

const V = vector.Vector(In, Out);
const group = "tt";
pub const none: Out = .{ .claimed = false, .rd = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = forms ++ sourced ++ unclaimed;

const forms = [_]V{
    vec("tt r0, r1 in secure state", .{}, .{}),
    vec("ttt r0, r1", .{ .hw2 = 0xF040 }, .{}),
    vec("tta r0, r1", .{ .hw2 = 0xF080 }, .{}),
    vec("ttat r0, r1", .{ .hw2 = 0xF0C0 }, .{}),
    vec("tt r2, r1 in non-secure state has no s", .{ .hw2 = 0xF200, .ns = true }, .{ .rd = r_rw }),
    vec("ttt r2, r1 in non-secure state", .{ .hw2 = 0xF240, .ns = true }, .{ .rd = r_rw }),
    vec("tt r0, r1 unprivileged", .{ .unprivileged = true }, .{}),
    vec("tt r1, r1 overwrites the address", .{ .hw2 = 0xF100 }, .{}),
    vec("tt r12, r1", .{ .hw2 = 0xFC00 }, .{}),
    vec("tt lr, r1", .{ .hw2 = 0xFE00 }, .{}),
    vec("tt r0, sp", .{ .hw1 = 0xE84D }, .{}),
    vec("tt r0, lr", .{ .hw1 = 0xE84E }, .{}),
};

const sourced = [_]V{
    vec("a secure answer keeps its region fields and drops the mpu ones", .{ .source = true, .resp = 0x05C3_037F }, .{ .rd = 0x05CE_0300, .asked = .secure }),
    vec("a non-secure answer gains nsr and nsrw", .{ .source = true, .resp = 0x0012_0200 }, .{ .rd = 0x003E_0200, .asked = .secure }),
    vec("a bare answer gets only the default map", .{ .source = true, .resp = 0 }, .{ .rd = r_rw, .asked = .secure }),
    vec("non-secure state asks the source as non-secure", .{ .source = true, .ns = true, .resp = 0x0010_0000 }, .{ .rd = 0x003C_0000, .asked = .non_secure }),
    vec("tta asks from the current state", .{ .hw2 = 0xF080, .source = true, .resp = 0x0040_0000 }, .{ .rd = secure_word, .asked = .secure }),
};

const unclaimed = [_]V{
    bad("rn = pc is unclaimed", 0xE84F, 0xF000),
    bad("rd = sp is unclaimed", 0xE841, 0xFD00),
    bad("rd = pc is unclaimed", 0xE841, 0xFF00),
    bad("hw2[0] set is unclaimed", 0xE841, 0xF001),
    bad("hw2[5] set is unclaimed", 0xE841, 0xF020),
    bad("hw2[15:12] = 1110 is unclaimed", 0xE841, 0xE000),
    bad("hw1 0xE851 is unclaimed", 0xE851, 0xF000),
    bad("hw1 0xE941 is unclaimed", 0xE941, 0xF000),
    vec("the 16-bit space is unclaimed", .{ .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);

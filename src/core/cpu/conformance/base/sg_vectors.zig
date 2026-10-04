//! Conformance vectors for the decode group `sg` (RA8EMU-278): SG (T1),
//! the Secure Gateway, 0xE97F 0xE97F. Expected values are worked from the
//! Armv8-M SG pseudocode in the Arm ARM (DDI0553): in Secure state SG is a
//! NOP wherever it was fetched; in Non-secure state, fetched from
//! Non-secure memory it is a NOP, fetched from Non-secure callable memory it
//! makes the core Secure (the banked SP comes back) and clears LR bit 0, and
//! fetched from Secure memory it is a SecureFault INVEP with nothing
//! changed. With no attribution source every address is Secure. Any other
//! halfword pair and the 16-bit space are left unclaimed.
//!
//! These vectors cover the instruction alone; the fetch-time checks
//! (INVEP for a non-SG fetch from callable memory, INVTRAN for a Secure
//! fetch from Non-secure memory) sit in Cpu.step and its own tests.
const vector = @import("../vector.zig");

/// The Secure and Non-secure stack pointers, and LR before every run.
pub const s_sp: u32 = 0x2000_0300;
pub const ns_sp: u32 = 0x2000_0280;
pub const lr_in: u32 = 0x2000_0181;

/// Which state the attribution source answers for the fetch address, or
/// no source at all.
pub const Attr = enum { none, secure, non_secure, callable };

pub const In = struct {
    hw1: u16 = 0xE97F,
    hw2: u16 = 0xE97F,
    size: u8 = 4,
    /// The core starts in Non-secure state.
    ns: bool = false,
    attr: Attr = .none,
    lr: u32 = lr_in,
};

/// How the instruction ended.
pub const Fault = enum { none, invalid_entry, other };

/// Whether the group claims the encoding, how it ended, whether the core
/// is Secure after, and LR and SP after.
pub const Out = struct {
    claimed: bool = true,
    fault: Fault = .none,
    secure: bool = true,
    lr: u32 = lr_in,
    sp: u32 = s_sp,
};

const V = vector.Vector(In, Out);
const group = "sg";
const none: Out = .{ .claimed = false, .secure = false, .lr = 0, .sp = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

/// A Non-secure core that SG leaves as it was.
const ns_kept: Out = .{ .secure = false, .sp = ns_sp };

pub const all = secure ++ non_secure ++ unclaimed;

const secure = [_]V{
    vec("sg in secure state with no attribution is a nop", .{}, .{}),
    vec("sg in secure state from secure memory is a nop", .{ .attr = .secure }, .{}),
    vec("sg in secure state from callable memory is a nop", .{ .attr = .callable }, .{}),
    vec("sg in secure state from non-secure memory is a nop", .{ .attr = .non_secure }, .{}),
    vec("sg in secure state keeps an even lr", .{ .attr = .callable, .lr = 0x2000_0180 }, .{ .lr = 0x2000_0180 }),
};

const non_secure = [_]V{
    vec("sg from callable memory enters secure state", .{ .ns = true, .attr = .callable }, .{ .lr = 0x2000_0180 }),
    vec("sg from callable memory keeps an even lr even", .{ .ns = true, .attr = .callable, .lr = 0x2000_0180 }, .{ .lr = 0x2000_0180 }),
    vec("sg from callable memory clears only lr bit 0", .{ .ns = true, .attr = .callable, .lr = 0xFFFF_FFFF }, .{ .lr = 0xFFFF_FFFE }),
    vec("sg from non-secure memory is a nop", .{ .ns = true, .attr = .non_secure }, ns_kept),
    vec("sg from secure memory faults invep", .{ .ns = true, .attr = .secure }, .{ .fault = .invalid_entry, .secure = false, .sp = ns_sp }),
    vec("sg with no attribution faults invep", .{ .ns = true }, .{ .fault = .invalid_entry, .secure = false, .sp = ns_sp }),
};

const unclaimed = [_]V{
    bad("hw2 0xE97E is unclaimed", 0xE97F, 0xE97E),
    bad("hw1 0xE97E is unclaimed", 0xE97E, 0xE97F),
    bad("hw2 0x0000 is unclaimed", 0xE97F, 0x0000),
    bad("hw1 0xE96F is unclaimed", 0xE96F, 0xE97F),
    bad("hw2 0xF97F is unclaimed", 0xE97F, 0xF97F),
    vec("the 16-bit space is unclaimed", .{ .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);

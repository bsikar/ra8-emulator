//! The additional state context (RA8EMU-168): what exception entry stacks
//! on top of the caller frame when a Non-secure exception preempts Secure
//! code, so the Non-secure handler never sees Secure callee registers.
//!
//! Ten words below the caller frame, lowest address first: the integrity
//! signature, a reserved word, then R4-R11. Bits 31:1 of the signature are
//! fixed; bit 0 is FType, clear when an FP context was stacked too
//! (DDI0553 B3.19). The return checks the signature before it trusts the
//! frame, and a mismatch is a SecureFault INVIS for the caller to raise.
const std = @import("std");
const bus = @import("../bus.zig");

pub const size: u32 = 0x28;
pub const words = 10;

/// The signature with bit 0 (FType) clear.
const sig_base: u32 = 0xFEFA_125A;

/// R4-R11, in register order.
pub const Callee = [8]u32;

pub const Error = bus.Error || error{Integrity};

/// The integrity signature for a frame that does (`fp`) or does not carry
/// an FP context.
pub fn signature(fp: bool) u32 {
    return if (fp) sig_base else sig_base | 1;
}

/// Stack `callee` below `sp`, which the caller frame already left 8-byte
/// aligned, and give back the new stack pointer.
pub fn push(to: bus.Bus, sp: u32, callee: Callee, fp: bool) bus.Error!u32 {
    const at = sp -% size;
    try put(to, at, signature(fp));
    try put(to, at +% 4, 0);
    for (callee, 0..) |word, i| try put(to, at +% 8 +% @as(u32, @intCast(i * 4)), word);
    return at;
}

pub const Popped = struct {
    callee: Callee,
    /// Where the caller frame starts.
    sp: u32,
};

/// Read the context at `at` back. The signature must match the FType the
/// return asks for; nothing is taken off the stack when it does not.
pub fn pop(from: bus.Bus, at: u32, fp: bool) Error!Popped {
    if (try from.readWord(at) != signature(fp)) return error.Integrity;
    var callee: Callee = undefined;
    for (&callee, 0..) |*word, i| word.* = try from.readWord(at +% 8 +% @as(u32, @intCast(i * 4)));
    return .{ .callee = callee, .sp = at +% size };
}

fn put(to: bus.Bus, address: u32, word: u32) bus.Error!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, word, .little);
    try to.write(address, &bytes);
}

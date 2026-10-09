//! The basic exception stack frame: R0-R3, R12, LR, the return address and
//! xPSR, eight words at an 8-byte-aligned address.
//!
//! Armv8-M always aligns the frame (CCR.STKALIGN is RES1). When the stack
//! pointer was only 4-byte aligned, the frame starts one word lower and bit 9
//! of the stacked xPSR records it, so the return can put the pointer back.
const std = @import("std");
const bus = @import("../bus.zig");

pub const size: u32 = 0x20;
pub const words = 8;
/// Bit 9 of the stacked xPSR: the frame was realigned.
pub const realigned: u32 = 1 << 9;

/// Frame word indices.
pub const slot = struct {
    pub const r12: usize = 4;
    pub const lr: usize = 5;
    pub const return_address: usize = 6;
    pub const xpsr: usize = 7;
};

pub const Frame = [words]u32;

/// Push `frame` below `sp` and give back the new stack pointer. The xPSR
/// word gets bit 9 from the alignment.
pub fn push(to: bus.Bus, sp: u32, frame: Frame) bus.Error!u32 {
    const pad = sp & 4;
    const at = (sp -% size) & ~pad;
    var stacked = frame;
    stacked[slot.xpsr] &= ~realigned;
    if (pad != 0) stacked[slot.xpsr] |= realigned;
    for (stacked, 0..) |word, i| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, word, .little);
        try to.write(at +% @as(u32, @intCast(i * 4)), &bytes);
    }
    return at;
}

pub const Popped = struct {
    frame: Frame,
    /// The stack pointer once the frame, and any realignment word, is gone.
    sp: u32,
};

pub fn pop(from: bus.Bus, at: u32) bus.Error!Popped {
    var frame: Frame = undefined;
    for (&frame, 0..) |*word, i| word.* = try from.readWord(at +% @as(u32, @intCast(i * 4)));
    const pad: u32 = if (frame[slot.xpsr] & realigned != 0) 4 else 0;
    return .{ .frame = frame, .sp = (at +% size) | pad };
}

//! Where a GPT channel's registers sit, and how a narrow store finds one.
//!
//! A channel window is 0x100 wide (ra8_gpt_regs.h `r_gpt_channel_regs_t`,
//! HUM Ch 22 register map p 879) and this model interprets eight of its
//! words; the rest it shadows. Two questions come up on every access and
//! neither belongs to the counting: which word a byte offset lands in, so a
//! byte or half-word store reaches the right register instead of falling
//! through to the shadow, and whether this model interprets that word at
//! all, which is the set GTWP's protection covers.
const std = @import("std");

const buf = @import("gpt_buffer.zig");
const compare = @import("gpt_compare.zig");

/// Channel-local offsets of the registers this model interprets
/// (ra8_gpt_regs.h lines 55..80).
pub const off = struct {
    pub const gtstr: u32 = 0x04;
    pub const gtstp: u32 = 0x08;
    pub const gtclr: u32 = 0x0C;
    pub const gtcr: u32 = 0x2C;
    pub const gtst: u32 = 0x3C;
    pub const gtcnt: u32 = 0x48;
    pub const gtpr: u32 = 0x64;
};

/// The words this model interprets, as opposed to the rest of the window it
/// only shadows.
const cells = [_]u32{
    off.gtstr, off.gtstp, off.gtclr, off.gtcr,
    off.gtst,  off.gtcnt, off.gtpr,  buf.off.gtber,
};

/// The register a byte offset belongs to, so a narrow store lands on the
/// right word instead of falling through to the shadow.
pub fn cellOf(local: u32) u32 {
    for (cells) |cell| {
        if (local >= cell and local < cell + 4) return cell;
    }
    return local;
}

/// Does this model interpret the register at this offset? GTWP's protection
/// covers exactly these, which is the set the HAL brackets between its keys.
pub fn interpreted(local: u32) bool {
    if (compare.which(local) != null or buf.which(local) != null) return true;
    for (cells) |cell| {
        if (local >= cell and local < cell + 4) return true;
    }
    return false;
}

/// One byte lane out of a word.
pub fn lane(value: u32, index: u32) u8 {
    return @truncate(value >> @intCast(index * 8));
}

/// A word with one byte lane replaced.
pub fn merge(value: u32, index: u32, byte: u8) u32 {
    const shift: u5 = @intCast(index * 8);
    const mask = ~(@as(u32, 0xFF) << shift);
    return (value & mask) | (@as(u32, byte) << shift);
}

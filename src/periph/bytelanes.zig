//! Byte lanes of a window whose registers are not all one word wide.
//!
//! `src/periph/lanes.zig` covers the ordinary case: a window of 32-bit
//! registers, where a narrow access reaches part of one register and the
//! arithmetic is a cut and a merge. Some windows are the other way round. The
//! RIIC registers are every one of them a byte (HUM Ch 39.2), and the DTC
//! window mixes 8-, 16- and 32-bit registers inside the same word. On both,
//! ONE ACCESS CAN NAME SEVERAL WHOLE REGISTERS, and each of them has to be
//! answered.
//!
//! The rule the callers share: AN ACCESS IS THE BYTES IT NAMES, LOW LANE
//! FIRST. A read assembles them right-justified, the low lane in bits 0..7,
//! which is what `registry.mask` hands back to the core. A write hands each
//! byte to the register that owns it in ascending order, so a store that
//! enables a block in one lane and asks it to do something in the next does
//! those two things in the order the driver wrote them.
//!
//! Order is the whole point on RIIC: ICCR1 sits at +0x00 and ICCR2 at +0x01,
//! and a driver that enables the interface and STARTs in one halfword store
//! means enable, then START. Descending would refuse the START on a disabled
//! interface and count it as an access to a dead block.

/// How many bytes an access of this width names. Width reaches a block as
/// 1, 2 or 4; anything else is a whole word, matching `registry.mask`.
pub fn span(width: u3) u32 {
    return switch (width) {
        1 => 1,
        2 => 2,
        else => 4,
    };
}

/// Where in the answer the byte `index` lanes up from the start address sits.
pub fn shift(index: u32) u5 {
    return @intCast(index * 8);
}

/// The byte of `value` the register `index` lanes up from the start address
/// is given.
pub fn byteAt(value: u32, index: u32) u8 {
    return @truncate(value >> shift(index));
}

/// Fold a register's answer into the assembled read at its lane.
pub fn place(answer: u32, byte: u8, index: u32) u32 {
    return answer | (@as(u32, byte) << shift(index));
}

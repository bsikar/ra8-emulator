//! How wide an access to the RIIC window is answered.
//!
//! Every RIIC register is a byte (HUM Ch 39.2), so unlike the 32-bit windows
//! in `src/periph/lanes.zig` there is no word to cut a narrow access out of.
//! The opposite problem applies: ONE ACCESS CAN NAME SEVERAL WHOLE REGISTERS,
//! and each of them has to be answered.
//!
//! The rule the block follows: AN ACCESS IS THE BYTES IT NAMES, LOW LANE
//! FIRST. A read assembles them right-justified, the low lane in bits 0..7,
//! which is what `registry.mask` hands back to the core. A write hands each
//! byte to the register that owns it in ascending order, so a store that
//! enables the interface in one lane and requests a condition in the next
//! does those two things in the order the driver wrote them.
//!
//! Order is the whole point on this block: ICCR1 sits at +0x00 and ICCR2 at
//! +0x01, and a driver that enables and STARTs in one halfword store means
//! enable, then START. Descending would refuse the START on a disabled
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

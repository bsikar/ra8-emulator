//! Tail predication (RA8EMU-236): the arithmetic behind DLSTP, WLSTP, LETP
//! and VCTP, as pure functions over LR, FPSCR.LTPSIZE and VPR, following
//! the Arm ARM (DDI0553) pseudocode for LE/LETP, VCTP and the element mask
//! (GetCurInstrBeat).
//!
//! LTPSIZE is the element size of the loop as log2 of its bytes (0 byte,
//! 1 halfword, 2 word, 3 doubleword); 4 means no tail predication. Inside a
//! tail-predicated loop LR counts elements still to process, so the last
//! iteration masks every element past LR.
const Vpr = @import("predicate.zig").Vpr;

/// LTPSIZE when no tail-predicated loop is running.
pub const none: u3 = 4;

/// Elements in one 128-bit vector at element size `ltpsize`.
pub fn perVector(ltpsize: u3) u32 {
    return @as(u32, 1) << @intCast(4 - @as(u4, @min(ltpsize, none)));
}

/// The low `bytes` bits of a P0-shaped mask set.
fn lowBits(bytes: u32) u16 {
    if (bytes >= 16) return 0xFFFF;
    return @intCast((@as(u32, 1) << @intCast(bytes)) - 1);
}

/// The P0-shaped mask tail predication leaves active: every byte unless a
/// loop is running and LR has fewer elements left than a vector holds.
pub fn mask(ltpsize: u3, lr: u32) u16 {
    if (ltpsize >= none or lr > perVector(ltpsize)) return 0xFFFF;
    return lowBits(lr << ltpsize);
}

/// VCTP's predicate before it merges into VPR: the first `rn` elements of
/// size `size` active, the rest clear.
pub fn vctpMask(size: u2, rn: u32) u16 {
    if (rn >= perVector(size)) return 0xFFFF;
    return lowBits(rn << size);
}

/// VCTP: P0 takes the predicate on the bytes this instruction executes
/// (`beats`, the ECI view as a P0-shaped mask), ANDed with the element
/// mask in force (`active`); bytes it does not execute keep their P0 bit.
pub fn vctp(vpr: Vpr, size: u2, rn: u32, active: u16, beats: u16) Vpr {
    const fresh = vctpMask(size, rn) & active;
    var out = vpr;
    out.p0 = (vpr.p0 & ~beats) | (fresh & beats);
    return out;
}

/// What DLSTP and WLSTP leave: LR the element count, LTPSIZE the element
/// size. WLSTP with a zero count skips the loop and leaves both alone.
pub const Start = struct {
    lr: u32,
    ltpsize: u3,
    enter: bool,
};

pub fn start(size: u2, count: u32, while_form: bool, lr: u32, ltpsize: u3) Start {
    if (while_form and count == 0) return .{ .lr = lr, .ltpsize = ltpsize, .enter = false };
    return .{ .lr = count, .ltpsize = size, .enter = true };
}

/// What LETP leaves: another iteration with LR down one vector of
/// elements, or the exit with LR untouched and LTPSIZE back to 4.
pub const End = struct {
    lr: u32,
    ltpsize: u3,
    again: bool,
};

pub fn end(lr: u32, ltpsize: u3) End {
    const step = perVector(ltpsize);
    if (lr <= step) return .{ .lr = lr, .ltpsize = none, .again = false };
    return .{ .lr = lr - step, .ltpsize = ltpsize, .again = true };
}

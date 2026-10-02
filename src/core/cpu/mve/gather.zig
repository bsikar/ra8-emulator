//! MVE gather loads and scatter stores with a vector of offsets, VLDRB/
//! VLDRH/VLDRW [Rn, Qm] and VSTRB/VSTRH/VSTRW [Rn, Qm] (RA8EMU-25), from
//! their pseudocode in the Arm ARM (DDI0553). Element e of Qm, read
//! unsigned at the register width, offsets Rn for element e; with
//! `uxtw #n` (os) it is first scaled by the memory size. Memory widths
//! narrower than the element sign- or zero-extend on load and truncate on
//! store through contiguous.element. The 64-bit VLDRD/VSTRD forms move
//! each doubleword as two word beats addressed by `beatAddress`.
const qreg = @import("qreg.zig");
const Size = qreg.Size;

pub const Form = struct { msize: Size, esize: Size, signed: bool, store: bool, os: bool };

/// Whether the encoding names an access the architecture defines:
/// memory no wider than the element, os never with bytes, and a signed
/// load only when it widens. Stores are unsigned.
pub fn valid(f: Form) bool {
    const m = @intFromEnum(f.msize);
    const e = @intFromEnum(f.esize);
    if (m > e) return false;
    if (f.os and f.msize == .byte) return false;
    if (f.signed) return !f.store and m < e;
    return true;
}

pub const Address = struct { base: u32, offset: u32, msize: Size, os: bool };

/// The address element e touches: Rn plus its offset, scaled when os.
pub fn address(a: Address) u32 {
    const shift: u5 = if (a.os) @intFromEnum(a.msize) else 0;
    return a.base +% (a.offset << shift);
}

/// One 32-bit beat of a 64-bit VLDRD/VSTRD gather or scatter: the even
/// word of the doubleword's Qm pair offsets both beats, scaled by 8 under
/// uxtw #3, and the odd beat sits four bytes above the even one.
pub const Beat = struct { base: u32, offset: u32, os: bool, odd: bool };

pub fn beatAddress(b: Beat) u32 {
    const shift: u5 = if (b.os) 3 else 0;
    const high: u32 = if (b.odd) 4 else 0;
    return b.base +% (b.offset << shift) +% high;
}

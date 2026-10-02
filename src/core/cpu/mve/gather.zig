//! MVE gather loads and scatter stores with a vector of offsets, VLDRB/
//! VLDRH/VLDRW [Rn, Qm] and VSTRB/VSTRH/VSTRW [Rn, Qm] (RA8EMU-25), from
//! their pseudocode in the Arm ARM (DDI0553). Element e of Qm, read
//! unsigned at the register width, offsets Rn for element e; with
//! `uxtw #n` (os) it is first scaled by the memory size. Memory widths
//! narrower than the element sign- or zero-extend on load and truncate on
//! store through contiguous.element. The 64-bit VLDRD/VSTRD forms are not
//! modelled here yet.
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

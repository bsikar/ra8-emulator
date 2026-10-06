//! The M85's Auxiliary Fault Status Register (0xE000_ED3C), which says
//! which interface a BusFault came from (Cortex-M85 TRM 101924 issue 05,
//! 5.3 and Table 5-4). Bits [20:10] belong to a precise BusFault, valid only
//! with BFSR.PRECISERR set; every bit is write one to clear.
//!
//! Only what silicon was seen to do is modelled. On the EK-RA8D2 a data
//! read at 0, into the ITCM window the board leaves unpopulated, takes a
//! precise BusFault with AFSR = 0x0008_0000: PPOISON, "Precise fault that
//! is caused by RPOISON or TEBRx.POISON" (RA8EMU-495's secure_boot_hil
//! capture, RA8EMU-715). Every other refusal leaves AFSR alone, because no
//! capture says what it would set.

const memmap = @import("../core/memmap.zig");

/// AFSR.PPOISON [19].
pub const ppoison: u32 = 1 << 19;

/// The AFSR bits a precise BusFault on a data access to `address` raises.
pub fn forData(address: u32) u32 {
    if (address >= memmap.itcm_base and address < memmap.itcm_end) return ppoison;
    return 0;
}

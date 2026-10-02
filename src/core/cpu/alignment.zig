//! The alignment check the memory groups share (DDI0553 MemA and MemU).
//!
//! MemA accesses (LDM/STM, PUSH/POP, LDRD/STRD, the exclusives, and the FP
//! loads and stores) must be aligned to their size whatever CCR.UNALIGN_TRP
//! says. An unaligned one is an UNALIGNED UsageFault; until the core takes
//! UsageFault through the fault model (RA8EMU-39) it stops on it instead.
//! MemU (LDR/STR/LDRH/STRH) faulting under UNALIGN_TRP is the next slice of
//! RA8EMU-85.

pub const Error = error{Unaligned};

/// A MemA access of `size` bytes (1, 2, 4 or 8; 8 checks word alignment, as
/// LDRD/STRD do) at `address`.
pub fn memA(address: u32, size: u32) Error!void {
    const need: u32 = if (size >= 4) 4 else size;
    if (address & (need - 1) != 0) return error.Unaligned;
}

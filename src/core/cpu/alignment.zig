//! The alignment check the memory groups share (DDI0553 MemA and MemU).
//!
//! MemA accesses (LDM/STM, PUSH/POP, LDRD/STRD, the exclusives, and the FP
//! loads and stores) must be aligned to their size whatever CCR.UNALIGN_TRP
//! says. An unaligned one is an UNALIGNED UsageFault; until the core takes
//! UsageFault through the fault model (RA8EMU-39) it stops on it instead.
//! MemU accesses (LDR/STR/LDRH/STRH and their signed and wide forms) go
//! through unaligned unless the firmware set CCR.UNALIGN_TRP.
const bus = @import("bus.zig");

pub const Error = error{Unaligned};

pub const ccr: u32 = 0xE000_ED14;
pub const unalign_trp: u32 = 1 << 3;

/// A MemA access of `size` bytes (1, 2, 4 or 8; 8 checks word alignment, as
/// LDRD/STRD do) at `address`.
pub fn memA(address: u32, size: u32) Error!void {
    const need: u32 = if (size >= 4) 4 else size;
    if (address & (need - 1) != 0) return error.Unaligned;
}

/// A MemU access of `size` bytes at `address`. CCR is read only when the
/// access is unaligned; a bus with no SCS behind it counts as UNALIGN_TRP
/// clear.
pub fn memU(on: bus.Bus, address: u32, size: u32) Error!void {
    if (size < 2 or address & (size - 1) == 0) return;
    const value = on.readWord(ccr) catch 0;
    if (value & unalign_trp != 0) return error.Unaligned;
}

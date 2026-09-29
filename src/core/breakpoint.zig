//! The instruction address a run stops at.
//!
//! `--stop-sym` watches a counter in RAM, which answers "did the firmware
//! get as far as counting N of something". It cannot answer the question a
//! wall actually raises, which is whether a given function was entered at
//! all. Reading the C to decide that is guesswork, and on the SD provision
//! wall it has now been wrong twice.
//!
//! So this is the other half: an address execution stops at the first time
//! it arrives. The engine hands it to the emulator as the point to run
//! until, so the stop costs nothing per instruction and lands on the first
//! instruction of the function rather than at the chunk boundary after it.
//!
//! The interesting verdict is the negative one. A run that ends without
//! arriving proves the firmware never called that function, which is the
//! evidence a command trace cannot give: a function that issues no bus
//! access leaves no trace either way.
const std = @import("std");

/// How the address is compared, and what an unset break runs until.
pub const limits = struct {
    /// The Thumb interworking bit. A symbol may carry it and a program
    /// counter may carry it; neither says anything about which address
    /// was meant, so it is cleared on both sides of the comparison.
    pub const thumb_bit: u32 = 1;
    /// What a run with no break asks to run until: an address no image
    /// reaches, so the emulator stops on the instruction count alone.
    pub const unreachable_address: u64 = 0xFFFF_FFFF;
};

pub const Break = struct {
    /// Where to stop, resolved from the image's symbol table before the
    /// run starts.
    address: u32,
    /// Set when execution arrived. This is what tells the report the run
    /// ended at the break rather than spending its budget.
    reached: bool = false,

    /// The address to run until, as the emulator wants it.
    pub fn until(self: Break) u64 {
        return @as(u64, entry(self.address));
    }

    /// Did execution arrive at the break?
    ///
    /// Called at a chunk boundary with the program counter as it stands.
    /// Arriving is a one-way latch: a later boundary somewhere else does
    /// not un-reach a break that was already met.
    pub fn met(self: *Break, pc: u32) bool {
        if (entry(pc) != entry(self.address)) return false;
        self.reached = true;
        return true;
    }
};

/// An address with the interworking bit cleared.
fn entry(address: u32) u32 {
    return address & ~limits.thumb_bit;
}

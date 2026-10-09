//! CPUID: which processor a core says it is.
//!
//! The RA8 parts carry two different Cortex-M cores against one board, a
//! Cortex-M85 as CPU0 and a Cortex-M33 as CPU1, and each answers CPUID out of
//! its own System Control Space. The PPB is plain RAM in this model, so
//! without a primed word both cores read zero, which is no processor at all.
//!
//!   CPUID 0xE000_ED00 (DDI0553 D1.2.47), read-only
//!     Implementer  [31:24]  0x41, Arm
//!     Variant      [23:20]  the major revision, the r in rNpM
//!     Architecture [19:16]  0xF, the CPUID scheme every Armv8-M core uses
//!     PartNo       [15:4]   0xD23 Cortex-M85, 0xD21 Cortex-M33
//!     Revision     [3:0]    the minor revision, the p in rNpM
//!
//! The part numbers are Arm's (the same ones pyOCD names its cores by). The
//! revision fields are r0p0 here: which silicon revision the RA8 cores carry
//! is not settled, and nothing in the tree reads them yet.

/// Where every core finds its own CPUID.
pub const address: u32 = 0xE000_ED00;

pub const field = struct {
    pub const implementer_shift: u5 = 24;
    pub const architecture_shift: u5 = 16;
    pub const partno_shift: u5 = 4;
    pub const partno_mask: u32 = 0xFFF << partno_shift;
};

pub const implementer = struct {
    pub const arm: u32 = 0x41;
};

/// The CPUID scheme Armv7-M and Armv8-M cores report in Architecture.
pub const architecture: u32 = 0xF;

pub const partno = struct {
    pub const cortex_m85: u12 = 0xD23;
    pub const cortex_m33: u12 = 0xD21;
};

/// One processor's CPUID word, built from its part number at r0p0.
pub fn word(number: u12) u32 {
    return (implementer.arm << field.implementer_shift) |
        (architecture << field.architecture_shift) |
        (@as(u32, number) << field.partno_shift);
}

/// The two cores this board carries.
pub const cpu0: u32 = word(partno.cortex_m85);
pub const cpu1: u32 = word(partno.cortex_m33);

/// The part number a CPUID word names.
pub fn part(value: u32) u12 {
    return @intCast((value & field.partno_mask) >> field.partno_shift);
}

/// Put this core's CPUID in its own PPB word, so the first read names the
/// processor rather than the zero the mapping starts at.
pub fn prime(core: anytype, value: u32) !void {
    try core.writeWord(address, value);
}

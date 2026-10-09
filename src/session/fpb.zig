//! The Flash Patch and Breakpoint unit as firmware programs it: FP_CTRL,
//! FP_REMAP and the instruction comparators FP_COMP0..7, at 0xE000_2000.
//!
//! This is the Armv8-M FPB, version 2. Each comparator holds an address
//! with bit 0 as its enable (BE); the unit as a whole is enabled through
//! FP_CTRL.ENABLE, and a write to FP_CTRL only lands when it carries
//! KEY. Armv8-M has no remap and no literal comparators, so FP_REMAP reads
//! zero and ignores writes. Each core has its own unit.
//!
//! The model is the register file and the question the debug core asks of
//! it: does a comparator match this instruction address. Halting the core
//! on a match goes through the stop machine, the same way a debugger break
//! does.
pub const base: u32 = 0xE000_2000;

pub const offsets = struct {
    pub const ctrl: u32 = 0x000;
    pub const remap: u32 = 0x004;
    pub const comp0: u32 = 0x008;
};

pub const limits = struct {
    /// Instruction comparators on the M85 and on the RA8 M33.
    pub const comparators: usize = 8;
    /// The bytes the register file spans from `base`.
    pub const span: u32 = offsets.comp0 + comparators * 4;
};

pub const ctrl_bits = struct {
    pub const enable: u32 = 1 << 0;
    pub const key: u32 = 1 << 1;
    /// FPB version 2, the Armv8-M layout, in FP_CTRL.REV.
    pub const rev_v2: u32 = 1 << 28;
};

/// FP_COMPn.BE: this comparator breaks.
pub const comp_enable: u32 = 1 << 0;

pub const Fpb = struct {
    enabled: bool = false,
    comps: [limits.comparators]u32 = @splat(0),

    /// The register at `offset` from `base`, or null when the offset is
    /// not one of the unit's registers.
    pub fn read(self: *const Fpb, offset: u32) ?u32 {
        if (offset == offsets.ctrl) return ctrlValue(self.enabled);
        if (offset == offsets.remap) return 0;
        const index = compIndex(offset) orelse return null;
        return self.comps[index];
    }

    /// Write the register at `offset`. False when the offset is not one of
    /// the unit's registers, so the caller can treat it as unclaimed.
    pub fn write(self: *Fpb, offset: u32, value: u32) bool {
        if (offset == offsets.ctrl) {
            if (value & ctrl_bits.key != 0) self.enabled = value & ctrl_bits.enable != 0;
            return true;
        }
        if (offset == offsets.remap) return true;
        const index = compIndex(offset) orelse return false;
        self.comps[index] = value;
        return true;
    }

    /// The comparator that matches an instruction at `pc`, when the unit
    /// is enabled and one of its enabled comparators holds that address.
    pub fn matches(self: *const Fpb, pc: u32) ?usize {
        if (!self.enabled) return null;
        for (self.comps, 0..) |comp, index| {
            if (comp & comp_enable != 0 and comp & ~comp_enable == pc & ~@as(u32, 1)) return index;
        }
        return null;
    }
};

/// FP_CTRL as read: version 2, eight code comparators split across
/// NUM_CODE[6:4] and NUM_CODE[14:12], no literal comparators, KEY as zero.
fn ctrlValue(enabled: bool) u32 {
    const code: u32 = limits.comparators;
    const low = (code & 0x7) << 4;
    const high = (code >> 3) << 12;
    return ctrl_bits.rev_v2 | high | low | @intFromBool(enabled);
}

fn compIndex(offset: u32) ?usize {
    if (offset < offsets.comp0 or offset >= limits.span or offset % 4 != 0) return null;
    return (offset - offsets.comp0) / 4;
}

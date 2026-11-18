//! The Flash Patch and Breakpoint unit as firmware programs it: FP_CTRL,
//! FP_REMAP and the instruction comparators FP_COMPn, at 0xE000_2000.
//!
//! This is the Armv8-M FPB, version 2. Each comparator holds an address
//! with bit 0 as its enable (BE); the unit as a whole is enabled through
//! FP_CTRL.ENABLE, and a write to FP_CTRL only lands when it carries
//! KEY. Armv8-M has no remap and no literal comparators, so FP_REMAP reads
//! zero and ignores writes. Each core has its own unit and comparator count.
pub const base: u32 = 0xE000_2000;

pub const offsets = struct {
    pub const ctrl: u32 = 0x000;
    pub const remap: u32 = 0x004;
    pub const comp0: u32 = 0x008;
};

pub const limits = struct {
    /// Default instruction comparators on the RA8 M85 and M33.
    pub const comparators: usize = 8;
    /// Maximum 5-bit NUM_CODE value an Armv8-M FPB unit can advertise.
    pub const max_comparators: usize = 31;
    /// Default register file span from `base` for 8 comparators.
    pub const span: u32 = offsets.comp0 + comparators * 4;
    /// Full architectural comparator span from `base`.
    pub const max_span: u32 = offsets.comp0 + max_comparators * 4;
};

pub const ctrl_bits = struct {
    pub const enable: u32 = 1 << 0;
    pub const key: u32 = 1 << 1;
    /// FPB version 2, the Armv8-M layout, in FP_CTRL.REV.
    pub const rev_v2: u32 = 1 << 28;
};

/// FP_COMPn.BE: this comparator breaks.
pub const comp_enable: u32 = 1 << 0;

/// FP_CTRL reset word for `num_code` instruction comparators.
pub fn ctrlReset(num_code: u5) u32 {
    return ctrlValue(false, num_code);
}

/// FP_CTRL as read: version 2, `num_code` split across NUM_CODE[6:4] and
/// NUM_CODE[14:12], no literal comparators, KEY read as zero.
pub fn ctrlValue(enabled: bool, num_code: u5) u32 {
    const code: u32 = num_code;
    const low = (code & 0x7) << 4;
    const high = (code >> 3) << 12;
    return ctrl_bits.rev_v2 | high | low | @intFromBool(enabled);
}

pub const Fpb = struct {
    enabled: bool = false,
    num_code: u5 = limits.comparators,
    comps: [limits.max_comparators]u32 = @splat(0),

    /// The register at `offset` from `base`, or null when the offset is
    /// not one of the unit's implemented registers.
    pub fn read(self: *const Fpb, offset: u32) ?u32 {
        if (offset == offsets.ctrl) return ctrlValue(self.enabled, self.num_code);
        if (offset == offsets.remap) return 0;
        const index = self.compIndex(offset) orelse return null;
        return self.comps[index];
    }

    /// Write the register at `offset`. False when the offset is not one of
    /// the unit's implemented registers, so the caller can treat it as unclaimed.
    pub fn write(self: *Fpb, offset: u32, value: u32) bool {
        if (offset == offsets.ctrl) {
            if (self.num_code > 0 and value & ctrl_bits.key != 0) {
                self.enabled = value & ctrl_bits.enable != 0;
            }
            return true;
        }
        if (offset == offsets.remap) return true;
        const index = self.compIndex(offset) orelse return false;
        self.comps[index] = value;
        return true;
    }

    /// The comparator that matches an instruction at `pc`, when the unit
    /// is enabled and one of its enabled comparators holds that address.
    pub fn matches(self: *const Fpb, pc: u32) ?usize {
        if (!self.enabled) return null;
        for (self.comps[0..self.num_code], 0..) |comp, index| {
            if (comp & comp_enable != 0 and comp & ~comp_enable == pc & ~@as(u32, 1)) return index;
        }
        return null;
    }

    fn compIndex(self: *const Fpb, offset: u32) ?usize {
        if (offset < offsets.comp0 or offset % 4 != 0) return null;
        const index = (offset - offsets.comp0) / 4;
        if (index >= self.num_code) return null;
        return index;
    }
};

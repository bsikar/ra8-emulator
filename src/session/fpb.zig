//! Re-export of the chip FPB register and comparator model (`ra8_chip.periph.fpb`).
const chip_fpb = @import("ra8_chip").periph.fpb;

pub const base = chip_fpb.base;
pub const offsets = chip_fpb.offsets;
pub const limits = chip_fpb.limits;
pub const ctrl_bits = chip_fpb.ctrl_bits;
pub const comp_enable = chip_fpb.comp_enable;
pub const ctrlReset = chip_fpb.ctrlReset;
pub const ctrlValue = chip_fpb.ctrlValue;
pub const Fpb = chip_fpb.Fpb;

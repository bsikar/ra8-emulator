//! Per-core System Control Space configuration: interrupt line count,
//! priority width, SAU and MPU region counts, DWT and FPB comparator counts,
//! initial VTOR seed, and SysTick calibration value.

/// Architectural upper bound on external interrupt lines in Armv8-M.
pub const max_irq_lines: u16 = 480;

/// Architectural 32-line register words covering `max_irq_lines` (15 full words,
/// inside the 16-word architectural NVIC array span).
pub const max_irq_words: u16 = 16;

/// Number of 32-bit NVIC register words needed to cover `lines` external IRQs.
pub fn irqWordsOf(lines: u16) u16 {
    const clamped = @min(lines, max_irq_lines);
    return (clamped + 31) / 32;
}

/// Bitmask of implemented lines in the last active 32-bit NVIC register word.
pub fn tailIrqMaskOf(lines: u16) u32 {
    const clamped = @min(lines, max_irq_lines);
    if (clamped == 0) return 0;
    const rem: u5 = @intCast(clamped % 32);
    if (rem == 0) return 0xFFFF_FFFF;
    return (@as(u32, 1) << rem) - 1;
}

/// Bitmask of implemented lines in NVIC register word `word` (0..15).
pub fn wordIrqMaskOf(lines: u16, word: u32) u32 {
    const words = irqWordsOf(lines);
    if (word >= words) return 0;
    if (word + 1 == words) return tailIrqMaskOf(lines);
    return 0xFFFF_FFFF;
}

/// Byte mask of implemented priority bits (top `bits` of an 8-bit priority field).
pub fn prioMaskOf(bits: u4) u8 {
    if (bits == 0) return 0;
    if (bits >= 8) return 0xFF;
    return @as(u8, 0xFF) << @intCast(8 - @as(u5, bits));
}

pub const ScsConfig = struct {
    irq_lines: u16 = 96,
    prio_bits: u4 = 4,
    sau_regions: u8 = 8,
    mpu_regions_s: u8 = 8,
    mpu_regions_ns: u8 = 8,
    dwt_comparators: ?u4 = null,
    fpb_code: u5 = 8,
    init_vtor: ?u32 = null,
    syst_calib: u32 = 0,

    pub fn irqWords(self: ScsConfig) u16 {
        return irqWordsOf(self.irq_lines);
    }

    pub fn tailIrqMask(self: ScsConfig) u32 {
        return tailIrqMaskOf(self.irq_lines);
    }

    pub fn wordIrqMask(self: ScsConfig, word: u32) u32 {
        return wordIrqMaskOf(self.irq_lines, word);
    }

    pub fn prioMask(self: ScsConfig) u8 {
        return prioMaskOf(self.prio_bits);
    }

    pub fn effectiveDwt(self: ScsConfig, is_m85: bool) u4 {
        return self.dwt_comparators orelse if (is_m85) 8 else 4;
    }

    pub fn effectiveSau(self: ScsConfig, security: bool) u8 {
        return if (!security) 0 else self.sau_regions;
    }
};

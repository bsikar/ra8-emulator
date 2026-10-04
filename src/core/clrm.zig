//! Armv8.1-M CLRM: clear a list of general registers and the APSR flags.
//!
//! The CMSE entry stub a compiler emits for a cmse_nonsecure_entry function
//! ends with `vscclrm` then `clrm {r1, r2, r3, ip, APSR}`, so no Secure value
//! leaks back to the Non-Secure caller. The pinned Unicorn rejects CLRM as an
//! invalid instruction, which stopped the TrustZone examples on their first
//! Non-Secure to Secure call. This file knows the encoding and nothing about
//! Unicorn; the Zig core runs it in src/core/cpu/ops/clrm.zig.
//!
//! Encoding T1: hw1 0xE89F, hw2 = P M 0 register_list. Bits 0..12 name r0 to
//! r12, bit 14 names LR and bit 15 names the APSR. Bit 13 (SP) must be clear
//! and an empty list is UNPREDICTABLE, so both are left to the core to fault.

pub const width: u32 = 4;
pub const first_half: u16 = 0xE89F;
pub const apsr_bit: u16 = 1 << 15;
pub const lr_bit: u16 = 1 << 14;
const sp_bit: u16 = 1 << 13;

pub const Instruction = struct {
    /// Bits 0..12 for r0..r12 and bit 14 for LR, in register order.
    registers: u16,
    apsr: bool,

    /// Whether general register `index` (0..14) is cleared.
    pub fn clears(self: Instruction, index: u4) bool {
        if (index == 13 or index == 15) return false;
        return self.registers & (@as(u16, 1) << index) != 0;
    }
};

pub fn decode(hw1: u16, hw2: u16) ?Instruction {
    if (hw1 != first_half) return null;
    if (hw2 & sp_bit != 0) return null;
    if (hw2 == 0) return null;
    return .{ .registers = hw2 & ~apsr_bit, .apsr = hw2 & apsr_bit != 0 };
}

/// The APSR with N, Z, C, V, Q and GE cleared, as CLRM leaves it. The rest
/// of xPSR (exception number, execution state) is not the APSR and stays.
pub fn clearedApsr(apsr: u32) u32 {
    return apsr & ~@as(u32, 0xF80F_0000);
}

/// How often the run needed the hook, reported like the selects next door.
pub const Clears = struct {
    stepped: usize = 0,

    pub fn quiet(self: Clears) bool {
        return self.stepped == 0;
    }
};

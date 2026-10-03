//! The RA8 IDAU (RA8EMU-277): what the part itself says about an address
//! before the SAU is asked.
//!
//! ADDRESS BIT 28 DECIDES IT (HUM 51.3.3.1, p3265). With bit 28 clear the
//! address is Secure, and the SAU may make it Non-secure callable but never
//! Non-secure; with it set the address is Non-secure. That is why the
//! firmware's trustzone_init.c runs Non-secure code from the bit-28 aliases
//! (0x12.. code, 0x32.. SRAM, 0x5.. peripherals) and marks exactly those
//! ranges Non-secure in the SAU (HUM p3267).
//!
//! SRAM IS SPLIT AT RUN TIME by SRAMSABAR0..3 (HUM 58.2.1, p3527; modelled
//! in cpscu_sram.zig). Each word holds an offset from the SRAM base: in its
//! bank, below the boundary is Secure and at or above it is Non-secure. So
//! the Non-secure SRAM alias is Non-secure only above the boundary of the
//! bank it falls in.
//!
//! The code MRAM split comes from option-setting memory and is not
//! modelled; the bit-28 rule alone answers for code. IREGION numbering was
//! not read from the HUM, so no answer names a region (TT's IRVALID stays
//! clear).

const sau = @import("sau.zig");
const sau_attr = @import("sau_attr.zig");
const cpscu_sram = @import("cpscu_sram.zig");

pub const alias_bit: u32 = 1 << 28;
pub const sram_ns_base: u32 = 0x3200_0000;

/// One SRAM bank as an offset span from the SRAM base.
pub const Bank = struct { first: u32, size: u32 };

/// RA8D2: SRAM0..2 512 KiB each and SRAM3 128 KiB, 0x2200_0000..0x221A_0000
/// (ra8_board_ek_ra8d2, ereader_m33.h).
pub const ra8d2_banks = [cpscu_sram.bank_count]Bank{
    .{ .first = 0x00_0000, .size = 0x8_0000 },
    .{ .first = 0x08_0000, .size = 0x8_0000 },
    .{ .first = 0x10_0000, .size = 0x8_0000 },
    .{ .first = 0x18_0000, .size = 0x2_0000 },
};

pub const Map = struct {
    /// The SRAMSABARn words. With none, SRAM follows the bit-28 rule alone.
    sram: ?*const cpscu_sram.Unit = null,
    banks: *const [cpscu_sram.bank_count]Bank = &ra8d2_banks,

    /// The IDAU's answer for `address`.
    pub fn answer(self: Map, address: u32) sau_attr.Idau {
        if (address & alias_bit == 0) return .{ .state = .callable };
        return .{ .state = self.sramState(address) };
    }

    /// The SAU and this IDAU together, as sau_attr.attribute combines them.
    pub fn attribute(self: Map, unit: *const sau.Sau, address: u32) sau_attr.Attribution {
        return sau_attr.attribute(unit, self.answer(address), address);
    }

    fn sramState(self: Map, address: u32) sau_attr.State {
        const words = self.sram orelse return .non_secure;
        if (address < sram_ns_base) return .non_secure;
        const offset = address - sram_ns_base;
        for (self.banks, 0..) |bank, index| {
            if (offset < bank.first or offset - bank.first >= bank.size) continue;
            return if (offset < words.sabar[index]) .secure else .non_secure;
        }
        return .non_secure;
    }
};

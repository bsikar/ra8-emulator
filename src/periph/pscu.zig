//! R_PSCU: the peripheral security attribution words, and the mask they hold
//! over the module-stop register beside them.
//!
//! (R_PSCU at 0x4020_4000, HUM Ch 51.8.1..51.8.4 "PSARB..PSARE" p 3284.) The
//! block opens with a reserved word and then carries one attribution register
//! per module-stop register: PSARB at +4 for MSTPCRB, PSARC at +8, PSARD at
//! +0xC, PSARE at +0x10. MSTPCRA has no PSAR at all, so its whole width stays
//! Secure-owned.
//!
//! PSAR bit N mirrors MSTPCRx bit N one for one, and a set bit means the
//! Secure side has delegated that peripheral to the Non-secure world. A
//! Secure write to a delegated module-stop bit is MASKED: the bit does not
//! change. So the PSAR value is directly the mask of bits a Secure write
//! cannot move, which is why mstp.zig consults this block on every store.
//!
//! WHY THIS IS NOT COSMETIC. ra8_mstp.c reads all four words at init
//! (priv_ra8_mstp_ns_mask_internal) and uses them as the DON'T-CARE mask of
//! its mandated read-back: `care = ~ns_mask`, then the settle poll checks
//! only the bits it owns. Its own comment says "on a non-TrustZone system the
//! mask is all-ones, so the check stays fully strict". While these four words
//! were unmodelled the bus answered out of an unmodelled cell, which
//! alternates 0 and 0xFFFF_FFFF per read, so the mask the driver got was a
//! function of how often the address had been touched rather than of the
//! attribution. Two consecutive reads of PSARB really do give 0 and then
//! 0xFFFF_FFFF. A read landing on the second phase makes `care` zero, and
//! the whole init read-back then passes without comparing anything: a
//! genuinely stuck MSTPCR register boots clean. Answering the attribution
//! is what makes it strict, and strict every time.
//!
//! No image here provisions TrustZone, so every PSAR reads its reset value of
//! 0 and the mask stays empty. The window is still modelled rather than
//! stubbed at zero, because a store has to be able to move it: an image that
//! delegates a peripheral must see the delegation take effect next door.
const std = @import("std");
const periph = @import("registry.zig");

/// CMSAMON/SFSAMON, the memory split monitors in this block (RA8EMU-420).
pub const samon = @import("samon.zig");

/// R_PSCU geometry. The Non-secure alias is folded onto this base by the bus
/// before it ever gets here, the same way the MSTP window is.
pub const win_base: u32 = 0x4020_4000;
pub const win_span: u32 = 0x14;

/// One word per MSTPCR register, indexed the way mstp.zig indexes its own
/// shadow: 0 is MSTPCRA's slot, which is the reserved word and owns nothing.
pub const word_count: usize = 5;

/// Reset value (HUM Ch 51.8.1 p 3284): every peripheral Secure-owned.
pub const reset: u32 = 0;

/// The attribution words, and what the firmware did to them.
pub const Unit = struct {
    words: [word_count]u32 = @splat(reset),
    /// Stores that landed on a real attribution word.
    stores: u32 = 0,
    /// Stores that named the reserved word at +0, which is not a register.
    reserved_stores: u32 = 0,

    pub fn quiet(self: *const Unit) bool {
        return self.stores == 0 and self.reserved_stores == 0 and !self.anyDelegated();
    }

    /// True once any peripheral has been handed to the Non-secure world.
    pub fn anyDelegated(self: *const Unit) bool {
        for (self.words) |word| {
            if (word != 0) return true;
        }
        return false;
    }

    /// The mask of MSTPCRx bits a Secure write cannot move. MSTPCRA has no
    /// attribution register, so nothing in it is ever delegated.
    pub fn nonsecureMask(self: *const Unit, register: usize) u32 {
        if (register == 0 or register >= word_count) return 0;
        return self.words[register];
    }

    fn slotOf(address: u32) ?usize {
        const offset = address -% win_base;
        if (offset >= win_span) return null;
        return offset / 4;
    }

    pub fn read(self: *Unit, address: u32, width: u3) u32 {
        _ = width;
        const slot = slotOf(address) orelse return 0;
        if (slot == 0) return 0;
        return self.words[slot];
    }

    pub fn write(self: *Unit, address: u32, width: u3, value: u32) void {
        _ = width;
        const slot = slotOf(address) orelse return;
        if (slot == 0) {
            self.reserved_stores +%= 1;
            return;
        }
        self.words[slot] = value;
        self.stores +%= 1;
    }

    pub fn block(self: *Unit) periph.Block {
        return .{
            .name = "PSCU",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Unit = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Unit = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

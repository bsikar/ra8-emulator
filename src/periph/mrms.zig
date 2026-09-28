//! MRMS: the code-MRAM frequency latches and the prefetch buffer in front
//! of them.
//!
//! Three 32-bit registers at the R_MRMS base (ra8_mrms_regs.h,
//! k_ra8_mrms_base_addr 0x4013_C000, HUM Ch 59.5 p 3551):
//!
//!   MRCPFB  (+0x000)  prefetch buffer enable, bit 0
//!   MRCFREQ (+0x004)  MRICLK frequency in MHz, key 0x1E in the top byte
//!   MREFREQ (+0x008)  MRPCLK frequency in MHz, key 0xE1 in the top byte
//!
//! THE TWO FREQUENCY REGISTERS ARE KEYED LATCHES, NOT WORDS. The key byte is
//! part of the WRITE and not part of the register: ra8_mrms_regs.h's
//! ra8_mrms_key_t says a write whose key byte is anything else is "silently
//! dropped (the register continues to read back its previous value)", and
//! the driver's own wait loop depends on the accepted value coming back
//! WITHOUT the key. internal_wait_mrm_freq in ra8_cgc.c is the whole
//! contract in six lines: it compares `*reg == freq_mhz`, and only if that
//! fails does it store `key | freq_mhz` and go round again, up to
//! k_ra8_cgc_mrm_spin_limit (0x40000) times before returning
//! k_ra8_err_hw_timeout. The host build cannot run that loop at all and says
//! so: its seam comment reads "plain host RAM cannot strip the key byte on
//! readback the way the silicon latch does".
//!
//! THE GAP THIS CLOSES, and it was in front of every other one. Nothing
//! modelled these three, so they fell to the sparse register file, which
//! answers a written address with the word that was written. MRCFREQ
//! therefore read back 0x1E0000FA rather than 250, the comparison could
//! never be true, and the loop spent all 0x40000 iterations before returning
//! a hardware timeout. That timeout is step 6 of ra8_cgc_init's protected
//! core, so ra8_cgc_init failed on EVERY RA8D2 image, and every app whose
//! first act is `if (ra8_cgc_init() != k_ra8_ok) panic_halt()` parked in its
//! halt loop before it touched a peripheral of its own. The counter the
//! emulator-in-the-loop suite watches never moved, and the run reported
//! nothing worse than a budget spent.
//!
//! Now the key gates the store and is not kept: a write carrying the right
//! key latches the low 24 bits and a write carrying any other key is dropped
//! and counted, so the driver's first re-store satisfies its own comparison
//! on the next read. MRCPFB has no key and is an ordinary retained word; the
//! three dummy reads the driver does after clearing it are reads like any
//! other.
//!
//! NOT MODELLED, AND NOT GUESSED: nothing downstream reads these. No wait
//! state is inserted, no MRAM access is slowed, and the prefetch buffer
//! buffers nothing, because this model has no memory timing for any of that
//! to show up in. What the registers carry is reported and nothing more. The
//! 0x4013_C000 page's wait-state and ECC registers above +0x008 are not
//! claimed here either: this window is the three the driver names.
const periph = @import("registry.zig");

/// Window geometry: the R_MRMS base and the three registers on it.
pub const win_base: u32 = 0x4013_C000;
pub const win_span: u32 = 0x0C;

/// Register offsets from `win_base` (ra8_mrms_offset_t).
pub const regs = struct {
    pub const mrcpfb: u32 = 0x00;
    pub const mrcfreq: u32 = 0x04;
    pub const mrefreq: u32 = 0x08;
};

/// The keys the two frequency latches demand, already in place in the top
/// byte (ra8_mrms_key_t).
pub const key = struct {
    pub const mrcfreq: u32 = 0x1E00_0000;
    pub const mrefreq: u32 = 0xE100_0000;
    /// The byte the key occupies; everything below it is the frequency.
    pub const mask: u32 = 0xFF00_0000;
};

/// MRCPFB bit 0, the prefetch buffer enable (ra8_mrms_pfb_t).
pub const prefetch_on: u32 = 0x01;

/// One keyed frequency latch: what it holds and what it turned away.
pub const Latch = struct {
    /// The key a store has to carry for this latch to accept it.
    wants: u32,
    /// The megahertz the latch holds. The key is never part of this.
    mhz: u32 = 0,
    /// Stores that carried the right key and landed.
    latched: u32 = 0,
    /// Stores dropped because the key byte was wrong.
    refused: u32 = 0,

    /// A store lands only with the right key, and only the frequency is
    /// kept, which is what lets the driver's readback match what it asked
    /// for.
    pub fn store(self: *Latch, value: u32) void {
        if (value & key.mask != self.wants) {
            self.refused +%= 1;
            return;
        }
        self.mhz = value & ~key.mask;
        self.latched +%= 1;
    }
};

/// The three registers, and what the run did to them.
pub const Mrms = struct {
    code: Latch = .{ .wants = key.mrcfreq },
    extra: Latch = .{ .wants = key.mrefreq },
    /// MRCPFB, retained as written.
    pfb: u32 = 0,

    /// An image that never brought the clocks up has nothing to narrate.
    pub fn quiet(self: *const Mrms) bool {
        return self.code.latched == 0 and self.code.refused == 0 and
            self.extra.latched == 0 and self.extra.refused == 0 and self.pfb == 0;
    }

    /// Whether the prefetch buffer is switched on right now.
    pub fn prefetching(self: *const Mrms) bool {
        return self.pfb & prefetch_on != 0;
    }

    pub fn read(self: *Mrms, address: u32, width: u3) u32 {
        _ = width;
        return switch (address -% win_base) {
            regs.mrcpfb => self.pfb,
            regs.mrcfreq => self.code.mhz,
            regs.mrefreq => self.extra.mhz,
            else => 0,
        };
    }

    pub fn write(self: *Mrms, address: u32, width: u3, value: u32) void {
        _ = width;
        switch (address -% win_base) {
            regs.mrcpfb => self.pfb = value,
            regs.mrcfreq => self.code.store(value),
            regs.mrefreq => self.extra.store(value),
            else => {},
        }
    }

    pub fn block(self: *Mrms) periph.Block {
        return .{
            .name = "MRMS",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Mrms = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Mrms = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

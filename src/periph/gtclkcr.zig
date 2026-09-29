//! GTCLKCR: the GPT bank's clock-domain register, which silicon will only let
//! firmware change while the block is still module-stopped.
//!
//! The last address in the EIL corpus nothing modelled: six of the 36 images
//! write 0x4032_3F10 with 1 and nothing answered, so the store fell through
//! to the anonymous shadow. It is the first thing ra8_gpt.c does, before any
//! GPT channel exists:
//!
//!   GTCLKCR (0x4032_3F10, 32b)  BPEN bit 0, ties GTCLK to PCLKA
//!
//! The address is k_ra8_gpt_gtclk_addr in libs/ra8_hal/inc/ra8_gpt_regs.h and
//! the bit is k_ra8_gptclkcr_bpen in ra8_gpt.c, which cites HUM Ch 22.2.47
//! p 974 for the register and Ch 22.10.1 p 1146 for the ordering.
//!
//! THE RULE, quoted by internal_gpt_clock_block_init from HUM Ch 22.2.47:
//! "Set first of initial setting after resetting. If MSTPCRE.MSTPE31 bit is
//! 0, changing this register is prohibited." An MSTP bit reads 1 while the
//! module is stopped and 0 once firmware has released it, so the register is
//! writable only BEFORE the release, which is why ra8_gpt.c programs it with
//! a static one-shot guard ahead of the first ra8_mstp_enable call and
//! Ch 22.10.1 says "Set GTCLKCR register before releasing the module-stop
//! state" in so many words.
//!
//! A shadow cell takes the store whenever it arrives, so firmware that
//! released the GPT block first and programmed the clock domain afterwards
//! came up here with BPEN set and came up on the bench with the block in the
//! undefined clock-domain-crossing state ra8_gpt.c's own comment describes,
//! where "writes to GTWP / GTCR / etc. silently drop" and "every J-Link or
//! firmware read of 0x40322000 onward returns 0 even after MSTPCR is
//! cleared". That is a bring-up bug the emulator would have hidden. Now a
//! store arriving after the release is prohibited: rejected, counted, and the
//! register keeps what it had.
//!
//! MSTPE31 is asked of the live module-stop model rather than tracked here,
//! and it is asked through the GPT family's own base address, so the bit this
//! consults is the one the HUM names.
//!
//! DELIBERATELY NOT MODELLED. The consequence, which is the bigger half: a
//! GPT channel whose bank never had BPEN programmed should drop its register
//! writes and read back zero. That belongs to the per-channel block, not to
//! this register, and `programmed()` is here for whatever takes it on. No
//! clock rate is derived either: BPEN selects PCLKA as the synchronous
//! source, and this emulator has no frequency behind PCLKA to select.
const periph = @import("registry.zig");
const mstp = @import("mstp.zig");

pub const win_base: u32 = 0x4032_3F10;
pub const win_span: u32 = 4;

/// The GPT family's first channel, whose module-stop bit is MSTPCRE.MSTPE31,
/// the bit HUM Ch 22.2.47 names. The register is bank-wide, one instance.
pub const bank_base: u32 = 0x4032_2000;

pub const bit = struct {
    /// BPEN: PCLKA and GTCLK run synchronously.
    pub const bpen: u32 = 1 << 0;
};

pub const Unit = struct {
    /// The board's live module-stop model, not a copy of it.
    modules: *const mstp.Mstp,
    value: u32 = 0,
    /// Stores that landed.
    stores: u32 = 0,
    /// Stores prohibited because the GPT block was already released.
    prohibited_running: u32 = 0,

    pub fn init(modules: *const mstp.Mstp) Unit {
        return .{ .modules = modules };
    }

    pub fn quiet(self: *const Unit) bool {
        return self.stores == 0 and self.prohibited_running == 0;
    }

    /// Whether the bank's clock domain was ever tied, which is what a later
    /// slice needs to decide if a GPT channel should answer at all.
    pub fn programmed(self: *const Unit) bool {
        return self.value & bit.bpen != 0;
    }

    /// True while MSTPCRE.MSTPE31 still reads 1, which is the only window the
    /// register may be changed in.
    fn stopped(self: *const Unit) bool {
        return self.modules.stopped(bank_base);
    }

    pub fn read(self: *Unit, address: u32, width: u3) u32 {
        _ = address;
        _ = width;
        return self.value;
    }

    pub fn write(self: *Unit, address: u32, width: u3, value: u32) void {
        _ = address;
        _ = width;
        if (!self.stopped()) {
            self.prohibited_running +%= 1;
            return;
        }
        self.value = value;
        self.stores +%= 1;
    }

    pub fn block(self: *Unit) periph.Block {
        return .{
            .name = "GTCLKCR",
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

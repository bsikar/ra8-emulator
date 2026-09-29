//! PLL1's configuration registers: PLLCCR, PLLCCR2 and MOSCWTCR, behind
//! PRCR.PRC0, with the divider code the hardware silently rejects.
//!
//! These three were the next most-written unmodelled addresses in the EIL
//! corpus after the low-power bytes: 26 of the 36 images write all three,
//! always the same values. They come from ra8_cgc.c's clock bring-up:
//! internal_start_main_osc writes MOSCWTCR = 9 before releasing the main
//! oscillator, and internal_program_and_start_pll1 writes PLLCCR = 0xFA02
//! and PLLCCR2 = 0x451, the EK-RA8D2 quickstart numbers (XTAL 24 MHz, /3 in,
//! x250.00, P=/2, Q=/6, R=/5), between stopping and restarting PLL1.
//!
//!   PLLCCR2  (0x4001_E04C, 16b)  PLODIVP[3:0] PLODIVQ[7:4] PLODIVR[11:8]
//!   MOSCWTCR (0x4001_E0A2,  8b)  main oscillator wait cycles
//!   PLLCCR   (0x4001_E0AC, 32b)  PLIDIV[1:0] PLSRCSEL[4] PLLMULNF[7:6]
//!                                PLLMUL[16:8]
//!
//! Offsets and field layouts are from libs/ra8_hal/inc/ra8_system_regs.h and
//! ra8_cgc_regs.h on zig/dev, which cite HUM Ch 9.2.6 p 331 (PLLCCR),
//! Ch 9.2.7 p 332 (PLLCCR2) and Ch 9.2.27 p 349 (MOSCWTCR) alongside the FSP
//! CMSIS header and bsp_clocks.c.
//!
//! Two rules make this worth modelling rather than storing.
//!
//! PRC0, the same gate sysclk.zig takes: these are CGC registers, and
//! ra8_cgc.c only reaches them inside RA8_PROTECTED_WRITE(unlock_cgc). A
//! store arriving with PRC0 clear is discarded by silicon with no fault and
//! no flag.
//!
//! And the one that is specific to PLLCCR2: the bit pattern 0000 in any of
//! PLODIVP, PLODIVQ or PLODIVR is "Setting prohibited" per HUM Ch 9.2.7, and
//! ra8_cgc_regs.h records what the hardware does with it in so many words:
//! the entire 16-bit register write is dropped and the register keeps its
//! previous value. That is why k_ra8_plodiv_div1 is absent from the firmware
//! enum. A model that stored the word anyway would let firmware configure a
//! PLL output ratio here that silicon never accepted, and the run would
//! report a clock tree the bench does not have.
//!
//! A narrow access is served the way the rest of SYSC serves one: a load is
//! cut to the lanes it names and a store is merged into the word, so the
//! bytes it leaves alone keep what they had. The PLLCCR2 rejection is judged
//! on the MERGED word, because that is the value the register would take.
//!
//! AND THE STOP BARRIER, which this file previously wrote off as a driver
//! contract and which the tree says outright is the hardware's. ra8_cgc.c's
//! own file header, step 3: "Stop PLL1 (PLLCR = 1), then poll OSCSF.PLLSF = 0.
//! Without this barrier, PLLCCR / PLLCCR2 writes are silently dropped and read
//! back as zero." That is not a precondition the driver keeps out of tidiness,
//! it is what silicon does, and internal_cgc_init_protected orders
//! internal_stop_pll1 before internal_program_and_start_pll1 for exactly that
//! reason. A model that stored the configuration while PLL1 was still running
//! would let firmware skip step 3 and still come up at the rate it asked for,
//! and the run would report a clock tree that only exists in the emulator: the
//! bench would keep the old multiplier, or zero. So a PLLCCR or PLLCCR2 store
//! arriving while OSCSF.PLL1SF is set is dropped and counted, and a later read
//! gives back what was there before, which before any successful store is
//! zero, the way the driver's note says.
//!
//! MOSCWTCR IS OUTSIDE THE BARRIER and deliberately so: it is the main
//! oscillator's wait count, written in step 1 by internal_start_main_osc,
//! before PLL1 is stopped at all, and nothing in the tree ties it to PLL1's
//! run state.
//!
//! DELIBERATELY NOT MODELLED. The reset values: nothing in the tree records
//! them, so the registers start at zero here and the report only speaks once
//! firmware has written. No frequency is derived: the multiplier and the four
//! ratios are reported as written, because turning them into megahertz would
//! need the XTAL rate, which this emulator does not model. Nor does anything
//! here check the core voltage range VSCR selected: step 2 is a brown-out
//! hazard rather than a rule the clock registers enforce, so it belongs to
//! whatever models the consequence, not to this file.
const periph = @import("registry.zig");
const prcr = @import("prcr.zig");
const oscsf = @import("oscsf.zig");
const div = @import("pll_div.zig");
const lanes = @import("lanes.zig");

/// The group these sit behind: PRC0, the clock generation circuit.
pub const guard: u16 = prcr.group.cgc;

pub const Slot = struct {
    address: u32,
    span: u32,
    name: []const u8,
};

/// Three registers scattered across the SYSC page, so each gets its own bus
/// window rather than one span that would swallow everything between them.
pub const slots = [_]Slot{
    .{ .address = 0x4001_E04C, .span = 2, .name = "PLLCCR2" },
    .{ .address = 0x4001_E0A2, .span = 1, .name = "MOSCWTCR" },
    .{ .address = 0x4001_E0AC, .span = 4, .name = "PLLCCR" },
};

pub const index = struct {
    pub const pllccr2: usize = 0;
    pub const moscwtcr: usize = 1;
    pub const pllccr: usize = 2;
};

/// Which register an access names. A wider or narrower access is answered by
/// the register whose window it lands in, the way the rest of SYSC is.
pub fn indexOf(address: u32) ?usize {
    for (&slots, 0..) |one, which| {
        if (address >= one.address and address < one.address + one.span) return which;
    }
    return null;
}

/// The retained words, plus what the run did to them.
pub const Unit = struct {
    protection: *const prcr.Prcr,
    /// The board's live oscillators, so PLL1's run state is read rather than
    /// tracked twice. Not a copy: the stop bit moves under this pointer.
    oscillators: *const oscsf.Oscillators,
    pllccr: u32 = 0,
    pllccr2: u16 = 0,
    moscwtcr: u8 = 0,
    /// Stores that landed.
    stores: u32 = 0,
    /// Stores dropped because PRCR.PRC0 was locked.
    dropped_locked: u32 = 0,
    /// Configuration stores dropped because PLL1 was still running.
    dropped_running: u32 = 0,
    /// PLLCCR2 stores rejected whole for carrying a prohibited divider code.
    prohibited_divider: u32 = 0,

    pub fn init(protection: *const prcr.Prcr, oscillators: *const oscsf.Oscillators) Unit {
        return .{ .protection = protection, .oscillators = oscillators };
    }

    pub fn quiet(self: *const Unit) bool {
        return self.stores == 0 and self.dropped_locked == 0 and
            self.dropped_running == 0 and self.prohibited_divider == 0;
    }

    /// Whether PLL1 is turning right now, which is what shuts the barrier.
    fn running(self: *const Unit) bool {
        return self.oscillators.running(oscsf.flag.pll1sf);
    }

    /// Whether firmware has configured PLL1 at all, which is what decides
    /// if the report has anything to say about it.
    pub fn configured(self: *const Unit) bool {
        return self.pllccr != 0 or self.pllccr2 != 0;
    }

    pub fn source(self: *const Unit) div.Source {
        return div.sourceOf(self.pllccr);
    }

    pub fn multiplier(self: *const Unit) div.Multiplier {
        return div.multiplierOf(self.pllccr);
    }

    /// The input divider ratio, or null when PLIDIV carries the code the
    /// part does not define.
    pub fn inputRatio(self: *const Unit) ?u8 {
        return div.inputRatio(div.inputCodeOf(self.pllccr));
    }

    /// P, Q and R output ratios. A null entry is a field never written or
    /// carrying a prohibited code, which a landed store cannot leave behind.
    pub fn outputRatios(self: *const Unit) [3]?u8 {
        const codes = div.outputCodesOf(self.pllccr2);
        return .{
            div.outputRatio(codes[0]),
            div.outputRatio(codes[1]),
            div.outputRatio(codes[2]),
        };
    }

    pub fn read(self: *Unit, address: u32, width: u3) u32 {
        const which = indexOf(address) orelse return 0;
        const word: u32 = switch (which) {
            index.pllccr2 => self.pllccr2,
            index.moscwtcr => self.moscwtcr,
            else => self.pllccr,
        };
        return lanes.part(word, address - slots[which].address, width);
    }

    pub fn write(self: *Unit, address: u32, width: u3, value: u32) void {
        const which = indexOf(address) orelse return;
        // Protection first: a store nobody unlocked never reaches the word.
        if (!self.protection.unlocked(guard)) {
            self.dropped_locked +%= 1;
            return;
        }
        // Step 3's barrier: the configuration pair takes nothing while PLL1
        // turns. MOSCWTCR is not part of that pair; see the header.
        if (which != index.moscwtcr and self.running()) {
            self.dropped_running +%= 1;
            return;
        }
        const at = address - slots[which].address;
        switch (which) {
            index.pllccr2 => self.storeOutputs(@truncate(lanes.merge(self.pllccr2, at, width, value))),
            index.moscwtcr => {
                self.moscwtcr = @truncate(lanes.merge(self.moscwtcr, at, width, value));
                self.stores +%= 1;
            },
            else => {
                self.pllccr = lanes.merge(self.pllccr, at, width, value);
                self.stores +%= 1;
            },
        }
    }

    /// PLLCCR2 takes the whole word or none of it: one prohibited field and
    /// silicon drops the write and keeps what was there.
    fn storeOutputs(self: *Unit, written: u16) void {
        if (!div.outputsAllowed(written)) {
            self.prohibited_divider +%= 1;
            return;
        }
        self.pllccr2 = written;
        self.stores +%= 1;
    }

    /// One bus entry per register.
    pub fn block(self: *Unit, which: usize) periph.Block {
        return .{
            .name = slots[which].name,
            .base = slots[which].address,
            .size = slots[which].span,
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

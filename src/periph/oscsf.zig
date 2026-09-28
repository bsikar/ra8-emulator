//! OSCSF: the oscillation stabilisation flags, and the four stop bits they
//! follow.
//!
//! Every clock source on this part is started by CLEARING a stop bit in its
//! own control register, and the driver then waits for the matching bit in
//! OSCSF to come up before it dares select that source. OSCSF is read-only:
//! hardware sets each bit "when the corresponding oscillator has stabilised"
//! (ra8_system_regs.h, the ra8_oscsf_bit_t doc comment).
//!
//!   PLLCR  (+0x02A, 8b) PLLSTP   b0   1 stops PLL1, 0 runs it
//!   MOSCCR (+0x032, 8b) MOSTP    b0   0 starts the XTAL, 1 stops it
//!   HOCOCR (+0x036, 8b) HCSTP    b0   0 operating, 1 stopped
//!   OSCSF  (+0x03C, 8b) HOCOSF b0, MOSCSF b3, PLL1SF b5, PLL2SF b6
//!   PLL2CR (+0x04A, 8b) PLL2STP  b0   1 stops PLL2, 0 runs it
//!
//! Bit positions are cited, not guessed: the stop bits from ra8_cgc_regs.h
//! line 287 (HCSTP), ra8_system_regs.h line 135 (MOSTP) and line 395
//! (PLL2STP), and ra8_cgc.c lines 180/188/189 (PLLSTP); the flag positions
//! from the ra8_oscsf_bit_t enum (hocosf 0, moscsf 3, pll1sf 5, pll2sf 6).
//! HUM Ch 9.2.21 p 344 is the OSCSF page the driver cites at each wait.
//!
//! THE GAP THIS CLOSES. None of these five registers was modelled, so all of
//! them fell to the bus catch-all, which answers an unmodelled address by
//! alternating zero and all-ones on successive reads so that a ready-bit poll
//! of either polarity eventually completes. That rescues a POLL and ruins a
//! CHECK. `priv_ra8_cgc_wait_oscsf_set` loops, so it got through on the second
//! read; but any single read of OSCSF is a coin flip, and the CGC driver does
//! exactly that in ra8_cgc_usb.c line 271, which tests PLL2SF once to decide
//! whether PLL2 is already running and skips the start when it reads set. On
//! the alternating fallback that answer had nothing to do with PLL2. Worse,
//! the flags did not follow the stop bits at all: firmware could stop PLL1 and
//! still read PLL1SF as set, or never start the main oscillator and read
//! MOSCSF as set, so a model that was supposed to catch a missing bring-up
//! step waved it through.
//!
//! Now the flag is computed from the stop bit every read: source running means
//! flag set, source stopped means flag clear, with no free-running component.
//! There is no stabilisation DELAY here and that is deliberate: this model has
//! no wall clock behind the oscillators, and a wait that never finishes would
//! be a worse lie than one that finishes at once. The driver's bounded spin
//! (k_ra8_cgc_osc_spin_limit, 0x40000) completes on its first read either way.
//!
//! RESET STATE. HOCO comes up running and the other three come up stopped.
//! The HOCO half is stated in the tree rather than assumed: ra8_cgc.h lines
//! 241 and 380 both record that a reset-value clock-source register "reads as
//! 0 (... = HOCO ~20 MHz)", which only makes sense with HOCO already running,
//! and ra8_cgc_use_hoco read-modify-writes HCSTP rather than assuming it. The
//! other three are stopped because every path that uses them starts them first
//! and waits, and ra8_cgc_usb.c line 271 exists precisely to find PLL2 down.
//!
//! PRCR.PRC0 GATES EVERY STORE HERE. These four control registers are in the
//! clock-generation family, which PRC0 protects: ra8_lpm.h lines 572-573 name
//! the group and state that "a write issued while PRC0 is locked is discarded
//! silently by the hardware" (HUM Ch 13.1 Table 13.1), and k_ra8_prcr_grp0_cgc
//! is that bit. So a store arriving with PRC0 locked is dropped and counted,
//! exactly as ckcr.zig right next door already does for the clock selects.
//! Reads are never gated, which is prcr.zig's rule and the hardware's.
//!
//! That silence is the point. ra8_cgc_use_hoco clears HCSTP at ra8_cgc.c:765
//! OUTSIDE any RA8_PROTECTED_WRITE window, wrapping only the SCKSCR store that
//! follows it (line 773), while the MOSCCR and PLLCR stores in the bring-up
//! path run inside ra8_cgc_init's protected core. A caller that reaches
//! ra8_cgc_use_hoco with PRC0 shut therefore loses its HOCOCR write on silicon
//! and keeps it in a model that gates nothing. This is the shape of the C
//! tree's issue #131, where a whole VBATT backup file was written with PRCR
//! locked: the bench reported failure and the emulator reported success.
//!
//! NOT MODELLED, AND NOT GUESSED: MOSCWTCR, PLLCCR, PLLCCR2, PLL2CCR and
//! PLL2CCR2 all sit inside this window and are retained as written, nothing
//! more. The multiplier and divider fields are not interpreted, no frequency
//! is derived from them, and OSCSF does not depend on them: a PLL whose
//! multiplier was never programmed still reports stable here. Wiring the
//! dividers into the modelled clock tree is its own slice.
const std = @import("std");
const periph = @import("registry.zig");
const prcr = @import("prcr.zig");

/// Window geometry: SYSC base 0x4001_E000, PLLCR (+0x02A) through PLL2CR
/// (+0x04A) inclusive.
pub const win_base: u32 = 0x4001_E02A;
pub const win_span: u32 = 0x21;

/// Register offsets from `win_base`.
pub const regs = struct {
    pub const pllcr: u32 = 0x00;
    pub const mosccr: u32 = 0x08;
    pub const hococr: u32 = 0x0C;
    pub const oscsf: u32 = 0x12;
    pub const pll2cr: u32 = 0x20;
};

/// Each control register carries its stop bit at bit 0.
pub const stop: u8 = 0x01;

/// The OSCSF bits, from the ra8_oscsf_bit_t enum.
pub const flag = struct {
    pub const hocosf: u8 = 1 << 0;
    pub const moscsf: u8 = 1 << 3;
    pub const pll1sf: u8 = 1 << 5;
    pub const pll2sf: u8 = 1 << 6;
};

/// One clock source: the control register that stops it and the flag it raises.
const Source = struct { control: u32, raises: u8 };

const sources = [_]Source{
    .{ .control = regs.hococr, .raises = flag.hocosf },
    .{ .control = regs.mosccr, .raises = flag.moscsf },
    .{ .control = regs.pllcr, .raises = flag.pll1sf },
    .{ .control = regs.pll2cr, .raises = flag.pll2sf },
};

/// The PRCR group that has to be open for a store to land: PRC0, the clock
/// generation circuit (k_ra8_prcr_grp0_cgc).
pub const guard: u16 = prcr.group.cgc;

/// The stop bits and the counters behind the end-of-run line.
pub const Oscillators = struct {
    /// The board's live protection model, not a copy of it.
    protection: *const prcr.Prcr,
    shadow: [win_span]u8,
    starts: u32 = 0,
    stops: u32 = 0,
    readonly_writes: u32 = 0,
    dropped_locked: u32 = 0,

    pub fn init(protection: *const prcr.Prcr) Oscillators {
        var self = Oscillators{
            .protection = protection,
            .shadow = [_]u8{0} ** win_span,
        };
        // HOCO running, the other three stopped. See the header.
        self.shadow[regs.mosccr] = stop;
        self.shadow[regs.pllcr] = stop;
        self.shadow[regs.pll2cr] = stop;
        return self;
    }

    /// Untouched units stay out of the end-of-run report.
    pub fn quiet(self: *const Oscillators) bool {
        return self.starts == 0 and self.stops == 0 and
            self.readonly_writes == 0 and self.dropped_locked == 0;
    }

    /// OSCSF, computed from the stop bits rather than stored.
    pub fn flags(self: *const Oscillators) u8 {
        var out: u8 = 0;
        for (sources) |source| {
            if (self.shadow[source.control] & stop == 0) out |= source.raises;
        }
        return out;
    }

    /// Whether the source that `raises` this flag is running right now.
    pub fn running(self: *const Oscillators, raises: u8) bool {
        return self.flags() & raises != 0;
    }

    fn byteAt(self: *const Oscillators, offset: u32) u8 {
        if (offset == regs.oscsf) return self.flags();
        return if (offset < win_span) self.shadow[offset] else 0;
    }

    pub fn read(self: *Oscillators, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        var out: u32 = 0;
        var lane: u32 = 0;
        while (lane < width) : (lane += 1) {
            out |= @as(u32, self.byteAt(offset + lane)) << @intCast(lane * 8);
        }
        return out;
    }

    pub fn write(self: *Oscillators, address: u32, width: u3, value: u32) void {
        // PRC0 shut means the hardware discards the store without a fault and
        // without a status bit. Counting it is the only way the run can say so.
        if (!self.protection.unlocked(guard)) {
            self.dropped_locked +%= 1;
            return;
        }
        const offset = address -% win_base;
        var lane: u32 = 0;
        while (lane < width) : (lane += 1) {
            const at = offset + lane;
            if (at >= win_span) continue;
            const byte: u8 = @truncate(value >> @intCast(lane * 8));
            // OSCSF is read-only: hardware owns every bit of it.
            if (at == regs.oscsf) {
                self.readonly_writes +%= 1;
                continue;
            }
            self.note(at, byte);
            self.shadow[at] = byte;
        }
    }

    /// Count a stop bit that actually moved, so the report can say how many
    /// sources this run started and stopped.
    fn note(self: *Oscillators, offset: u32, byte: u8) void {
        for (sources) |source| {
            if (source.control != offset) continue;
            const was_stopped = self.shadow[offset] & stop != 0;
            const now_stopped = byte & stop != 0;
            if (was_stopped and !now_stopped) self.starts +%= 1;
            if (!was_stopped and now_stopped) self.stops +%= 1;
        }
    }

    pub fn block(self: *Oscillators) periph.Block {
        return .{
            .name = "SYSC-OSC",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Oscillators = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Oscillators = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

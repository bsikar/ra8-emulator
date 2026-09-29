//! The brown-out hazard between the core voltage range and the clock the tree
//! is about to run on: step 2 of ra8_cgc.c's bring-up, watched rather than
//! enforced.
//!
//! vscr.zig models the register and says outright that it records "which range
//! was selected, not what the core would have survived". pll.zig says the same
//! from the other side: the voltage range is "a brown-out hazard rather than a
//! rule the clock registers enforce, so it belongs to whatever models the
//! consequence". This file is that consequence, and it is deliberately the
//! only place in the tree that joins the two.
//!
//! WHY IT CANNOT BE A REFUSAL. ra8_cgc.c's own step 2 doc comment is explicit
//! about what silicon does when the order is wrong: "without it, the PLL
//! writes succeed but the chip browns out as soon as CPUCLK0 lifts past the
//! high-voltage threshold". So every store lands. There is no dropped write to
//! model, no status flag to raise, and a model that refused the select would be
//! inventing a protection the part does not have. What there is instead is a
//! run that comes up looking perfect in the emulator and dies on the bench, so
//! the only useful thing an emulator can do is say the order was wrong.
//!
//! WHERE THE LINE IS DRAWN. The trigger is the CLOCK LIFT, not the PLL
//! configuration: the writes succeed, and the brown-out arrives when CPUCLK0
//! actually rises, which on this part is the SCKSCR switch onto a PLL. So this
//! watches selects, and sysclk.zig calls in on every one of them with whether
//! the source about to drive the tree is a PLL (Source.liftsCore). The
//! ordering the driver keeps is visible in internal_cgc_init_protected:
//! internal_set_vscr_not_high_v runs second, the SCKSCR store onto PLL1 runs
//! last, and everything in between happens with the core already in the
//! not-high-voltage range.
//!
//! DELIBERATELY NOT MODELLED. No threshold and no rate: nothing in the tree
//! records the frequency at which the high-voltage range stops being safe, so
//! this file does not pretend to compare one. It knows only that a PLL source
//! is what lifts CPUCLK0 far enough for step 2 to matter, which is the whole
//! of what the driver's eleven-step preamble claims. A run that never touches
//! VSCR and never selects a PLL is silent here, and so is one that got the
//! order right.
const vscr = @import("vscr.zig");

/// What the run did about step 2, counted at the moment of each clock select.
pub const Watch = struct {
    /// The board's live voltage register, so the range is read at the instant
    /// of the select rather than tracked twice.
    voltage: *const vscr.Unit,
    /// Selects of a source whose rate lifts CPUCLK0 past the threshold.
    lifts: u32 = 0,
    /// Those of them that happened with the high-voltage range still selected.
    brownouts: u32 = 0,

    pub fn init(voltage: *const vscr.Unit) Watch {
        return .{ .voltage = voltage };
    }

    pub fn quiet(self: *const Watch) bool {
        return self.lifts == 0;
    }

    /// Take one clock select. `lifts_core` is whether the source about to
    /// drive the tree is one that raises CPUCLK0 past the high-voltage
    /// threshold; a select that does not is not a hazard and is not counted.
    /// The select lands either way: see the header.
    pub fn selecting(self: *Watch, lifts_core: bool) void {
        if (!lifts_core) return;
        self.lifts +%= 1;
        if (self.voltage.range() == .high_voltage) self.brownouts +%= 1;
    }
};

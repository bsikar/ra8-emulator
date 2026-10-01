//! When a pend is ready and PRIMASK is the only thing holding it back.
//!
//! WHY THIS EXISTS. src/periph/nvic.zig runs at the chunk boundary, which is
//! the right seam for almost everything: the clocks are charged there, the
//! board's blocks raise there, and the controller picks there. But it makes
//! the boundary the ONLY instant at which an exception can be taken, and the
//! architecture does not work that way. On silicon a pend that arrives under
//! `cpsid i` is held in hardware and taken the moment PRIMASK clears
//! (DDI0553 B3.19). Here it was offered once, at whatever instruction the
//! boundary happened to land on, and if that instruction sat inside a masked
//! region the pend was counted as held and not looked at again for a whole
//! period.
//!
//! That is not a corner case, it is the ThreadX idle loop. `__tx_ts_wait` is
//! six instructions and four of them are masked:
//!
//!     cpsid i
//!     ldr  r1, [r2]      ; _tx_thread_execute_ptr
//!     str  r1, [r0]      ; _tx_thread_current_ptr
//!     cbnz r1, ready
//!     cpsie i
//!     b    wait
//!
//! Measured on `threadx_blink`: the boundary landed on the `str` at
//! 0x0200029E every single time, PRIMASK 1, SysTick pending, and the run
//! finished 500 periods having taken FOUR interrupts and held 9961. The
//! scheduler therefore never ran, `g_threadx_blink_tick` never moved off
//! 151, and the image could not pass its own probe contract at any window
//! length. Lengthening the window changed nothing, which is the signature of
//! a pend that is never delivered rather than one that is delivered late.
//!
//! WHAT THIS DOES. At a boundary where a pend is ready and masked, step the
//! core forward until PRIMASK clears, then let the controller pick as usual.
//! The instructions spent are real instructions: the caller charges them to
//! the clocks and to the run's budget, so modelled time still matches the
//! work done. Bounded by `limits.steps`, because firmware that masks
//! interrupts for a long stretch during bring-up must not be single-stepped
//! through it; past the bound the pend stays pending and is offered again at
//! the next boundary, exactly as before.
//!
//! `core` is `anytype` for the reason src/core/idle.zig takes it that way: it
//! keeps this file off the engine's import cycle and nothing here touches C.
const nvic = @import("../periph/nvic.zig");
const pend_sites = @import("pend_sites.zig");

pub const limits = struct {
    /// Instructions a lift may step before giving up. A mask held longer
    /// than this is a bring-up sequence rather than an idle loop, and is
    /// better left to the next boundary than stepped through. ThreadX's
    /// masked window is four instructions.
    pub const steps: usize = 64;
};

/// What one lift did.
pub const Lift = struct {
    /// Instructions actually stepped. The caller owes these to the clocks.
    ran: usize = 0,
    /// PRIMASK came clear, so the pend can be taken now.
    cleared: bool = false,
};

/// The running tally, kept across a whole run for the end-of-run line.
pub const Release = struct {
    /// Pends that were masked at a boundary and became takeable after
    /// stepping.
    lifted: u64 = 0,
    /// Instructions spent stepping to those unmasks.
    stepped: u64 = 0,
    /// Masked pends still masked after `limits.steps`, left for the next
    /// boundary.
    stuck: u64 = 0,
    /// Lifts abandoned because a step faulted. The machine is left where the
    /// step put it and the ordinary stretch handles it next time round,
    /// which is also how an exception return inside a lift is dealt with.
    faulted: u64 = 0,
    /// Lifts that have ended stuck in a row, cleared the moment one
    /// succeeds or no pend is masked at all.
    ///
    /// The bound is deliberate, but giving up and FORGETTING is not: the
    /// pend is then offered again a whole chunk later. This is what lets
    /// the boundary be narrowed while the mask holds, without touching the
    /// bound itself. src/core/mask_pace.zig carries what that is worth.
    run: u64 = 0,
    /// Where the stepping stopped on each of those give-ups, busiest site
    /// first. `stuck` says how often a lift ran out of room; this says in
    /// which code, which is the part that decides whether the mask is the
    /// firmware's own doing or the model holding one it should not.
    gave_up: pend_sites.Sites = .{},
    /// Whether the firmware has ever been seen running with interrupts on.
    ///
    /// Reset leaves PRIMASK clear on this architecture, but a boot path
    /// masks early and stays masked until it is ready, so everything
    /// before that first unmasked instant is bring-up. Only a direct read
    /// of PRIMASK sets this: a boundary with no pend standing says
    /// nothing, and neither does a lift that gave up.
    enabled_once: bool = false,
    /// Give-ups that happened before that instant. A pend held here was
    /// never takeable: the firmware had not yet reached the point where
    /// it accepts interrupts at all, so no amount of stepping would have
    /// released it and the tick it would have carried does not exist.
    booting: u64 = 0,
    /// Instructions run so far under the mask currently being waited out,
    /// stepped and stretched alike, zeroed the moment it clears or no pend
    /// is masked at all. `held_stepped` is the stepped part alone.
    held: u64 = 0,
    held_stepped: u64 = 0,
    /// The most consecutive give-ups one mask ever caused, and the
    /// instructions stepped across them.
    ///
    /// `stuck` says how OFTEN a mask outlasted the bound and never how
    /// FAR, which is the figure that decides whether the bound is set
    /// anywhere near right. A mask that gives up once and is gone by the
    /// next boundary outlasted the bound by less than a chunk. One that
    /// gives up five times in a row held for at least five bounds of
    /// stepping and is a different animal.
    ///
    /// `longest_held` is the SPAN from that mask's first give-up to its
    /// last: the stepping plus every ordinary stretch the run loop reports
    /// through `ran` in between. Each of those stretches opened and closed
    /// with PRIMASK set, so the span is the mask's length if nothing in the
    /// middle cleared and re-set it, which the firmware's own code has to
    /// settle and this cannot. `longest_stepped` is the stepping alone, the
    /// floor that holds either way. The stretch in which the mask finally
    /// cleared is not in either: where in it the clear landed is unknown.
    longest: u64 = 0,
    longest_held: u64 = 0,
    longest_stepped: u64 = 0,

    /// Step until PRIMASK clears, at most `bound` instructions.
    pub fn lift(self: *Release, core: anytype, bound: usize) !Lift {
        var out = Lift{};
        while (out.ran < bound) {
            if (try core.runChunk(try core.register(.pc), 1, null)) |_| {
                self.faulted += 1;
                return out;
            }
            out.ran += 1;
            self.stepped += 1;
            if (!(try masked(core))) {
                out.cleared = true;
                self.lifted += 1;
                self.forget();
                self.enabled_once = true;
                return out;
            }
        }
        self.stuck += 1;
        self.run +%= 1;
        self.held +%= out.ran;
        self.held_stepped +%= out.ran;
        if (self.run > self.longest) {
            self.longest = self.run;
            self.longest_held = self.held;
            self.longest_stepped = self.held_stepped;
        }
        if (!self.enabled_once) self.booting +%= 1;
        self.gave_up.record(try core.register(.pc));
        return out;
    }

    /// No pend was masked at this boundary, so there is nothing to wait
    /// out and the run starts again from zero.
    ///
    /// PRIMASK is read here rather than inferred: this boundary had no
    /// masked pend either because the firmware is running unmasked or
    /// because nothing was pending at all, and only the first of those
    /// says the firmware has finished bringing itself up.
    pub fn nothingMasked(self: *Release, core: anytype) !void {
        if (!(try masked(core))) self.enabled_once = true;
        self.forget();
    }

    /// The run loop ran an ordinary stretch of `instructions`. While a
    /// mask is being waited out it opened under that mask, so it is
    /// charged to the span; it only counts once the next boundary finds
    /// the mask still standing and gives up again.
    pub fn ran(self: *Release, instructions: usize) void {
        if (self.run != 0) self.held +%= instructions;
    }

    fn forget(self: *Release) void {
        self.run = 0;
        self.held = 0;
        self.held_stepped = 0;
    }

    /// Whether anything happened worth a line at the end of a run.
    pub fn quiet(self: *const Release) bool {
        return self.lifted == 0 and self.stuck == 0 and self.faulted == 0;
    }
};

fn masked(core: anytype) !bool {
    return (try core.register(.primask)) & nvic.primask_pm != 0;
}

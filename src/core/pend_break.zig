//! A pend the firmware writes ends the stretch it was written in.
//!
//! The controller can only take an exception at a run boundary, and a
//! boundary is thousands of instructions wide. That is fine for a pend
//! the model raises itself, because the model raises it at a boundary.
//! It is wrong for a pend the FIRMWARE writes: on silicon, storing
//! `ICSR.PENDSVSET` is followed by the PendSV handler on the next
//! instruction boundary, and here the thread that asked to be switched
//! away from carried on running until the stretch ran out.
//!
//! Measured on `threadx_blink`: `_tx_thread_system_suspend` ends by
//! pending PendSV, and 72 of those were written over four modelled
//! seconds against about a dozen exception entries. Every suspend that
//! lost its PendSV returned to `tx_thread_sleep`, which returned to the
//! thread, which toggled its LED and slept again, all inside one
//! stretch and all in no modelled time. The run showed 48 toggles where
//! the board shows 8, and the count scaled with the boundary width:
//! roughly six iterations per wake at a 2000-instruction boundary and
//! about forty times that at 100000.
//!
//! So the write itself is the boundary. The hook next door stops the
//! stretch on the store, the run loop charges it one instruction and
//! lets the controller dispatch, and the exception lands where the
//! architecture puts it.
const std = @import("std");
const pend_sites = @import("pend_sites.zig");

/// A pend written by the firmware, waiting to be taken.
pub const Pend = struct {
    /// Set by the hook as the store retires, taken by the run loop at
    /// the boundary the store made.
    latched: bool = false,
    /// Stretches cut short this way, so a run can say how often the
    /// firmware asked for a switch.
    cuts: usize = 0,
    /// Stores of `PENDSVSET` that found the bit already standing, so there
    /// was no transition to latch and the stretch ran on.
    ///
    /// This is NOT noise to be filtered away. A pend that is already
    /// standing is a pend the controller has not managed to take, and every
    /// further request to switch lands on top of it and is lost: the
    /// scheduler asks, nothing happens, and the thread that asked to be
    /// switched away from carries on. One of these is the architecture
    /// (the bit is a single flag and a second write is genuinely a no-op);
    /// a hundred and fifty of them against one take is the model failing to
    /// drain it.
    swallowed: usize = 0,
    /// Swallowed stores that happened while an exception was executing,
    /// rather than in Thread mode.
    ///
    /// This is the question the count on its own cannot answer. A pend
    /// that is standing because the handler for it is ALREADY RUNNING is
    /// the architecture: PendSV cannot preempt itself, and ThreadX's own
    /// handler spins in `__tx_ts_wait` with no thread to run. A pend
    /// standing while Thread mode runs on is the model failing to drain
    /// it, because on silicon the handler would have been entered an
    /// instruction after the first store.
    swallowed_in_handler: usize = 0,
    /// The exception that was executing at the first swallowed store, or
    /// zero when the first one happened in Thread mode.
    swallowed_under: u16 = 0,
    /// Set once `swallowed_under` has been written, so a first store in
    /// Thread mode is not overwritten by a later one in a handler.
    placed: bool = false,
    /// Swallowed stores piled on the standing pend inside the stretch
    /// running right now.
    in_stretch: usize = 0,
    /// The most swallowed stores any one stretch carried.
    ///
    /// This is what decides whether the boundary width is the hole. The
    /// controller can only take an exception at a boundary, so every store
    /// that lands inside one stretch is a switch the firmware asked for and
    /// could not get until the stretch ran out. A worst of one says the
    /// losses are spread thin and the stretch is innocent; a worst near the
    /// whole swallowed count says they all happened between two boundaries
    /// and the chunk is exactly the thing to shorten.
    longest_stretch: usize = 0,
    /// Stretches that carried at least one swallowed store, so the worst
    /// can be read against how often it happens at all.
    stretches: usize = 0,
    /// Whether a Thread-mode store that raises nothing may still end the
    /// stretch. OFF by default, and `--drain-pends` turns it on.
    ///
    /// It is off because the experiment it enables does not yet produce a
    /// right answer, only a differently wrong one. Measured on
    /// threadx_blink over 1000 ms at the 50000 default: LED1 falls from
    /// 150 toggles to 1 where the board shows 2, and over 4000 ms it is
    /// still 1 where the board shows 8, so the thread stops blinking
    /// rather than blinking correctly. Exceptions taken go from 1004 to
    /// 11002 and swallowed stores from 151 to 639937. Shipping that as the
    /// default would trade a number that is too high for one that is too
    /// low and call it a fix. The switch keeps the experiment reproducible
    /// without any image's behaviour depending on it.
    look_again: bool = false,
    /// Set by the hook when the firmware asked AGAIN, in Thread mode, for
    /// a switch it is still owed. Taken by the run loop as a second look.
    ///
    /// Separate from `latched` because the two cost different things. A
    /// rising edge is a pend that did not exist a moment ago, so the
    /// stretch it cut is charged and the clocks move. This one raises
    /// nothing: the bit was already standing, and all the boundary buys is
    /// another chance to dispatch it. Charging a chunk of modelled time for
    /// that would invent time the firmware never spent, and at 150 of them
    /// a second it would be a visible lie.
    again: bool = false,
    /// Second looks given, so the cost of this is readable rather than
    /// assumed.
    looks: usize = 0,
    /// The address of the store that ended the stretch running now, and
    /// whether one has been written at all.
    ///
    /// The hook stops the stretch AS THE STORE HAPPENS, which leaves the
    /// program counter on the store rather than past it. That is the
    /// right place to stop and the wrong place to come back to: if the
    /// controller takes the exception here, the return address it stacks
    /// is the store itself, and the thread re-runs it the moment the
    /// handler returns, asking for a switch it has already been given.
    /// Whether that actually happens is not a thing to reason about from
    /// the instruction stream, so it is measured.
    ended_at: u32 = 0,
    ended: bool = false,
    /// Stretches that opened on the very address the one before them
    /// ended on.
    reentered: usize = 0,
    /// The first address it happened on, so the loop can be named rather
    /// than counted.
    reentered_at: u32 = 0,
    /// The address of the first swallowed store, and how many of the rest
    /// came from somewhere else.
    ///
    /// This is the difference between one site asking over and over and
    /// the whole firmware asking once each. The run already says how many
    /// stores landed on a standing pend; it has never said WHERE, and the
    /// two readings want opposite fixes. A single address with every store
    /// on it is one loop to go and read. Hundreds of thousands spread over
    /// many addresses is the model never draining the bit at all.
    swallowed_at: u32 = 0,
    swallowed_placed: bool = false,
    swallowed_elsewhere: usize = 0,
    /// Every address a swallowed store came from, with its count.
    ///
    /// `swallowed_at` and `swallowed_elsewhere` answer "all at one site or
    /// not" and cannot tell one other address from a hundred. This names
    /// them. src/core/pend_sites.zig carries why it is a fixed table.
    sites: pend_sites.Sites = .{},

    /// Called from the hook as it stops the stretch: the store was at
    /// `pc`. Both reasons for stopping come through here, because both
    /// leave the program counter in the same place.
    pub fn endedAt(self: *Pend, pc: u32) void {
        self.ended_at = pc;
        self.ended = true;
    }

    /// Called from the hook: the firmware just set a pend bit.
    pub fn record(self: *Pend) void {
        self.latched = true;
        self.cuts +%= 1;
    }

    /// Called from the hook: the firmware wrote a pend that was already
    /// standing, so nothing was raised. `executing` is the IPSR at the
    /// store, zero in Thread mode.
    pub fn alreadyPending(self: *Pend, executing: u16) void {
        self.swallowed +%= 1;
        self.in_stretch +%= 1;
        if (executing != 0) {
            self.swallowed_in_handler +%= 1;
        } else {
            // Thread mode: the thread is running on top of a switch it
            // already asked for, which on silicon it would never get to
            // do. Give the controller another look. A store from INSIDE a
            // handler is left alone on purpose: PendSV cannot preempt
            // itself, so a look there can never take it and would only
            // spin the boundary.
            if (self.look_again) {
                self.again = true;
                self.looks +%= 1;
            }
        }
        if (self.placed) return;
        self.placed = true;
        self.swallowed_under = executing;
    }

    /// Called from the hook with the address of a swallowed store, which
    /// the hook knows and this does not.
    pub fn swallowedAt(self: *Pend, pc: u32) void {
        self.sites.record(pc);
        if (!self.swallowed_placed) {
            self.swallowed_placed = true;
            self.swallowed_at = pc;
            return;
        }
        if (pc != self.swallowed_at) self.swallowed_elsewhere +%= 1;
    }

    /// Called by the run loop as a stretch opens at `pc`: close the books
    /// on the one that just ended. A stretch that swallowed nothing is not
    /// counted, so `stretches` reads as how often this happens rather than
    /// how long the run was.
    pub fn boundary(self: *Pend, pc: u32) void {
        if (self.ended and pc == self.ended_at) {
            if (self.reentered == 0) self.reentered_at = pc;
            self.reentered +%= 1;
        }
        self.ended = false;
        if (self.in_stretch == 0) return;
        if (self.in_stretch > self.longest_stretch) self.longest_stretch = self.in_stretch;
        self.stretches +%= 1;
        self.in_stretch = 0;
    }

    /// Take the second-look latch, if one is standing.
    pub fn lookAgain(self: *Pend) bool {
        if (!self.again) return false;
        self.again = false;
        return true;
    }

    /// Take the latch, if one is standing. Clears it, so one store ends
    /// one stretch.
    pub fn take(self: *Pend) bool {
        if (!self.latched) return false;
        self.latched = false;
        return true;
    }
};

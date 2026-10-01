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

    /// Called from the hook: the firmware just set a pend bit.
    pub fn record(self: *Pend) void {
        self.latched = true;
        self.cuts +%= 1;
    }

    /// Called from the hook: the firmware wrote a pend that was already
    /// standing, so nothing was raised.
    pub fn alreadyPending(self: *Pend) void {
        self.swallowed +%= 1;
    }

    /// Take the latch, if one is standing. Clears it, so one store ends
    /// one stretch.
    pub fn take(self: *Pend) bool {
        if (!self.latched) return false;
        self.latched = false;
        return true;
    }
};

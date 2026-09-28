//! EXC_RETURN: the value a handler branches to, and what it asks the core for.
//!
//! Exception entry hands the handler an EXC_RETURN in LR instead of a return
//! address. Bits [31:8] are all ones, which is why no real code lives there
//! and why a branch to one is unambiguous; the low bits say what the return
//! should restore.
//!
//! Until this file existed the model only ever issued 0xFFFF_FFF9 and only
//! ever unstacked from the Main stack, which is right for a bare-metal image
//! with one stack and wrong for anything with a scheduler. An RTOS thread runs
//! on the Process stack: ThreadX's PendSV handler rebuilds a thread's context,
//! puts its stack pointer in PSP, and branches to 0xFFFF_FFFD. Returning that
//! onto MSP resumed whatever happened to be on the main stack instead of the
//! thread, so no thread ever ran.
//!
//!   EXC_RETURN (DDI0553 B3.19.3)
//!     [3] MODE   1 = return to Thread mode, 0 = back into a handler
//!     [2] SPSEL  1 = unstack from the Process stack (Thread mode only)
//!     [4] FTYPE  0 = an extended frame was stacked; not modelled
//!     [0] ES     Secure/Non-secure; not modelled, this core runs Secure
//!
//! CONTROL.SPSEL is the other half of the pair: it says which stack Thread
//! mode is using right now, and the return writes it to match the value the
//! handler branched to.

/// Bits [31:8]: what makes an address an EXC_RETURN rather than somewhere to
/// fetch from.
pub const base: u32 = 0xFFFF_FF00;

/// The bits of EXC_RETURN this model reads.
pub const field = struct {
    /// ES[0]: the security state to return to. Not modelled.
    pub const es: u32 = 1 << 0;
    /// SPSEL[2]: return onto the Process stack.
    pub const spsel: u32 = 1 << 2;
    /// MODE[3]: return to Thread mode rather than to another handler.
    pub const mode: u32 = 1 << 3;
    /// FTYPE[4]: clear when an extended (floating-point) frame was stacked.
    pub const ftype: u32 = 1 << 4;
};

/// The three values this model issues on entry.
pub const to = struct {
    /// Thread mode on the Main stack: a bare-metal image, and an RTOS before
    /// its first thread has been scheduled.
    pub const thread_main: u32 = 0xFFFF_FFF9;
    /// Thread mode on the Process stack: a thread under a scheduler.
    pub const thread_process: u32 = 0xFFFF_FFFD;
    /// Back into the handler this one preempted.
    pub const handler_main: u32 = 0xFFFF_FFF1;
};

/// CONTROL, the register that says which stack Thread mode is on.
pub const control = struct {
    /// nPRIV[0]: unprivileged Thread mode. Not modelled.
    pub const npriv: u32 = 1 << 0;
    /// SPSEL[1]: Thread mode is using the Process stack.
    pub const spsel: u32 = 1 << 1;
    /// FPCA[2]: the floating-point context is live. Not modelled here, but
    /// firmware clears it (ThreadX does, on its way into the scheduler) and
    /// the bit has to survive that store, so it is never masked off.
    pub const fpca: u32 = 1 << 2;
};

/// Is this address an EXC_RETURN rather than somewhere to fetch from?
pub fn is(address: u32) bool {
    return address >= base;
}

/// Does this EXC_RETURN go back to Thread mode?
pub fn toThread(value: u32) bool {
    return value & field.mode != 0;
}

/// Which stack should the return unstack from? Only Thread mode has the
/// choice: an EXC_RETURN back into a handler is always on the Main stack,
/// whatever SPSEL happens to say, because handler mode has no other stack.
pub fn usesProcessStack(value: u32) bool {
    return toThread(value) and value & field.spsel != 0;
}

/// The EXC_RETURN to hand a handler being entered.
pub fn forEntry(from_handler: bool, thread_on_process: bool) u32 {
    if (from_handler) return to.handler_main;
    return if (thread_on_process) to.thread_process else to.thread_main;
}

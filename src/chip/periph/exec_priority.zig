//! The execution priority a fault is weighed against.
//!
//! On silicon a synchronous fault preempts only when it is more urgent than
//! the execution priority, and that is not just the innermost active
//! handler's priority. PRIMASK boosts it to 0, and a non-zero BASEPRI to
//! its own value when that is more urgent. So a BusFault or MemManage raised
//! under `cpsid i`, or with BASEPRI at or above the fault's priority,
//! escalates to HardFault even from Thread mode.
//!
//! FAULTMASK is deliberately left out. It boosts to -1, which no u8
//! priority can say, and at -1 even HardFault cannot be taken: the core
//! locks up. Lockup belongs to the core, so a fault under FAULTMASK is
//! weighed here as if FAULTMASK were clear.

/// PRIMASK bit 0.
const primask_pm: u32 = 1 << 0;

/// The execution priority for a handler at `running` (null in Thread mode)
/// once PRIMASK and BASEPRI are applied. Null means nothing boosts it, so
/// any enabled fault can be taken.
pub fn boosted(running: ?u8, primask: u32, basepri: u32) ?u8 {
    if (primask & primask_pm != 0) return 0;
    const base: u8 = @truncate(basepri);
    if (base == 0) return running;
    const level = running orelse return base;
    return @min(level, base);
}

/// `boosted` for a live core. A mask register the backend cannot read is
/// taken as clear, which is what it reads as out of reset.
pub fn current(core: anytype, running: ?u8) ?u8 {
    const primask = core.register(.primask) catch 0;
    const basepri = core.register(.basepri) catch 0;
    return boosted(running, primask, basepri);
}

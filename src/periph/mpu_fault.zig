//! What a store into a read-only region does to the core: the MemManage
//! status it latches, and the violation waiting to become one.
//!
//! Armv8-M refuses a store into a region whose RBAR.AP says read-only, at
//! both privilege levels, and takes a MemManage for it. Unicorn's core models
//! no MPU at all, so nothing refuses the store and nothing takes the fault:
//! the enforcement is synthesised, with a write hook over each protected span
//! catching the store and the run loop turning it into an exception at the
//! chunk boundary. src/core/mpu_guard.zig is that half; this file is what it
//! records, kept apart so the bookkeeping can be tested without an engine.
//!
//!   CFSR 0xE000_ED28, MMFSR is its low byte (DDI0553 D1.2.11)
//!     IACCVIOL  [0] an instruction fetch the MPU refused
//!     DACCVIOL  [1] a data access the MPU refused, which is this one
//!     MMARVALID [7] MMFAR holds the address that took it
//!   MMFAR 0xE000_ED34: the address, valid only while MMARVALID stands.

/// MemManage, exception 4 (DDI0553 B3.6).
pub const exception: u16 = 4;

/// The MMFSR bits a data-access violation sets. IACCVIOL is named for what it
/// means rather than because this model sets it: nothing here checks a fetch
/// against the region's XN bit.
pub const mmfsr = struct {
    pub const iaccviol: u32 = 1 << 0;
    pub const daccviol: u32 = 1 << 1;
    pub const mmarvalid: u32 = 1 << 7;
};

/// One refused store: the instruction that made it, and the address it went
/// for. The PC matters as much as the address, because entry has to stack
/// the faulting store rather than whatever the run stopped on.
pub const Violation = struct {
    pc: u32,
    address: u32,
};

/// What enforcement has caught and what became of it.
pub const Latch = struct {
    /// The store waiting to become an exception, taken at the next boundary.
    pending: ?Violation = null,
    /// Stores refused by an enabled read-only region.
    violations: u64 = 0,
    /// Violations that reached a MemManage handler.
    faults: u64 = 0,
    /// Violations with no handler to reach: the vector table carries none, or
    /// the controller would not take it. No escalation to HardFault is
    /// modelled, so the run carries on from where the store left it.
    unhandled: u64 = 0,
    /// Further refused words of an access already latched. A store multiple
    /// puts one word per hook call, so the words after the first belong to
    /// the access that already stopped the run, not to a second violation.
    coalesced: u64 = 0,
    /// Times enforcement was armed, one per CTRL store that asked for it.
    arms: u64 = 0,

    /// A run whose firmware never enabled a protected region stays out of
    /// the report.
    pub fn quiet(self: *const Latch) bool {
        return self.arms == 0 and self.violations == 0;
    }

    /// Catch one refused store. Answers whether it is the one to stop on:
    /// the first is, and the rest of the same access are not.
    pub fn record(self: *Latch, hit: Violation) bool {
        if (self.pending != null) {
            self.coalesced +%= 1;
            return false;
        }
        self.pending = hit;
        self.violations +%= 1;
        return true;
    }

    /// Take the pending violation, leaving nothing behind: the caller is
    /// about to turn it into an exception, and a violation is taken once.
    pub fn take(self: *Latch) ?Violation {
        const hit = self.pending orelse return null;
        self.pending = null;
        return hit;
    }
};

//! The exceptions the core is inside, innermost last, and the execution
//! priority they and the mask registers give it.
//!
//! Priorities are the raw 8-bit values, lower more urgent. AIRCR.PRIGROUP
//! splits each into a group priority, which decides preemption, and a
//! subpriority, which only orders pending exceptions of the same group.

/// One exception and the priority it runs at.
pub const Entry = struct {
    number: u9,
    priority: u8,
    /// SysTick or PendSV pended in the Non-secure copy (RA8EMU-438).
    non_secure: bool = false,
};

/// Execution priority with nothing active and no mask set: lower than any
/// configurable priority.
pub const lowest: i16 = 256;

pub const Active = struct {
    /// A guard, not an architectural limit: real nesting is bounded by stack.
    pub const max = 8;

    stack: [max]Entry = undefined,
    depth: usize = 0,

    pub fn full(self: *const Active) bool {
        return self.depth == max;
    }

    /// False when the guard is reached; the caller holds the exception.
    pub fn push(self: *Active, entry: Entry) bool {
        if (self.full()) return false;
        self.stack[self.depth] = entry;
        self.depth += 1;
        return true;
    }

    pub fn pop(self: *Active) ?Entry {
        if (self.depth == 0) return null;
        self.depth -= 1;
        return self.stack[self.depth];
    }

    pub fn running(self: *const Active) ?Entry {
        return if (self.depth == 0) null else self.stack[self.depth - 1];
    }

    /// The handler that will be running after the innermost one returns.
    pub fn returningTo(self: *const Active) ?Entry {
        return if (self.depth < 2) null else self.stack[self.depth - 2];
    }
};

/// The group-priority half of `priority` under PRIGROUP: bits [prigroup:0]
/// are subpriority and drop out (ExecutionPriority, Armv8-M ARM B3.9).
pub fn group(priority: u8, prigroup: u3) u8 {
    const sub: u9 = (@as(u9, 2) << prigroup) - 1;
    return priority & ~@as(u8, @truncate(sub));
}

/// The priority a pending exception's group priority must beat (be strictly
/// lower than) to preempt: the innermost active handler, boosted by BASEPRI
/// when it is non-zero, to 0 by PRIMASK, and to -1 by FAULTMASK. The handler
/// and BASEPRI count by group priority only.
pub fn executionPriority(active: *const Active, primask: u32, basepri: u32, faultmask: u32, prigroup: u3) i16 {
    var priority = lowest;
    if (active.running()) |inner| priority = @min(priority, @as(i16, group(inner.priority, prigroup)));
    if (basepri & 0xFF != 0) priority = @min(priority, @as(i16, group(@truncate(basepri), prigroup)));
    if (primask & 1 != 0) priority = @min(priority, 0);
    if (faultmask & 1 != 0) priority = -1;
    return priority;
}

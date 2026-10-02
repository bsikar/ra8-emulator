//! WFI and WFE waiting (RA8EMU-129).
//!
//! A core that waits stops executing until something would wake it. Nothing
//! it waits on changes until the peripherals move, and they move only at a
//! boundary, so `Cpu.run` ends the stretch when the core is still asleep and
//! the board's clock goes straight to its next edge.
const bus = @import("../bus.zig");
const Cpu = @import("../cpu.zig").Cpu;
const active = @import("active.zig");
const dispatch = @import("dispatch.zig");

/// What the core is waiting for.
pub const Wait = enum {
    /// WFI: a pending exception that would preempt if PRIMASK were clear.
    interrupt,
    /// WFE: the event register, which entry, return, SEV and SEVONPEND set.
    event,
};

/// SCR and its SEVONPEND bit: a pend then sets the event register.
pub const scr: u32 = 0xE000_ED10;
pub const sevonpend: u32 = 1 << 4;

/// Whether a core waiting for `why` wakes now. A WFE that wakes on the
/// event register consumes it.
pub fn wakes(cpu: *Cpu, why: Wait) bus.Error!bool {
    const from = cpu.source orelse return true;
    if (try from.winner(cpu.bus)) |winner| {
        const r = &cpu.regs;
        const split = dispatch.prigroup(cpu.bus);
        const bar = active.executionPriority(&cpu.active, 0, r.basepri, r.faultmask, split);
        if (active.group(winner.priority, split) < bar) return true;
        const control = cpu.bus.readWord(scr) catch 0;
        if (why == .event and control & sevonpend != 0) cpu.event = true;
    }
    if (why == .event and cpu.event) {
        cpu.event = false;
        return true;
    }
    return false;
}

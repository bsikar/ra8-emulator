//! An SVC turned into the SVCall exception it takes on silicon.
//!
//! Unicorn does not model SVCall: an `svc` ends the run with an unhandled
//! CPU exception and the PC already on the next instruction. Measured with
//! `svc #0` at 0x2200_2000, the run stopped at 0x2200_2002 with no access
//! recorded. A ThreadX module reaches the kernel only through SVC, so a run
//! with a controller takes exception 11 instead, with that PC as the stacked
//! return address, which is what the part stacks for an SVC.
//!
//! SVCall is synchronous. When its SHPR2 priority cannot preempt the
//! current execution priority it escalates to HardFault and owes
//! HFSR.FORCED, the same rule src/periph/fault_route.zig applies to faults.

const fault = @import("fault.zig");
const memmap = @import("memmap.zig");
const Session = @import("session.zig").Session;
const exec_priority = @import("../periph/exec_priority.zig");
const fault_route = @import("../periph/fault_route.zig");
const status = @import("../periph/fault_status.zig");

/// The SVCall exception number.
pub const svcall: u16 = 11;
/// T1 SVC is 0xDFxx; the low byte is the immediate.
const svc_mask: u16 = 0xFF00;
const svc_bits: u16 = 0xDF00;

/// Whether the halfword before `pc` is a T1 SVC, so a run that stopped at
/// `pc` with no access recorded stopped on that SVC.
pub fn after(core: anytype, pc: u32) bool {
    if (pc < 2) return false;
    const at = pc - 2;
    const word = core.readWord(at & ~@as(u32, 3)) catch return false;
    const half: u16 = @truncate(word >> @intCast((at & 2) * 8));
    return half & svc_mask == svc_bits;
}

/// Where SVCall goes from SHPR2 and the current execution priority.
pub fn route(shpr2: u32, running: ?u8) fault_route.Taken {
    const own: u8 = @truncate(shpr2 >> 24);
    const preempts = if (running) |level| own < level else true;
    if (preempts) return .{ .number = svcall, .priority = own, .escalated = false };
    return .{
        .number = fault_route.hard_fault,
        .priority = fault_route.hard_fault_priority,
        .escalated = true,
    };
}

/// Take SVCall for the SVC behind `taken` and return where to resume, or
/// null when the run has no controller or did not stop on an SVC.
pub fn raised(core: anytype, session: Session, taken: fault.Fault) !?u32 {
    const controller = session.interrupts orelse return null;
    if (taken.access != null) return null;
    if (!after(core, taken.pc)) return null;
    const shpr2 = core.readWord(memmap.scb.shpr2) catch 0;
    const taking = route(shpr2, exec_priority.current(core, controller.running()));
    if (taking.escalated) {
        const hfsr = core.readWord(memmap.scb.hfsr) catch 0;
        try core.writeWord(memmap.scb.hfsr, hfsr | status.Hard.forced.bit());
    }
    try core.setRegister(.pc, taken.pc);
    controller.enter(core, .{ .number = taking.number, .priority = taking.priority }) catch return null;
    return try core.register(.pc);
}

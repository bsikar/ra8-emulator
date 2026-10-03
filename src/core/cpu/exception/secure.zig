//! Taking a SecureFault on the Zig core (RA8EMU-358).
//!
//! src/periph/secure_fault.zig says what each cause latches; this file does
//! the rest the way src/core/cpu/exception/fault.zig does for UsageFault:
//! routes exception 7 against SHCSR.SECUREFAULTENA, SHPR1.PRI_7 and the
//! execution priority (src/periph/fault_route.zig), owes HFSR.FORCED when
//! it escalates to HardFault, reports lockup when even HardFault cannot
//! preempt, and enters the handler with the faulting instruction stacked as
//! the return address. SFSR is latched either way, so a HardFault handler
//! can still read the cause. SFAR is written only for the causes that
//! report an address, together with SFARVALID.
const std = @import("std");
const bus = @import("../bus.zig");
const memmap = @import("../../memmap.zig");
const fault_route = @import("../../../periph/fault_route.zig");
const status = @import("../../../periph/fault_status.zig");
const secure_fault = @import("../../../periph/secure_fault.zig");
const fault = @import("fault.zig");
const active = @import("active.zig");
const dispatch = @import("dispatch.zig");
const Cpu = @import("../cpu.zig").Cpu;

pub const Error = fault.Error;
pub const Cause = secure_fault.Cause;

/// Raise a SecureFault for `cause`, which the instruction at `pc` caused.
/// `address` is what AUVIOL and LSPERR report in SFAR; the other causes
/// ignore it.
pub fn raise(cpu: *Cpu, cause: Cause, pc: u32, address: u32) Error!void {
    const which = try latch(cpu, cause, address);
    cpu.regs.pc = pc;
    try dispatch.enter(cpu, which, pc);
}

/// Route the fault, latch SFSR (and SFAR), owe HFSR.FORCED when it
/// escalates, and say which exception to enter.
fn latch(cpu: *Cpu, cause: Cause, address: u32) Error!active.Entry {
    const r = &cpu.regs;
    const level = active.executionPriority(&cpu.active, r.primask, r.basepri, r.faultmask, dispatch.prigroup(cpu.bus));
    const route = fault_route.route(
        .secure_fault,
        cpu.bus.readWord(memmap.scb.shcsr) catch 0,
        cpu.bus.readWord(memmap.scb.shpr1) catch 0,
        fault.running(level),
    );
    if (route.escalated and (level < 0 or fault.inHardFaultOrNmi(cpu))) return error.Lockup;
    const owed = secure_fault.latch(cause, address);
    fault.orInto(cpu.bus, secure_fault.sfsr, owed.sfsr);
    if (owed.address) |at| putWord(cpu.bus, secure_fault.sfar, at);
    if (route.escalated) fault.orInto(cpu.bus, memmap.scb.hfsr, status.Hard.forced.bit());
    return .{ .number = @intCast(route.number), .priority = route.priority };
}

/// A bus with no SCS behind it keeps no SFAR, so a refused write is dropped.
fn putWord(on: bus.Bus, address: u32, value: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    on.write(address, &bytes) catch {};
}

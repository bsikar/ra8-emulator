//! Taking a synchronous UsageFault on the Zig core.
//!
//! The core decides that an instruction faults; this file latches the UFSR
//! bit in CFSR, routes the fault against SHCSR, SHPR1 and the execution
//! priority with the same rules the Unicorn backend uses
//! (src/periph/fault_route.zig), owes HFSR.FORCED when it escalates to
//! HardFault, and enters the handler with the faulting instruction stacked
//! as the return address. A HardFault that cannot preempt either (FAULTMASK
//! set, or already in HardFault) is lockup, which the caller reports as a
//! stop instead.
const std = @import("std");
const bus = @import("../bus.zig");
const memmap = @import("../../memmap.zig");
const fault_route = @import("../../../periph/fault_route.zig");
const status = @import("../../../periph/fault_status.zig");
const active = @import("active.zig");
const dispatch = @import("dispatch.zig");
const Cpu = @import("../cpu.zig").Cpu;

pub const Error = bus.Error || error{Lockup};
pub const Cause = status.Cause;

/// Raise UsageFault for `cause`, which the instruction at `pc` caused.
pub fn usage(cpu: *Cpu, cause: status.Cause, pc: u32) Error!void {
    std.debug.assert(cause.fault() == .usage_fault);
    const r = &cpu.regs;
    const level = active.executionPriority(&cpu.active, r.primask, r.basepri, r.faultmask);
    const route = fault_route.route(
        .usage_fault,
        cpu.bus.readWord(memmap.scb.shcsr) catch 0,
        cpu.bus.readWord(memmap.scb.shpr1) catch 0,
        running(level),
    );
    if (route.escalated and (level < 0 or inHardFaultOrNmi(cpu))) return error.Lockup;
    orInto(cpu.bus, memmap.scb.cfsr, cause.bit());
    if (route.escalated) orInto(cpu.bus, memmap.scb.hfsr, status.Hard.forced.bit());
    r.pc = pc;
    try dispatch.enter(cpu, .{ .number = @intCast(route.number), .priority = route.priority }, pc);
}

/// HardFault and NMI run at -1 and -2, below any priority an Entry can hold,
/// so being inside either is checked by number.
fn inHardFaultOrNmi(cpu: *const Cpu) bool {
    const inner = cpu.active.running() orelse return false;
    return inner.number == 2 or inner.number == 3;
}

/// The execution priority as fault_route reads it: null with nothing
/// running and no mask set, 0 for anything boosted to 0 or below.
fn running(level: i16) ?u8 {
    if (level >= active.lowest) return null;
    return if (level <= 0) 0 else @intCast(level);
}

/// Set `bits` in the status word at `address`. A bus with no SCS behind it
/// keeps no status, so a refused access is dropped.
fn orInto(on: bus.Bus, address: u32, bits: u32) void {
    const value = on.readWord(address) catch return;
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value | bits, .little);
    on.write(address, &bytes) catch {};
}

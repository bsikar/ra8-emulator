//! Taking the MemManage the MPU raises on the Zig core.
//!
//! A refused data access (RA8EMU-369) sets CFSR DACCVIOL and MMARVALID, and
//! MMFAR the address the instruction used. A refused instruction fetch
//! (RA8EMU-368) sets IACCVIOL alone and leaves MMFAR as it was, as the
//! architecture says. The fault routes against SHCSR.MEMFAULTENA, SHPR1.PRI_4 and the
//! execution priority with the same rules UsageFault uses
//! (src/periph/fault_route.zig); escalated, it owes HFSR.FORCED. The handler
//! is entered with the faulting instruction stacked as the return address. A
//! HardFault that cannot preempt is lockup, which the caller reports as a
//! stop instead.

const std = @import("std");
const memmap = @import("../../memmap.zig");
const fault_route = @import("../../../periph/fault_route.zig");
const status = @import("../../../periph/fault_status.zig");
const active = @import("active.zig");
const dispatch = @import("dispatch.zig");
const fault = @import("fault.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Stop = @import("../cpu.zig").Stop;

pub const Error = fault.Error;

/// Raise MemManage for a data access to `mmfar` the instruction at `pc` made.
pub fn data(cpu: *Cpu, pc: u32, mmfar: u32) Error!void {
    return take(cpu, pc, status.Cause.daccviol.bit() | status.Cause.mmarvalid.bit(), mmfar);
}

/// Raise MemManage for the refused fetch of the instruction at `pc`.
pub fn instruction(cpu: *Cpu, pc: u32) Error!void {
    return take(cpu, pc, status.Cause.iaccviol.bit(), null);
}

/// Raise MemManage MLSPERR: the MPU refused the deferred FP push the
/// instruction at `pc` triggered (RA8EMU-621). MMFAR is not valid.
pub fn lazyPreserve(cpu: *Cpu, pc: u32) Error!void {
    return take(cpu, pc, status.Cause.mlsperr.bit(), null);
}

/// lazyPreserve for the core's step, or a bus-fault stop on lockup.
pub fn lazyOrStop(cpu: *Cpu, pc: u32) ?Stop {
    lazyPreserve(cpu, pc) catch return .{ .bus_fault = pc };
    return null;
}

fn take(cpu: *Cpu, pc: u32, cause: u32, mmfar: ?u32) Error!void {
    const r = &cpu.regs;
    const level = active.executionPriority(&cpu.active, r.primask, r.basepri, r.faultmask, dispatch.prigroup(cpu.bus));
    const route = fault_route.route(
        .mem_manage,
        cpu.bus.readWord(memmap.scb.shcsr) catch 0,
        cpu.bus.readWord(memmap.scb.shpr1) catch 0,
        fault.running(level),
    );
    if (route.escalated and (level < 0 or fault.inHardFaultOrNmi(cpu))) return error.Lockup;
    fault.orInto(cpu.bus, memmap.scb.cfsr, cause);
    if (mmfar) |at| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, at, .little);
        cpu.bus.write(memmap.scb.mmfar, &bytes) catch {};
    }
    if (route.escalated) fault.orInto(cpu.bus, memmap.scb.hfsr, status.Hard.forced.bit());
    cpu.regs.pc = pc;
    try dispatch.enter(cpu, .{ .number = @intCast(route.number), .priority = route.priority }, pc);
}

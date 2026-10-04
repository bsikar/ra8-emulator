//! The faults a deferred FP push raises on the Zig core (RA8EMU-621).
//!
//! When the first FP instruction after a lazy exception entry runs, its
//! PreserveFPState may be refused: by the MPU, which is MemManage with
//! CFSR.MLSPERR, or by the bus, which is BusFault with CFSR.LSPERR (DDI0553
//! PreserveFPState). Neither writes MMFAR or BFAR. Each routes against its
//! SHCSR enable, SHPR1 priority and the execution priority like any other
//! configurable fault (src/periph/fault_route.zig); escalated, it owes
//! HFSR.FORCED. The FP instruction is stacked as the return address and
//! FPCCR.LSPACT stays set, so the push is retried when it runs again.

const memmap = @import("../../memmap.zig");
const fault_route = @import("../../../periph/fault_route.zig");
const status = @import("../../../periph/fault_status.zig");
const active = @import("active.zig");
const dispatch = @import("dispatch.zig");
const fault = @import("fault.zig");
const cpu_mod = @import("../cpu.zig");
const Cpu = cpu_mod.Cpu;
const Stop = cpu_mod.Stop;

pub const Error = fault.Error;

/// Take the fault `err` names for the FP instruction at `pc`, or stop with a
/// bus fault when it locks up.
pub fn orStop(cpu: *Cpu, err: anyerror, pc: u32) ?Stop {
    const taken = if (err == error.LazyMemManage)
        raise(cpu, .mem_manage, .mlsperr, pc)
    else
        raise(cpu, .bus_fault, .lsperr, pc);
    taken catch return .{ .bus_fault = pc };
    return null;
}

/// Raise `kind` with `cause` set in CFSR for the instruction at `pc`.
pub fn raise(cpu: *Cpu, kind: fault_route.Fault, cause: status.Cause, pc: u32) Error!void {
    const r = &cpu.regs;
    const level = active.executionPriority(&cpu.active, r.primask, r.basepri, r.faultmask, dispatch.prigroup(cpu.bus));
    const route = fault_route.route(
        kind,
        cpu.bus.readWord(memmap.scb.shcsr) catch 0,
        cpu.bus.readWord(memmap.scb.shpr1) catch 0,
        fault.running(level),
    );
    if (route.escalated and (level < 0 or fault.inHardFaultOrNmi(cpu))) return error.Lockup;
    fault.orInto(cpu.bus, memmap.scb.cfsr, cause.bit());
    if (route.escalated) fault.orInto(cpu.bus, memmap.scb.hfsr, status.Hard.forced.bit());
    r.pc = pc;
    try dispatch.enter(cpu, .{ .number = @intCast(route.number), .priority = route.priority }, pc);
}

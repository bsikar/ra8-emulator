//! Taking exceptions between instructions, and keeping the active stack in
//! step with entry and return.
//!
//! The core asks its source for the pending winner before each instruction
//! and takes it when it beats the execution priority. A return followed by
//! another pending exception is taken at the next boundary, which leaves the
//! same state tail-chaining would, with the frame popped and pushed again.
const bus = @import("../bus.zig");
const memmap = @import("../../memmap.zig");
const Cpu = @import("../cpu.zig").Cpu;
const active = @import("active.zig");
const entry = @import("entry.zig");
const fault = @import("fault.zig");

/// Take the pending winner if it may preempt. True when one was taken.
pub const Error = fault.Error;

pub fn poll(cpu: *Cpu) Error!bool {
    const external = if (cpu.source) |from| try from.winner(cpu.bus) else null;
    const pending_fault = fault.pendingUsage(cpu.bus);
    const split = prigroup(cpu.bus);
    const fault_first = if (pending_fault) |pending|
        external == null or active.group(pending.priority, split) < active.group(external.?.priority, split)
    else
        false;
    const winner = if (fault_first) pending_fault else external;
    const selected_fault = fault_first;
    const r = &cpu.regs;
    const candidate = winner orelse return false;
    if (active.group(candidate.priority, split) >= active.executionPriority(&cpu.active, r.primask, r.basepri, r.faultmask, split)) return false;
    if (cpu.active.full()) return false;
    // An image with no handler for what it pended keeps the pend rather than
    // branching to address zero.
    const handler = cpu.bus.readWord(entry.vectorTable(cpu) +% @as(u32, candidate.number) * 4) catch return false;
    if (handler == 0) return false;
    if (selected_fault) fault.clearUsagePending(cpu.bus);
    try enterInternal(cpu, candidate, r.pc, false, !selected_fault);
    return true;
}

/// AIRCR.PRIGROUP. A bus with no SCS behind it reads as 0, every bit but
/// bit 0 a group bit.
pub fn prigroup(on: bus.Bus) u3 {
    const aircr = on.readWord(memmap.scb.aircr) catch return 0;
    return @truncate(aircr >> 8);
}

/// Enter `which` with `return_address` stacked, and record it active.
pub fn enter(cpu: *Cpu, which: active.Entry, return_address: u32) Error!void {
    try enterInternal(cpu, which, return_address, true, true);
}

fn enterInternal(cpu: *Cpu, which: active.Entry, return_address: u32, derive: bool, notify_source: bool) Error!void {
    const overflow = try entry.take(cpu, which.number, return_address);
    if (overflow and derive) {
        const derived = try fault.derivedEntry(cpu, .stkof);
        if (derivedWins(derived, which, prigroup(cpu.bus))) {
            try entry.retarget(cpu, derived.number);
            _ = cpu.active.push(derived);
            return;
        }
        try fault.pendUsage(cpu);
    }
    _ = cpu.active.push(which);
    if (notify_source) {
        if (cpu.source) |from| try from.taken(cpu.bus, which.number);
    }
}

fn derivedWins(derived: active.Entry, original: active.Entry, split: u3) bool {
    if (derived.number == 3) return true;
    return active.group(derived.priority, split) < active.group(original.priority, split);
}

/// Enter `which` as a tail chain: no frame, `lr` as the link value.
pub fn chain(cpu: *Cpu, which: active.Entry, lr: u32) Error!void {
    try entry.chain(cpu, which.number, lr);
    _ = cpu.active.push(which);
    if (cpu.source) |from| try from.taken(cpu.bus, which.number);
}

/// SVC, at the priority SHPR2 gives it.
pub fn supervisorCall(cpu: *Cpu, number: u9, return_address: u32) Error!void {
    const shpr2 = cpu.bus.readWord(memmap.scb.shpr2) catch 0;
    try enter(cpu, .{ .number = number, .priority = @truncate(shpr2 >> 24) }, return_address);
}

/// After an exception return: the innermost handler is no longer active.
pub fn left(cpu: *Cpu) bus.Error!void {
    const done = cpu.active.pop() orelse return;
    if (cpu.source) |from| try from.returned(cpu.bus, done.number);
}

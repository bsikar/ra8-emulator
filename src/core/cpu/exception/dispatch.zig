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
const quiet_source = @import("quiet_source.zig");
const stack_fault = @import("stack_fault.zig");

/// Take the pending winner if it may preempt. True when one was taken.
pub const Error = fault.Error;

pub fn poll(cpu: *Cpu) Error!bool {
    if (cpu.quiet) |q| if (q.hushed and (q.clear or q.holds(key(cpu)))) return false;
    const now = key(cpu);
    const external = if (cpu.source) |from| try from.winner(cpu.bus) else null;
    const pending_fault = fault.pending(cpu.bus);
    if (external == null and pending_fault == null) return hush(cpu, now, true);
    const split = prigroup(cpu.bus);
    const fault_first = if (pending_fault) |pending|
        external == null or fault.precedes(pending, external.?)
    else
        false;
    const winner = if (fault_first) pending_fault else external;
    const selected_fault = fault_first;
    const r = &cpu.regs;
    const candidate = winner orelse return false;
    if (active.group(candidate.priority, split) >= active.executionPriority(&cpu.active, r.primask, r.basepri, r.faultmask, split)) return hush(cpu, now, false);
    if (cpu.active.full()) return hush(cpu, now, false);
    // An image with no handler for what it pended keeps the pend rather than
    // branching to address zero.
    cpu.entering_non_secure = candidate.non_secure;
    defer cpu.entering_non_secure = false;
    const handler = entry.handlerOf(cpu, candidate.number) catch return false;
    if (handler == 0) return false;
    try enterInternal(cpu, candidate, r.pc, if (selected_fault) .pending_fault else .source);
    return true;
}

/// The mask registers and active stack a poll's decision rests on.
fn key(cpu: *const Cpu) quiet_source.Key {
    const r = &cpu.regs;
    const running: u16 = if (cpu.active.running()) |top| top.number else 0xFFFF;
    return .{ .primask = r.primask, .basepri = r.basepri, .faultmask = r.faultmask, .depth = cpu.active.depth, .running = running };
}

/// Nothing can be taken now; let the quiet source skip the polls that
/// would find the same until something changes.
fn hush(cpu: *Cpu, now: quiet_source.Key, clear: bool) bool {
    if (cpu.quiet) |q| q.hush(now, clear);
    return false;
}

/// AIRCR.PRIGROUP. A bus with no SCS behind it reads as 0, every bit but
/// bit 0 a group bit.
pub fn prigroup(on: bus.Bus) u3 {
    const aircr = on.readWord(memmap.scb.aircr) catch return 0;
    return @truncate(aircr >> 8);
}

/// Enter `which` with `return_address` stacked, and record it active.
pub fn enter(cpu: *Cpu, which: active.Entry, return_address: u32) Error!void {
    try enterInternal(cpu, which, return_address, .synchronous);
}

const Origin = enum { synchronous, source, pending_fault };

fn enterInternal(cpu: *Cpu, which: active.Entry, return_address: u32, origin: Origin) Error!void {
    const result = try entry.takeDetailed(cpu, which.number, return_address);
    const cause: ?fault.Cause = if (result.failed) |failed|
        stack_fault.cause(failed, .stacking)
    else if (result.overflow)
        .stkof
    else
        null;
    if (cause) |derived_cause| {
        const derived = try fault.derivedIn(cpu, derived_cause, result.from);
        if (derivedWins(derived, which, prigroup(cpu.bus))) {
            if (origin == .synchronous) try fault.pendException(cpu, which.number);
            try entry.retarget(cpu, derived.number, result.from);
            _ = cpu.active.push(derived);
            return;
        }
        if (origin == .pending_fault) fault.clearPending(cpu.bus, which.number);
        try fault.pendIn(cpu, derived_cause, result.from);
    } else if (origin == .pending_fault) {
        fault.clearPending(cpu.bus, which.number);
    }
    _ = cpu.active.push(which);
    if (origin != .pending_fault) {
        if (cpu.source) |from| try from.taken(cpu.bus, which.number);
    }
}

fn derivedWins(derived: active.Entry, original: active.Entry, split: u3) bool {
    if (derived.number == 3) return original.number != 2 and original.number != 3;
    return active.group(derived.priority, split) < active.group(original.priority, split);
}

/// Enter `which` as a tail chain: no frame, `lr` as the link value.
pub fn chain(cpu: *Cpu, which: active.Entry, lr: u32) Error!void {
    cpu.entering_non_secure = which.non_secure;
    defer cpu.entering_non_secure = false;
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

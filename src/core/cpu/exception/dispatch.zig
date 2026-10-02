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

/// Take the pending winner if it may preempt. True when one was taken.
pub fn poll(cpu: *Cpu) bus.Error!bool {
    const from = cpu.source orelse return false;
    const winner = (try from.winner(cpu.bus)) orelse return false;
    const r = &cpu.regs;
    if (winner.priority >= active.executionPriority(&cpu.active, r.primask, r.basepri, r.faultmask)) return false;
    if (cpu.active.full()) return false;
    // An image with no handler for what it pended keeps the pend, as the
    // NVIC model does, rather than branching to address zero.
    const handler = cpu.bus.readWord(entry.vectorTable(cpu) +% @as(u32, winner.number) * 4) catch return false;
    if (handler == 0) return false;
    try enter(cpu, winner, r.pc);
    return true;
}

/// Enter `which` with `return_address` stacked, and record it active.
pub fn enter(cpu: *Cpu, which: active.Entry, return_address: u32) bus.Error!void {
    try entry.take(cpu, which.number, return_address);
    _ = cpu.active.push(which);
    if (cpu.source) |from| try from.taken(cpu.bus, which.number);
}

/// SVC, at the priority SHPR2 gives it.
pub fn supervisorCall(cpu: *Cpu, number: u9, return_address: u32) bus.Error!void {
    const shpr2 = cpu.bus.readWord(memmap.scb.shpr2) catch 0;
    try enter(cpu, .{ .number = number, .priority = @truncate(shpr2 >> 24) }, return_address);
}

/// After an exception return: the innermost handler is no longer active.
pub fn left(cpu: *Cpu) bus.Error!void {
    const done = cpu.active.pop() orelse return;
    if (cpu.source) |from| try from.returned(cpu.bus, done.number);
}

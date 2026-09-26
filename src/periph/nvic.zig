//! The Nested Vectored Interrupt Controller: what is pending, and what taking
//! it does to the core.
//!
//! Unicorn's M-profile core only takes exceptions it raised itself. Nothing
//! here raises one: the PPB is plain RAM, so `NVIC->ISER[0] = 1 << n` and
//! `SysTick`'s pend in ICSR are words sitting in memory that the core will
//! never look at. Until this file existed, a firmware that armed SysTick with
//! TICKINT and then waited on a handler-updated flag spun out its whole
//! budget: the previous slice pended the exception, and nobody took it.
//!
//! So the controller is modelled host-side and runs at the chunk boundary,
//! the same seam the clocks are charged on. Taking an exception is done the
//! way the silicon does it (DDI0553 B3.19): stack the caller-saved frame,
//! load LR with an EXC_RETURN, and enter the handler from the vector table at
//! VTOR. Returning is the mirror: the handler branches to EXC_RETURN, which is
//! an unmapped fetch as far as Unicorn is concerned, and the run loop unwinds
//! the frame instead of reporting a fault.
const std = @import("std");
const memmap = @import("../core/memmap.zig");
const clocks = @import("clocks.zig");

/// Exception numbers (DDI0553 B3.6). Only the two system exceptions the
/// firmware actually pends are named; everything at or above `first_irq` is
/// an ICU line.
pub const pendsv: u16 = 14;
pub const systick: u16 = 15;
pub const first_irq: u16 = 16;

/// The RA8 ICU drives 96 NVIC lines (IELSR0..IELSR95), so three ISER/ICER
/// words. Widening the model to a bigger part is this one constant.
pub const irq_lines: u16 = 96;
const irq_words: u16 = irq_lines / 32;

/// ICSR's pend and unpend bits for the two system exceptions.
pub const icsr_pendstclr: u32 = 1 << 25;
pub const icsr_pendstset: u32 = clocks.icsr_pendstset;
pub const icsr_pendsvclr: u32 = 1 << 27;
pub const icsr_pendsvset: u32 = 1 << 28;

/// xPSR: the low nine bits are IPSR, the exception the core is executing, and
/// bit 9 records that entry pushed four bytes of padding to realign the stack.
pub const ipsr_mask: u32 = 0x0000_01FF;
pub const xpsr_stack_align: u32 = 1 << 9;

/// PRIMASK bit 0: interrupts at priority 0 and below are masked. `cpsid i`
/// sets it, and early bring-up runs under it for long stretches.
pub const primask_pm: u32 = 1 << 0;

/// EXC_RETURN. Bits [31:8] are all ones, which is why no real code lives
/// there and why a branch to one is unambiguous.
pub const exc_return_base: u32 = 0xFFFF_FF00;
pub const exc_return_thread_msp: u32 = 0xFFFF_FFF9;
pub const exc_return_handler_msp: u32 = 0xFFFF_FFF1;

/// The eight words entry stacks: r0-r3, r12, lr, the return address, xPSR.
pub const frame_bytes: u32 = 32;

/// Is this address an EXC_RETURN rather than somewhere to fetch from?
pub fn isExceptionReturn(address: u32) bool {
    return address >= exc_return_base;
}

/// A pending exception and the priority it would run at. Lower is more
/// urgent, the architecture's convention, kept here so the comparisons read
/// the way the manual does.
pub const Candidate = struct {
    number: u16,
    priority: u8,
};

pub const Error = error{ NotInHandler, TooDeep, NoVector };

pub const Nvic = struct {
    /// How deep exceptions may nest before the model refuses to preempt. Real
    /// silicon is bounded by stack, not by a count; this is a guard so a
    /// runaway pend cannot walk the stack pointer off the map.
    pub const max_nesting: usize = 8;

    /// Where the vector table is when VTOR does not say. VTOR reads zero out
    /// of reset and an image that never relocates its table leaves it there,
    /// so the fallback is the base the reset vector itself came from.
    vector_base: u32 = 0,
    active: [max_nesting]Candidate = undefined,
    depth: usize = 0,
    /// Exceptions entered.
    taken: u64 = 0,
    /// Handlers returned from.
    returned: u64 = 0,
    /// Pends that were ready but could not be taken: masked, outranked by the
    /// running handler, or past the nesting guard.
    held: u64 = 0,

    /// Fold the write-to-clear registers, then take the most urgent pend that
    /// is allowed to preempt whatever is running. Returns the exception it
    /// entered. Call it at the chunk boundary, after the clocks are charged.
    pub fn dispatch(self: *Nvic, core: anytype) !?u16 {
        try foldClearRegisters(core);
        const candidate = (try self.pick(core)) orelse return null;
        if (try masked(core)) {
            self.held += 1;
            return null;
        }
        if (self.depth == max_nesting) {
            self.held += 1;
            return null;
        }
        if (self.depth > 0 and candidate.priority >= self.active[self.depth - 1].priority) {
            self.held += 1;
            return null;
        }
        // An image with no handler for what it pended keeps the pend rather
        // than jumping to address zero, so a missing vector reads as a stuck
        // interrupt in the report instead of a fault somewhere unrelated.
        if ((try self.vectorFor(core, candidate.number)) == null) {
            self.held += 1;
            return null;
        }
        try self.enter(core, candidate);
        return candidate.number;
    }

    /// Enter `exc`: stack the caller-saved frame at SP, hand the handler an
    /// EXC_RETURN in LR, and jump to its vector.
    pub fn enter(self: *Nvic, core: anytype, exc: Candidate) !void {
        if (self.depth == max_nesting) return Error.TooDeep;
        const handler = (try self.vectorFor(core, exc.number)) orelse return Error.NoVector;
        const xpsr = try core.register(.xpsr);

        var stacked_xpsr = xpsr & ~xpsr_stack_align;
        var sp = try core.register(.sp);
        // The frame is eight-byte aligned; entry pads and records the pad.
        if (sp & 4 != 0) {
            sp -= 4;
            stacked_xpsr |= xpsr_stack_align;
        }
        sp -= frame_bytes;
        try core.writeWord(sp + 0, try core.register(.r0));
        try core.writeWord(sp + 4, try core.register(.r1));
        try core.writeWord(sp + 8, try core.register(.r2));
        try core.writeWord(sp + 12, try core.register(.r3));
        try core.writeWord(sp + 16, try core.register(.r12));
        try core.writeWord(sp + 20, try core.register(.lr));
        try core.writeWord(sp + 24, try core.register(.pc));
        try core.writeWord(sp + 28, stacked_xpsr);

        try core.setRegister(.sp, sp);
        try core.setRegister(.lr, if (self.depth == 0) exc_return_thread_msp else exc_return_handler_msp);
        // IPSR is the running exception: a handler that reads it gets itself.
        try core.setRegister(.xpsr, (xpsr & ~ipsr_mask) | exc.number);
        try core.setRegister(.pc, handler);

        self.active[self.depth] = exc;
        self.depth += 1;
        self.taken += 1;
        try clearPending(core, exc.number);
        try setActiveBit(core, exc.number, true);
    }

    /// Return from the innermost handler: restore the frame the entry stacked
    /// and resume where the exception interrupted.
    pub fn exit(self: *Nvic, core: anytype) !void {
        if (self.depth == 0) return Error.NotInHandler;
        const finished = self.active[self.depth - 1];
        self.depth -= 1;

        var sp = try core.register(.sp);
        try core.setRegister(.r0, try core.readWord(sp + 0));
        try core.setRegister(.r1, try core.readWord(sp + 4));
        try core.setRegister(.r2, try core.readWord(sp + 8));
        try core.setRegister(.r3, try core.readWord(sp + 12));
        try core.setRegister(.r12, try core.readWord(sp + 16));
        try core.setRegister(.lr, try core.readWord(sp + 20));
        const return_address = try core.readWord(sp + 24);
        const stacked_xpsr = try core.readWord(sp + 28);
        sp += frame_bytes;
        if (stacked_xpsr & xpsr_stack_align != 0) sp += 4;

        try core.setRegister(.sp, sp);
        try core.setRegister(.xpsr, stacked_xpsr & ~xpsr_stack_align);
        try core.setRegister(.pc, return_address & ~@as(u32, 1));
        try setActiveBit(core, finished.number, false);
        self.returned += 1;
    }

    /// The handler address for an exception, or null when the table does not
    /// carry one (unreadable, or a zero slot, which is what an image that
    /// never wired the exception up leaves behind).
    fn vectorFor(self: *Nvic, core: anytype, number: u16) !?u32 {
        const vtor = core.readWord(memmap.scb.vtor) catch 0;
        const table = if (vtor != 0) vtor else self.vector_base;
        const handler = core.readWord(table + 4 * @as(u32, number)) catch return null;
        if (handler == 0) return null;
        return handler & ~@as(u32, 1);
    }

    /// The most urgent pending exception that is enabled, or null. Ties go to
    /// the lower exception number, which is what the architecture does.
    fn pick(self: *Nvic, core: anytype) !?Candidate {
        _ = self;
        var best: ?Candidate = null;
        const icsr = try core.readWord(memmap.scb.icsr);
        const shpr3 = try core.readWord(memmap.scb.shpr3);
        // SysTick and PendSV have no enable of their own: pending is enough.
        if (icsr & icsr_pendstset != 0) {
            best = better(best, .{ .number = systick, .priority = @truncate(shpr3 >> 24) });
        }
        if (icsr & icsr_pendsvset != 0) {
            best = better(best, .{ .number = pendsv, .priority = @truncate(shpr3 >> 16) });
        }
        var word: u16 = 0;
        while (word < irq_words) : (word += 1) {
            const offset = 4 * @as(u32, word);
            const ready = (try core.readWord(memmap.nvic.ispr + offset)) &
                (try core.readWord(memmap.nvic.iser + offset));
            if (ready == 0) continue;
            var bit: u5 = 0;
            while (true) : (bit += 1) {
                if (ready & (@as(u32, 1) << bit) != 0) {
                    const line = word * 32 + bit;
                    best = better(best, .{
                        .number = first_irq + line,
                        .priority = try irqPriority(core, line),
                    });
                }
                if (bit == 31) break;
            }
        }
        return best;
    }
};

fn better(current: ?Candidate, candidate: Candidate) Candidate {
    const held = current orelse return candidate;
    if (candidate.priority < held.priority) return candidate;
    if (candidate.priority == held.priority and candidate.number < held.number) return candidate;
    return held;
}

/// NVIC_IPR is a byte per line, four to a word.
fn irqPriority(core: anytype, line: u16) !u8 {
    const word = try core.readWord(memmap.nvic.ipr + 4 * (@as(u32, line) / 4));
    return @truncate(word >> @intCast(8 * (line % 4)));
}

/// PRIMASK masks everything this model can take; NMI and HardFault ignore it
/// and neither is modelled yet. BASEPRI is not consulted for the same reason
/// the priorities barely matter yet: nothing here has two live sources.
fn masked(core: anytype) !bool {
    return (try core.register(.primask)) & primask_pm != 0;
}

fn clearPending(core: anytype, number: u16) !void {
    if (number == systick or number == pendsv) {
        const bit: u32 = if (number == systick) icsr_pendstset else icsr_pendsvset;
        const icsr = try core.readWord(memmap.scb.icsr);
        try core.writeWord(memmap.scb.icsr, icsr & ~bit);
        return;
    }
    const line = number - first_irq;
    const address = memmap.nvic.ispr + 4 * (@as(u32, line) / 32);
    const mask = @as(u32, 1) << @intCast(line % 32);
    try core.writeWord(address, (try core.readWord(address)) & ~mask);
}

/// NVIC_IABR: what a handler reads to ask whether a line is running.
fn setActiveBit(core: anytype, number: u16, active: bool) !void {
    if (number < first_irq) return;
    const line = number - first_irq;
    const address = memmap.nvic.iabr + 4 * (@as(u32, line) / 32);
    const mask = @as(u32, 1) << @intCast(line % 32);
    const current = try core.readWord(address);
    try core.writeWord(address, if (active) current | mask else current & ~mask);
}

/// The clear-side registers only work on hardware because the NVIC sees the
/// write. Against a plain-RAM PPB the word just sits there, so the fold is
/// done here instead: whatever the firmware put in ICER is removed from ISER,
/// whatever it put in ICPR is removed from ISPR, and the clear register is
/// emptied. A firmware that disables a line therefore stops seeing it from
/// the next chunk boundary, which is the same seam everything else moves on.
///
/// The one behaviour this cannot give back is the read side: on hardware ICER
/// reads as the enable state, here it reads as zero.
fn foldClearRegisters(core: anytype) !void {
    var word: u16 = 0;
    while (word < irq_words) : (word += 1) {
        const offset = 4 * @as(u32, word);
        try fold(core, memmap.nvic.icer + offset, memmap.nvic.iser + offset);
        try fold(core, memmap.nvic.icpr + offset, memmap.nvic.ispr + offset);
    }
    const icsr = try core.readWord(memmap.scb.icsr);
    var next = icsr;
    if (icsr & icsr_pendstclr != 0) next &= ~(icsr_pendstclr | icsr_pendstset);
    if (icsr & icsr_pendsvclr != 0) next &= ~(icsr_pendsvclr | icsr_pendsvset);
    if (next != icsr) try core.writeWord(memmap.scb.icsr, next);
}

fn fold(core: anytype, clear_register: u32, set_register: u32) !void {
    const clear = try core.readWord(clear_register);
    if (clear == 0) return;
    try core.writeWord(set_register, (try core.readWord(set_register)) & ~clear);
    try core.writeWord(clear_register, 0);
}

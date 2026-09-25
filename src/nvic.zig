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
const memmap = @import("memmap.zig");
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

/// A core-shaped stand-in: PPB words in a map, registers in an array, so the
/// controller can be tested without Unicorn underneath it.
const FakeCore = struct {
    const Name = enum { pc, sp, lr, r0, r1, r2, r3, r12, xpsr, primask };

    words: std.AutoHashMap(u32, u32),
    registers: std.EnumArray(Name, u32) = std.EnumArray(Name, u32).initFill(0),

    fn init(allocator: std.mem.Allocator) FakeCore {
        return .{ .words = std.AutoHashMap(u32, u32).init(allocator) };
    }

    fn deinit(self: *FakeCore) void {
        self.words.deinit();
    }

    fn readWord(self: *FakeCore, address: u32) !u32 {
        return self.words.get(address) orelse 0;
    }

    fn writeWord(self: *FakeCore, address: u32, value: u32) !void {
        try self.words.put(address, value);
    }

    fn register(self: *FakeCore, which: Name) !u32 {
        return self.registers.get(which);
    }

    fn setRegister(self: *FakeCore, which: Name, value: u32) !void {
        self.registers.set(which, value);
    }

    /// A vector table at 0x22000000 whose every handler is `base + 0x100 * n`.
    fn plantVectorTable(self: *FakeCore) !void {
        try self.writeWord(memmap.scb.vtor, 0x2200_0000);
        var number: u32 = 0;
        while (number < 48) : (number += 1) {
            try self.writeWord(0x2200_0000 + 4 * number, 0x2200_1000 + 0x100 * number + 1);
        }
    }

    fn handlerFor(number: u32) u32 {
        return 0x2200_1000 + 0x100 * number;
    }
};

test "a pended SysTick is entered with a stacked frame and an EXC_RETURN" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    try core.plantVectorTable();
    try core.setRegister(.sp, 0x2200_8000);
    try core.setRegister(.pc, 0x2200_0400);
    try core.setRegister(.r0, 0xAAAA_AAAA);
    try core.setRegister(.lr, 0x2200_0500);
    try core.writeWord(memmap.scb.icsr, icsr_pendstset);

    var irqs = Nvic{};
    try std.testing.expectEqual(@as(?u16, systick), try irqs.dispatch(&core));
    try std.testing.expectEqual(FakeCore.handlerFor(systick), try core.register(.pc));
    try std.testing.expectEqual(exc_return_thread_msp, try core.register(.lr));
    try std.testing.expectEqual(@as(u32, systick), (try core.register(.xpsr)) & ipsr_mask);
    try std.testing.expectEqual(@as(u32, 0x2200_8000 - frame_bytes), try core.register(.sp));
    try std.testing.expectEqual(@as(u32, 0xAAAA_AAAA), try core.readWord(0x2200_8000 - frame_bytes));
    try std.testing.expectEqual(@as(u32, 0x2200_0400), try core.readWord(0x2200_8000 - 8));
    // Taking it consumed the pend: it is not taken twice.
    try std.testing.expectEqual(@as(?u16, null), try irqs.dispatch(&core));
}

test "returning restores the frame and lands back where the exception hit" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    try core.plantVectorTable();
    try core.setRegister(.sp, 0x2200_8000);
    try core.setRegister(.pc, 0x2200_0400);
    try core.setRegister(.r2, 0x1234_5678);
    try core.writeWord(memmap.scb.icsr, icsr_pendstset);

    var irqs = Nvic{};
    _ = try irqs.dispatch(&core);
    // The handler clobbers what it is allowed to clobber.
    try core.setRegister(.r2, 0);
    try core.setRegister(.pc, exc_return_thread_msp);
    try irqs.exit(&core);

    try std.testing.expectEqual(@as(u32, 0x2200_0400), try core.register(.pc));
    try std.testing.expectEqual(@as(u32, 0x1234_5678), try core.register(.r2));
    try std.testing.expectEqual(@as(u32, 0x2200_8000), try core.register(.sp));
    try std.testing.expectEqual(@as(u32, 0), (try core.register(.xpsr)) & ipsr_mask);
    try std.testing.expectEqual(@as(u64, 1), irqs.returned);
    try std.testing.expectEqual(@as(usize, 0), irqs.depth);
}

test "an unaligned stack pointer is padded and the pad is given back" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    try core.plantVectorTable();
    try core.setRegister(.sp, 0x2200_7FFC);
    try core.writeWord(memmap.scb.icsr, icsr_pendstset);

    var irqs = Nvic{};
    _ = try irqs.dispatch(&core);
    try std.testing.expectEqual(@as(u32, 0x2200_7FF8 - frame_bytes), try core.register(.sp));
    try std.testing.expect(try core.readWord(0x2200_7FF8 - 4) & xpsr_stack_align != 0);

    try core.setRegister(.pc, exc_return_thread_msp);
    try irqs.exit(&core);
    try std.testing.expectEqual(@as(u32, 0x2200_7FFC), try core.register(.sp));
}

test "cpsid i holds a pend instead of losing it" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    try core.plantVectorTable();
    try core.setRegister(.sp, 0x2200_8000);
    try core.setRegister(.primask, primask_pm);
    try core.writeWord(memmap.scb.icsr, icsr_pendstset);

    var irqs = Nvic{};
    try std.testing.expectEqual(@as(?u16, null), try irqs.dispatch(&core));
    try std.testing.expectEqual(@as(u64, 1), irqs.held);

    // cpsie i, and the exception that was waiting is taken.
    try core.setRegister(.primask, 0);
    try std.testing.expectEqual(@as(?u16, systick), try irqs.dispatch(&core));
}

test "an enabled line is taken, a disabled one is not" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    try core.plantVectorTable();
    try core.setRegister(.sp, 0x2200_8000);
    // Line 5 pending but not enabled.
    try core.writeWord(memmap.nvic.ispr, 1 << 5);

    var irqs = Nvic{};
    try std.testing.expectEqual(@as(?u16, null), try irqs.dispatch(&core));

    try core.writeWord(memmap.nvic.iser, 1 << 5);
    try std.testing.expectEqual(@as(?u16, first_irq + 5), try irqs.dispatch(&core));
    try std.testing.expect(try core.readWord(memmap.nvic.iabr) & (1 << 5) != 0);
    try core.setRegister(.pc, exc_return_thread_msp);
    try irqs.exit(&core);
    try std.testing.expectEqual(@as(u32, 0), try core.readWord(memmap.nvic.iabr));
}

test "a write to ICER disables the line it names" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    try core.plantVectorTable();
    try core.setRegister(.sp, 0x2200_8000);
    try core.writeWord(memmap.nvic.iser, (1 << 5) | (1 << 9));
    try core.writeWord(memmap.nvic.ispr, 1 << 5);
    try core.writeWord(memmap.nvic.icer, 1 << 5);

    var irqs = Nvic{};
    try std.testing.expectEqual(@as(?u16, null), try irqs.dispatch(&core));
    try std.testing.expectEqual(@as(u32, 1 << 9), try core.readWord(memmap.nvic.iser));
    try std.testing.expectEqual(@as(u32, 0), try core.readWord(memmap.nvic.icer));
}

test "ICSR's clear bit unpends SysTick before it is ever entered" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    try core.plantVectorTable();
    try core.setRegister(.sp, 0x2200_8000);
    try core.writeWord(memmap.scb.icsr, icsr_pendstset | icsr_pendstclr);

    var irqs = Nvic{};
    try std.testing.expectEqual(@as(?u16, null), try irqs.dispatch(&core));
    try std.testing.expectEqual(@as(u32, 0), try core.readWord(memmap.scb.icsr));
}

test "the more urgent line wins, and ties go to the lower exception number" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    try core.plantVectorTable();
    try core.setRegister(.sp, 0x2200_8000);
    try core.writeWord(memmap.nvic.iser, (1 << 2) | (1 << 3));
    try core.writeWord(memmap.nvic.ispr, (1 << 2) | (1 << 3));
    // IPR byte per line: line 2 at 0x80, line 3 at 0x20 (more urgent).
    try core.writeWord(memmap.nvic.ipr, (0x80 << 16) | (0x20 << 24));

    var irqs = Nvic{};
    try std.testing.expectEqual(@as(?u16, first_irq + 3), try irqs.dispatch(&core));
    try core.setRegister(.pc, exc_return_thread_msp);
    try irqs.exit(&core);
    try std.testing.expectEqual(@as(?u16, first_irq + 2), try irqs.dispatch(&core));

    // Same priority now, so the lower number goes first.
    try core.setRegister(.pc, exc_return_thread_msp);
    try irqs.exit(&core);
    try core.writeWord(memmap.nvic.ipr, 0);
    try core.writeWord(memmap.nvic.ispr, (1 << 2) | (1 << 3));
    try std.testing.expectEqual(@as(?u16, first_irq + 2), try irqs.dispatch(&core));
}

test "a running handler is only preempted by something more urgent" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    try core.plantVectorTable();
    try core.setRegister(.sp, 0x2200_8000);
    try core.writeWord(memmap.nvic.iser, (1 << 2) | (1 << 3));
    try core.writeWord(memmap.nvic.ispr, 1 << 2);
    try core.writeWord(memmap.nvic.ipr, (0x40 << 16) | (0x40 << 24));

    var irqs = Nvic{};
    try std.testing.expectEqual(@as(?u16, first_irq + 2), try irqs.dispatch(&core));

    // Equal priority does not preempt.
    try core.writeWord(memmap.nvic.ispr, 1 << 3);
    try std.testing.expectEqual(@as(?u16, null), try irqs.dispatch(&core));
    try std.testing.expectEqual(@as(u64, 1), irqs.held);

    // More urgent does, and nests: LR says the return is into a handler.
    try core.writeWord(memmap.nvic.ipr, (0x40 << 16) | (0x10 << 24));
    try std.testing.expectEqual(@as(?u16, first_irq + 3), try irqs.dispatch(&core));
    try std.testing.expectEqual(exc_return_handler_msp, try core.register(.lr));
    try std.testing.expectEqual(@as(usize, 2), irqs.depth);
}

test "EXC_RETURN is recognised and ordinary addresses are not" {
    try std.testing.expect(isExceptionReturn(exc_return_thread_msp));
    try std.testing.expect(isExceptionReturn(exc_return_handler_msp));
    try std.testing.expect(!isExceptionReturn(0x2200_0400));
    try std.testing.expect(!isExceptionReturn(memmap.ppb_base));
}

test "returning with nothing active is an error, not a silent unwind" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    var irqs = Nvic{};
    try std.testing.expectError(Error.NotInHandler, irqs.exit(&core));
}

test "a pend with no handler in the table is held, not jumped to" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    try core.setRegister(.sp, 0x2200_8000);
    try core.writeWord(memmap.scb.icsr, icsr_pendstset);

    // No VTOR, no fallback base, so nothing to enter.
    var irqs = Nvic{};
    try std.testing.expectEqual(@as(?u16, null), try irqs.dispatch(&core));
    try std.testing.expectEqual(@as(u64, 1), irqs.held);
    try std.testing.expect(try core.readWord(memmap.scb.icsr) & icsr_pendstset != 0);
}

test "with VTOR still zero the reset vector base is where the table is" {
    var core = FakeCore.init(std.testing.allocator);
    defer core.deinit();
    try core.plantVectorTable();
    // The image never relocated the table: VTOR reads as it resets.
    try core.writeWord(memmap.scb.vtor, 0);
    try core.setRegister(.sp, 0x2200_8000);
    try core.writeWord(memmap.scb.icsr, icsr_pendstset);

    var irqs = Nvic{ .vector_base = 0x2200_0000 };
    try std.testing.expectEqual(@as(?u16, systick), try irqs.dispatch(&core));
    try std.testing.expectEqual(FakeCore.handlerFor(systick), try core.register(.pc));
}

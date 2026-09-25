//! The ICU event-link table: how a peripheral event becomes an NVIC line.
//!
//! On this part a peripheral does not own an interrupt line. It raises a
//! numbered event, and the Interrupt Controller Unit decides which of its 96
//! NVIC lines that event drives: IELSR[n].IELS holds the event number line n
//! listens for, and firmware writes it there (`ra8_isr_register` /
//! `ra8_icu_route`) before it enables the line. Until this file existed the
//! Zig tree had no path from a block to an interrupt at all: src/periph/sci.zig
//! landed with its transmit and receive interrupts deliberately left out,
//! because there was nothing to raise them into, so an interrupt-driven
//! `ra8_sci_write` printed nothing and waited forever on a flag its handler
//! was supposed to set. Ported from the ICU half of board_periph.c on dev.
//!
//!   IELSR[0..95] (+0x6300, 32-bit each, one per NVIC line)
//!     IELS[9:0]  the event this line listens for, 0 = unlinked
//!     IR    [16] the latched interrupt status flag, WRITE ZERO to clear
//!     DTCE  [24] DTC activation, retained here and consumed by nothing yet
//!
//! Only IELSR is registered on the bus. The rest of the ICU (IRQCR, the NMI
//! block, the wake-up masks, SELSR) is nobody's yet, and the sparse register
//! file answers a poll of an unmodelled register better than a block that
//! flatly returns zero for it, so the block claims the table and no more.
const memmap = @import("../core/memmap.zig");
const periph = @import("registry.zig");

/// R_ICU geometry (ra8_icu_regs.h): the block is at 0x4000_6000 and the
/// event-link table sits 0x6300 into it.
pub const icu_base: u32 = 0x4000_6000;
pub const off_ielsr: u32 = 0x6300;
pub const slots: usize = 96;
pub const win_base: u32 = icu_base + off_ielsr;
pub const win_span: u32 = @intCast(slots * 4);

/// IELSR fields (HUM Ch 14.2.17 p 547).
pub const field = struct {
    /// IELS[9:0]: the event number this line listens for. Zero is no link.
    pub const iels: u32 = 0x0000_03FF;
    /// IR[16]: the latched status flag. Cleared by writing ZERO, not one.
    pub const ir: u32 = 0x0001_0000;
    /// DTCE[24]: DTC activation enable. Retained, and nothing reads it yet.
    pub const dtce: u32 = 0x0100_0000;
};

/// The event-link table and the counters behind the end-of-run line.
pub const Icu = struct {
    links: [slots]u32 = [_]u32{0} ** slots,
    /// Events raised by a block that some slot was listening for.
    raised: u64 = 0,
    /// Events raised that no slot listens for. Silicon drops these too; they
    /// are counted because an unrouted event is almost always a firmware bug.
    unlinked: u64 = 0,
    /// NVIC lines pended from a fresh event.
    pends: u64 = 0,
    /// NVIC lines pended again because IR was still latched at a boundary.
    repends: u64 = 0,

    pub fn init() Icu {
        return .{};
    }

    /// An untouched unit stays out of the end-of-run report.
    pub fn quiet(self: *const Icu) bool {
        return self.raised == 0 and self.unlinked == 0;
    }

    /// The slot listening for `event`, or null. One slot owns a given event,
    /// so the first match wins, the same rule dev's scan uses. IELS = 0 means
    /// the slot is unlinked, so event zero never matches anything.
    pub fn slotFor(self: *const Icu, event: u16) ?usize {
        if (event == 0) return null;
        for (self.links, 0..) |link, index| {
            if (link & field.iels == event) return index;
        }
        return null;
    }

    pub fn latched(self: *const Icu, slot: usize) bool {
        return self.links[slot] & field.ir != 0;
    }

    /// A peripheral event fired: latch IR on the slot linked to it and pend
    /// that NVIC line. IR is a flag rather than a count, so an event raised
    /// again while the flag is still up latches nothing new.
    pub fn raise(self: *Icu, core: anytype, event: u16) !void {
        const slot = self.slotFor(event) orelse {
            self.unlinked += 1;
            return;
        };
        self.raised += 1;
        if (self.latched(slot)) return;
        self.links[slot] |= field.ir;
        try pend(core, slot);
        self.pends += 1;
    }

    /// Re-pend every line whose IR is still latched. The NVIC input is level
    /// driven from IR (HUM Ch 14.2.17), so a handler that returns without
    /// clearing the flag is entered again immediately. Call it at the chunk
    /// boundary, before the controller picks.
    pub fn repend(self: *Icu, core: anytype) !void {
        for (self.links, 0..) |link, slot| {
            if (link & field.ir == 0) continue;
            if (try isPending(core, slot)) continue;
            try pend(core, slot);
            self.repends += 1;
        }
    }

    /// Take every latched IR down without touching the links. A system reset
    /// clears IELSR outright on silicon; this tree keeps peripheral state
    /// across a reboot, so clearing the flags is the part that matters: a line
    /// still latched would be re-pended into a firmware that has not put its
    /// vector table back yet.
    pub fn clearLatches(self: *Icu) void {
        for (&self.links) |*link| link.* &= ~field.ir;
    }

    pub fn read(self: *Icu, address: u32, width: u3) u32 {
        _ = width;
        const slot = slotAt(address) orelse return 0;
        return self.links[slot];
    }

    /// IR is WRITE-ZERO-to-clear: a written 0 takes the latched flag down and
    /// a written 1 leaves it standing. Every other bit takes the written
    /// value. This is the polarity dev had inverted (its issue #170): a driver
    /// that ORs a 1 into IR to "clear" it clears nothing on silicon, and the
    /// re-pend above then re-enters the handler forever, which is the storm
    /// the bench hit while the emulator ran the same image clean.
    pub fn write(self: *Icu, address: u32, width: u3, value: u32) void {
        _ = width;
        const slot = slotAt(address) orelse return;
        const keep: u32 = if (value & field.ir != 0) self.links[slot] & field.ir else 0;
        self.links[slot] = (value & ~field.ir) | keep;
    }

    pub fn block(self: *Icu) periph.Block {
        return .{
            .name = "ICU event links",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// The address of one IELSR slot, so a test or a later slice does not have to
/// do the arithmetic itself.
pub fn slotAddress(slot: usize) u32 {
    return win_base + 4 * @as(u32, @intCast(slot));
}

/// The exception number an ICU line vectors through. Slot n is IRQn, and the
/// architecture numbers IRQ0 as exception 16.
pub fn exceptionFor(slot: usize) u16 {
    return @intCast(16 + slot);
}

fn slotAt(address: u32) ?usize {
    if (address < win_base or address >= win_base + win_span) return null;
    return (address - win_base) / 4;
}

/// Pend an ICU line in the NVIC. The PPB is plain RAM in this emulator, so the
/// ICU sets the ISPR bit and src/periph/nvic.zig picks it up at the same chunk
/// boundary.
///
/// The pend is unconditional, which is the one place this diverges from dev.
/// dev keeps its own ISER shadow and drops the pend when the line is disabled,
/// so an event that arrives a moment before the firmware enables its line is
/// lost for good. Here IR stays latched and the NVIC masks ISPR with ISER when
/// it picks, so enabling the line afterwards takes the interrupt, which is what
/// a level-driven IR does on silicon.
fn pend(core: anytype, slot: usize) !void {
    const address = pendingWord(slot);
    try core.writeWord(address, (try core.readWord(address)) | pendingBit(slot));
}

fn isPending(core: anytype, slot: usize) !bool {
    return (try core.readWord(pendingWord(slot))) & pendingBit(slot) != 0;
}

fn pendingWord(slot: usize) u32 {
    return memmap.nvic.ispr + 4 * (@as(u32, @intCast(slot)) / 32);
}

fn pendingBit(slot: usize) u32 {
    return @as(u32, 1) << @intCast(slot % 32);
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Icu = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Icu = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

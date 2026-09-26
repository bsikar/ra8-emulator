//! IPC: the cross-core mailbox, and which core a poke is meant to wake.
//!
//! The IPC unit sits at 0x4002_0000 and carries four channel windows from
//! 0xC0 up, 0x20 apart: IPC0 channels 0 and 1 run CPU1 -> CPU0, IPC1
//! channels 2 and 3 run CPU0 -> CPU1. A channel is a pending-IRQ byte plus a
//! four-stage message FIFO. The sender pushes a word into TXD and pokes
//! ISET; the receiver takes the interrupt, reads STA to see which line was
//! set, drains RXD while STA.RDY is up, and acknowledges through CLR. That
//! handshake is what the dual-core examples replace their done-flag polls
//! with, so it is what a headless run can check.
//!
//! Ported from board_periph_ipc.c on dev, with three things that model does
//! not do.
//!
//! A POKE WAKES THE RECEIVER, NOT THE SENDER. dev raises the event on
//! whichever engine performed the ISET store, for every channel, so a CPU0
//! write to an IPC1 channel raises ELC_EVENT_IPC_IRQ1 on CPU0 itself: the
//! core that sent the message takes the interrupt announcing it. Here the
//! receiving side decides. IPC0 channels raise into this board's event path,
//! because their receiver is the core this build runs; an IPC1 poke is
//! counted as addressed to a core that is not here and raises nothing, which
//! is what the run should say rather than a wake that went the wrong way.
//!
//! THE SEMAPHORES KEEP WHAT WAS WRITTEN. dev answers zero to every read
//! below the first channel window and drops every write there, so a driver
//! that claims a semaphore and reads it back to see whether it won reads
//! zero forever and can spin without end. The semaphore and NMI region is
//! not modelled here either, but it is shadowed rather than swallowed: a
//! read-modify-write survives, narrow stores keep the bytes they do not
//! name, and nothing in it is interpreted.
//!
//! A DROPPED MESSAGE IS COUNTED. dev latches FERR on a write into a full
//! FIFO and RERR on a read of an empty one, and its end-of-run line prints
//! only pushes and pops, so a run that overran the four stages reads exactly
//! like one that did not. The latches are kept, and the words the FIFO could
//! not take and the reads that found nothing are counted and reported.
//!
//! NOT MODELLED, AND NOT GUESSED: the semaphore protocol, the NMI window,
//! and any IPC interrupt besides the two receive events. The event is queued
//! for the chunk boundary rather than raised inside the store, which is how
//! every other block on this board offers one.
const std = @import("std");
const periph = @import("registry.zig");

/// IPC geometry (ra8_ipc_regs.h). The bus folds the Non-secure alias onto
/// this base before it arrives.
pub const win_base: u32 = 0x4002_0000;
pub const win_span: u32 = 0x140;

/// The channel windows: four of them, 0x20 apart, starting at 0xC0. Below
/// 0xC0 are the semaphores and the NMI window.
pub const ch0_offset: u32 = 0xC0;
pub const ch_stride: u32 = 0x20;
pub const ch_count: usize = 4;
/// Channels below this are IPC0 (CPU1 -> CPU0); the rest are IPC1.
pub const unit_split: usize = 2;
/// Four stages, the depth the hardware manual fixes.
pub const fifo_depth: usize = 4;

/// The registers this model interprets. Everything else is shadow.
pub const off_sta: u32 = 0x00;
pub const off_iset: u32 = 0x04;
pub const off_txd: u32 = 0x08;
pub const off_rxd: u32 = 0x0C;
pub const off_clr: u32 = 0x10;

pub const field = struct {
    /// STA and CLR: the eight maskable IRQ lines.
    pub const irq: u32 = 0x0000_00FF;
    /// STA.RDY, the receive FIFO holding something.
    pub const rdy: u32 = 0x0001_0000;
    /// STA.FULL, all four stages taken.
    pub const full: u32 = 0x0002_0000;
    /// STA.RERR, a read that found the FIFO empty.
    pub const rerr: u32 = 0x0100_0000;
    /// STA.FERR, a write that found the FIFO full.
    pub const ferr: u32 = 0x0200_0000;
    /// CLR.RST, empty the FIFO.
    pub const rst: u32 = 0x0001_0000;
    /// CLR.RCLR and CLR.FCLR, drop the sticky error latches.
    pub const rclr: u32 = 0x0100_0000;
    pub const fclr: u32 = 0x0200_0000;
};

/// The receive events the two units raise on their own side.
pub const event = struct {
    pub const ipc0_irq: u16 = 0x05B;
    pub const ipc1_irq: u16 = 0x05C;
};

/// One event per boundary: the line is already pending in the controller, so
/// a second raise before the core takes it would be the same line twice.
pub const Due = std.BoundedArray(u16, 1);

const shadow_words: usize = win_span / 4;

/// One channel: the pending IRQ lines, the four-stage message FIFO behind
/// them, and what the run should be told about the traffic it carried.
pub const Channel = struct {
    /// The IRQ lines ISET has latched and CLR has not yet dropped.
    pending: u32 = 0,
    /// Ring storage: `rd` is the oldest entry, `count` the fill level.
    word: [fifo_depth]u32 = .{0} ** fifo_depth,
    rd: usize = 0,
    count: usize = 0,
    /// The sticky error latches, which only CLR drops.
    rerr: bool = false,
    ferr: bool = false,
    /// ISET stores that latched at least one line.
    sends: u32 = 0,
    /// Words the FIFO took, and words it gave back.
    pushes: u32 = 0,
    pops: u32 = 0,
    /// Words a full FIFO could not take: the message never arrived.
    lost: u32 = 0,
    /// Reads that found the FIFO empty: no message was there to take.
    starved: u32 = 0,

    pub fn quiet(self: *const Channel) bool {
        return self.pending == 0 and self.count == 0 and self.sends == 0 and
            self.pushes == 0 and self.pops == 0 and self.lost == 0 and
            self.starved == 0 and !self.rerr and !self.ferr;
    }

    /// STA is composed, never stored: the FIFO bits follow the ring and the
    /// error bits follow the latches.
    pub fn status(self: *const Channel) u32 {
        var value: u32 = self.pending;
        if (self.count > 0) value |= field.rdy;
        if (self.count >= fifo_depth) value |= field.full;
        if (self.rerr) value |= field.rerr;
        if (self.ferr) value |= field.ferr;
        return value;
    }

    /// Latch the written IRQ lines. Returns whether anything was named, so
    /// the unit knows a store worth an event from one that said nothing.
    fn set(self: *Channel, value: u32) bool {
        const bits = value & field.irq;
        if (bits == 0) return false;
        self.pending |= bits;
        self.sends +%= 1;
        return true;
    }

    /// Push one word. A full FIFO drops it and latches FERR: on silicon the
    /// message is gone, and the run should say how many went that way.
    fn push(self: *Channel, value: u32) void {
        if (self.count >= fifo_depth) {
            self.ferr = true;
            self.lost +%= 1;
            return;
        }
        self.word[(self.rd + self.count) % fifo_depth] = value;
        self.count += 1;
        self.pushes +%= 1;
    }

    /// Pop the oldest word. An empty FIFO latches RERR and hands back zero:
    /// there was no message, and serving the last one again would invent it.
    fn pop(self: *Channel) u32 {
        if (self.count == 0) {
            self.rerr = true;
            self.starved +%= 1;
            return 0;
        }
        const taken = self.word[self.rd];
        self.rd = (self.rd + 1) % fifo_depth;
        self.count -= 1;
        self.pops +%= 1;
        return taken;
    }

    /// CLR is write-one-to-clear over the IRQ lines, plus the FIFO reset and
    /// the two error-latch clears.
    fn clear(self: *Channel, value: u32) void {
        self.pending &= ~(value & field.irq);
        if (value & field.rst != 0) {
            self.rd = 0;
            self.count = 0;
        }
        if (value & field.rclr != 0) self.rerr = false;
        if (value & field.fclr != 0) self.ferr = false;
    }
};

/// Where an offset in the window lands.
const Slot = struct { index: usize, reg: u32 };

pub const Ipc = struct {
    channels: [ch_count]Channel = .{Channel{}} ** ch_count,
    /// The semaphore and NMI region, and the padding inside each channel
    /// window. Held so a read-modify-write survives, never interpreted.
    shadow: [shadow_words]u32 = .{0} ** shadow_words,
    /// An IPC0 poke waiting for the chunk boundary to be offered as an event.
    raised: bool = false,
    /// Events handed to the board's event path.
    wakes: u32 = 0,
    /// ISET stores on a channel whose receiving core this build does not run.
    undelivered: u32 = 0,

    pub fn init() Ipc {
        return .{};
    }

    pub fn quiet(self: *const Ipc) bool {
        if (self.wakes != 0 or self.undelivered != 0) return false;
        for (&self.channels) |*unit| {
            if (!unit.quiet()) return false;
        }
        return true;
    }

    /// The receive event a poke earned, offered once per boundary.
    pub fn dueEvents(self: *Ipc) Due {
        var due = Due{};
        if (!self.raised) return due;
        self.raised = false;
        self.wakes +%= 1;
        due.appendAssumeCapacity(event.ipc0_irq);
        return due;
    }

    pub fn read(self: *Ipc, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        if (offset >= win_span) return 0;
        const byte = offset % 4;
        if (decode(offset)) |slot| {
            const unit = &self.channels[slot.index];
            switch (slot.reg) {
                off_sta => return part(unit.status(), byte, width),
                off_rxd => return part(unit.pop(), byte, width),
                // ISET, TXD and CLR are actions; nothing sits behind them.
                off_iset, off_txd, off_clr => return 0,
                else => {},
            }
        }
        return part(self.shadow[offset / 4], byte, width);
    }

    pub fn write(self: *Ipc, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        if (offset >= win_span) return;
        const byte = offset % 4;
        if (decode(offset)) |slot| {
            const named = merge(0, byte, width, value);
            switch (slot.reg) {
                off_iset => self.poke(slot.index, named),
                off_txd => self.channels[slot.index].push(named),
                off_clr => self.channels[slot.index].clear(named),
                // Status, and a status register does not take a store.
                off_sta, off_rxd => {},
                else => self.shadowWrite(offset, byte, width, value),
            }
            return;
        }
        self.shadowWrite(offset, byte, width, value);
    }

    /// Latch the lines, then decide who the poke was for. Only the unit whose
    /// receiver is the core this build runs raises anything.
    fn poke(self: *Ipc, index: usize, value: u32) void {
        if (!self.channels[index].set(value)) return;
        if (index < unit_split) {
            self.raised = true;
        } else {
            self.undelivered +%= 1;
        }
    }

    fn shadowWrite(self: *Ipc, offset: u32, byte: u32, width: u3, value: u32) void {
        const word = offset / 4;
        self.shadow[word] = merge(self.shadow[word], byte, width, value);
    }

    pub fn block(self: *Ipc) periph.Block {
        return .{
            .name = "IPC",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// Which channel an offset belongs to, and which register inside it. Null
/// for the semaphore and NMI region below the first window.
fn decode(offset: u32) ?Slot {
    if (offset < ch0_offset) return null;
    const relative = offset - ch0_offset;
    const index = relative / ch_stride;
    if (index >= ch_count) return null;
    return .{ .index = index, .reg = (relative % ch_stride) & ~@as(u32, 3) };
}

/// The bits an access of this width names.
fn widthMask(width: u3) u32 {
    return switch (width) {
        1 => 0xFF,
        2 => 0xFFFF,
        else => 0xFFFF_FFFF,
    };
}

/// The part of a 32-bit register a narrow access names.
fn part(value: u32, byte_offset: u32, width: u3) u32 {
    if (width >= 4) return value;
    const shift: u5 = @intCast(byte_offset * 8);
    return (value >> shift) & widthMask(width);
}

/// Fold a narrow write into a 32-bit register, leaving the bytes the access
/// does not name where they were.
fn merge(current: u32, byte_offset: u32, width: u3, value: u32) u32 {
    if (width >= 4) return value;
    const shift: u5 = @intCast(byte_offset * 8);
    const bits = widthMask(width);
    const window: u32 = bits << shift;
    return (current & ~window) | ((value & bits) << shift);
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Ipc = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Ipc = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The base address of one channel window, so a test or a later slice does
/// not do the arithmetic itself.
pub fn channelAddress(index: usize) u32 {
    return win_base + ch0_offset + @as(u32, @intCast(index)) * ch_stride;
}

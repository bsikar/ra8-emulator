//! CAN-FD: the two controllers, the mode state machine a driver waits on,
//! and the difference between a frame that was transmitted and one that was
//! received.
//!
//! CANFD0 sits at 0x4038_0000 and CANFD1 at 0x4038_2000, each a 0x1920-byte
//! channel window (ra8_canfd_regs.h, FSP R_CANFD_Type). There is no bus and
//! no other node here, so what a headless run can observe is the internal
//! loopback the `canfd_loopback` and `canfd_filter` examples drive: out of
//! reset mode, program the filter, write a frame into TX message buffer 0,
//! assert CFDTMC[0].TMTR, then poll RX FIFO 0 and read the frame back.
//!
//! Ported from board_periph_canfd.c on dev, with five things that model does
//! not do.
//!
//! THE PART COMES UP IN RESET MODE. dev powers every register up at zero, and
//! zero in CFDGSTS reads as operation mode, so an image that never programmed
//! the state machine transmits there and would sit in global reset on
//! silicon. Here both machines power up in reset, which is also what the
//! driver's first poll is waiting to see.
//!
//! A TRANSMIT NEEDS AN OPERATING CHANNEL. dev copies the TX buffer into the
//! receive stage on any TMTR whatever the two mode registers say. Here a
//! request made while either machine is out of operation mode moves nothing:
//! it is refused and counted, so the run says the channel was never started.
//!
//! THE RECEIVE SIDE IS A FIFO. dev keeps one stage and overwrites it, so a
//! second frame delivered before the firmware reads silently replaces the
//! first and the reader never learns it missed one. Here the stages queue,
//! oldest first, and a delivery with no stage free is counted as lost.
//!
//! A POP TAKES A FRAME THAT WAS THERE. dev's CFDRFPCTR write sets RFEMP and
//! drops RFIF whatever the FIFO holds, so a pop with nothing queued reports
//! an empty FIFO the firmware never drained, and the window keeps answering
//! with the frame it last held. Here a pop of an empty FIFO is refused and
//! counted, and the window reads zero once the last frame has been taken.
//!
//! STATUS IS WHAT THE CONTROLLER RAISED. dev drops every store into the flat
//! register array, so firmware can write CFDRFSTS itself and read back a
//! frame that never arrived. Refused and counted here, the SRAMESR / CETCR /
//! INTS pattern, and narrow writes keep the bytes they do not name, which
//! dev's reg[off / 4] = value wipes.
//!
//! KEPT FROM DEV DELIBERATELY: the acceptance filter and its open-when-empty
//! rule, so an image that programs no CFDGAFL entry keeps receiving
//! everything, and a programmed entry drops the identifier it does not match.
//!
//! NOT MODELLED, AND NOT GUESSED: bit timing and the rate registers, the
//! other RX FIFOs and the receive buffers, TX queues and history, error
//! counters and the bus-off machine, and every interrupt besides the
//! RX-FIFO one. The rest of the window is shadowed, and never read.
const std = @import("std");
const periph = @import("registry.zig");
const fifo = @import("canfd_fifo.zig");

/// CANFD geometry. The Non-secure alias is folded onto these by the bus.
pub const unit0_base: u32 = 0x4038_0000;
pub const unit1_base: u32 = 0x4038_2000;
pub const win_span: u32 = 0x1920;
pub const unit_count: usize = 2;

/// The registers this model interprets. Everything else is shadow.
pub const off_cnctr: u32 = 0x004;
pub const off_cnsts: u32 = 0x008;
pub const off_gctr: u32 = 0x018;
pub const off_gsts: u32 = 0x01C;
pub const off_rfsts0: u32 = 0x044;
pub const off_rfpctr0: u32 = 0x04C;
pub const off_tmc0: u32 = 0x070;
pub const off_tmsts0: u32 = 0x074;
pub const off_afl: u32 = 0x120;
pub const off_rf0: u32 = 0x520;
pub const off_tm0: u32 = 0x604;

/// The acceptance-filter page this model reads: sixteen entries of
/// {ID, mask, page 0, page 1}, as dev reads them.
pub const afl = struct {
    pub const stride: u32 = 0x10;
    pub const count: usize = 16;
};

/// The status and control bits dev's own masks name.
pub const field = struct {
    /// CFDGSTS.GRSTSTS, global reset status.
    pub const grststs: u32 = 1 << 0;
    /// CFDGSTS.GHLTSTS, global halt status.
    pub const ghltsts: u32 = 1 << 1;
    /// CFDGSTS.GRAMINIT, message-RAM init in progress. Clear from power-up
    /// here as on dev: there is no RAM to initialise.
    pub const graminit: u32 = 1 << 3;
    /// CFDC.STS.CRSTSTS, channel reset status.
    pub const crststs: u32 = 1 << 0;
    /// CFDC.STS.CHLTSTS, channel halt status.
    pub const chltsts: u32 = 1 << 1;
    /// CFDRFSTS.RFEMP, the FIFO is empty.
    pub const rfemp: u32 = 1 << 0;
    /// CFDRFSTS.RFIF, a frame is waiting.
    pub const rfif: u32 = 1 << 3;
    /// CFDTMC.TMTR, the transmit request.
    pub const tmtr: u32 = 1 << 0;
    /// CFDTMSTS.TMTRF = 10b, transmission complete.
    pub const tmtrf_done: u32 = 0x04;
    /// GMDC / CHMDC, the two-bit mode field both control registers carry.
    pub const mode: u32 = 0x3;
};

/// The CANFD0 RX-FIFO event, carried over from dev at its own best-effort
/// value: no FSP bsp_elc.h is installed here to check it against. Nothing in
/// this tree routes it, so it costs a polled image nothing and gives an
/// interrupt-driven one something to take.
pub const event = struct {
    pub const can0_rxf: u16 = 0x33D;
};

/// One event per boundary: the line is pending in the controller until the
/// firmware clears it, so re-raising every stage would say nothing new.
pub const Due = std.BoundedArray(u16, 1);

/// The three states both machines walk. A reserved encoding lands on
/// operation, which is what dev's else branch does.
pub const Mode = enum {
    operation,
    reset,
    halt,

    pub fn fromBits(value: u32) Mode {
        return switch (value & field.mode) {
            1 => .reset,
            2 => .halt,
            else => .operation,
        };
    }
};

const shadow_words: usize = win_span / 4;
const frame_span: u32 = @as(u32, fifo.frame_words) * 4;

/// One controller: the two mode machines, the receive FIFO, and what the run
/// should be told about the traffic it was given.
pub const Unit = struct {
    /// The state machines, both in reset from power-up as on silicon.
    global: Mode = .reset,
    channel: Mode = .reset,
    /// CFDTMC[0], with TMTR cleared once the frame has gone.
    tmc: u32 = 0,
    /// CFDTMSTS[0], set by the controller and by nothing else.
    tmsts: u32 = 0,
    queue: fifo.Fifo = .{},
    shadow: [shadow_words]u32 = .{0} ** shadow_words,
    /// Frames clocked out of the transmit buffer.
    sent: u32 = 0,
    /// Frames the filter accepted and a stage took.
    received: u32 = 0,
    /// Frames transmitted and dropped by the acceptance filter.
    filtered: u32 = 0,
    /// Transmit requests made out of operation mode: nothing left.
    refused: u32 = 0,
    /// Accepted frames with no stage free.
    lost: u32 = 0,
    /// Pops of an empty FIFO.
    starved: u32 = 0,
    /// Stores into a status register the controller owns.
    faked: u32 = 0,

    pub fn quiet(self: *const Unit) bool {
        return self.sent == 0 and self.refused == 0 and self.starved == 0 and
            self.faked == 0 and self.global == .reset and self.channel == .reset;
    }

    /// Both machines have to be in operation before a frame can go.
    pub fn running(self: *const Unit) bool {
        return self.global == .operation and self.channel == .operation;
    }

    fn globalStatus(self: *const Unit) u32 {
        return switch (self.global) {
            .reset => field.grststs,
            .halt => field.ghltsts,
            .operation => 0,
        };
    }

    fn channelStatus(self: *const Unit) u32 {
        return switch (self.channel) {
            .reset => field.crststs,
            .halt => field.chltsts,
            .operation => 0,
        };
    }

    fn fifoStatus(self: *const Unit) u32 {
        if (self.queue.empty()) return field.rfemp;
        return field.rfif;
    }

    /// Does the programmed filter let this identifier through? An entry is
    /// active once its mask is non-zero, and with no active entry the filter
    /// is open. Carried from dev, including the open-when-empty rule.
    pub fn accepts(self: *const Unit, id: u32) bool {
        var active = false;
        for (0..afl.count) |slot| {
            const entry = off_afl + @as(u32, @intCast(slot)) * afl.stride;
            const mask = self.shadow[entry / 4 + 1] & fifo.id_mask.extended;
            if (mask == 0) continue;
            active = true;
            const wanted = self.shadow[entry / 4] & fifo.id_mask.extended;
            if (id & mask == wanted & mask) return true;
        }
        return !active;
    }

    /// Clock the frame in TX message buffer 0 out and, if the filter takes
    /// it, into the receive FIFO. True when a stage took it, which is the
    /// only case worth an event.
    fn transmit(self: *Unit) bool {
        if (!self.running()) {
            self.refused +%= 1;
            return false;
        }
        var frame = fifo.Frame{};
        for (&frame.words, 0..) |*word, index| {
            word.* = self.shadow[off_tm0 / 4 + index];
        }
        // The frame left the buffer whatever the filter decides: the request
        // completes and TMTR drops, as it does when the arbitration is won.
        self.sent +%= 1;
        self.tmc &= ~field.tmtr;
        self.tmsts = field.tmtrf_done;
        if (!self.accepts(frame.id())) {
            self.filtered +%= 1;
            return false;
        }
        if (!self.queue.push(frame)) {
            self.lost +%= 1;
            return false;
        }
        self.received +%= 1;
        return true;
    }

    /// CFDRFPCTR: advance past the frame the window is showing. A pop with
    /// nothing queued is a drain the firmware did not make.
    fn popFrame(self: *Unit) void {
        if (!self.queue.pop()) self.starved +%= 1;
    }

    fn readWord(self: *const Unit, offset: u32) u32 {
        if (offset >= off_rf0 and offset < off_rf0 + frame_span) {
            return self.queue.word((offset - off_rf0) / 4);
        }
        return switch (offset) {
            off_gsts => self.globalStatus(),
            off_cnsts => self.channelStatus(),
            off_rfsts0 => self.fifoStatus(),
            off_tmc0 => self.tmc,
            off_tmsts0 => self.tmsts,
            // Write-only: the pointer control has nothing behind it.
            off_rfpctr0 => 0,
            else => self.shadow[offset / 4],
        };
    }

    /// Returns true when the frame reached a stage, so the caller can offer
    /// the receive event.
    fn writeWord(self: *Unit, offset: u32, byte: u32, width: u3, value: u32) bool {
        switch (offset) {
            off_gctr => {
                const held = merge(self.shadow[offset / 4], byte, width, value);
                self.shadow[offset / 4] = held;
                self.global = Mode.fromBits(held);
            },
            off_cnctr => {
                const held = merge(self.shadow[offset / 4], byte, width, value);
                self.shadow[offset / 4] = held;
                self.channel = Mode.fromBits(held);
            },
            off_gsts, off_cnsts, off_rfsts0, off_tmsts0 => self.faked +%= 1,
            off_tmc0 => {
                self.tmc = merge(self.tmc, byte, width, value);
                if (self.tmc & field.tmtr != 0) return self.transmit();
            },
            off_rfpctr0 => self.popFrame(),
            else => {
                const word = offset / 4;
                self.shadow[word] = merge(self.shadow[word], byte, width, value);
            },
        }
        return false;
    }
};

pub const Canfd = struct {
    units: [unit_count]Unit = .{Unit{}} ** unit_count,
    /// A delivery on CANFD0 waiting for the chunk boundary.
    raised: bool = false,
    /// Events handed to the board's event path.
    wakes: u32 = 0,

    pub fn init() Canfd {
        return .{};
    }

    pub fn quiet(self: *const Canfd) bool {
        if (self.wakes != 0) return false;
        for (&self.units) |*unit| {
            if (!unit.quiet()) return false;
        }
        return true;
    }

    /// The receive event a delivered frame earned, offered once per boundary.
    pub fn dueEvents(self: *Canfd) Due {
        var due = Due{};
        if (!self.raised) return due;
        self.raised = false;
        self.wakes +%= 1;
        due.appendAssumeCapacity(event.can0_rxf);
        return due;
    }

    pub fn read(self: *Canfd, address: u32, width: u3) u32 {
        const index = unitIndex(address) orelse return 0;
        const offset = address - unitBase(index);
        return part(self.units[index].readWord(offset & ~@as(u32, 3)), offset % 4, width);
    }

    pub fn write(self: *Canfd, address: u32, width: u3, value: u32) void {
        const index = unitIndex(address) orelse return;
        const offset = address - unitBase(index);
        const delivered = self.units[index].writeWord(
            offset & ~@as(u32, 3),
            offset % 4,
            width,
            value,
        );
        if (delivered and index == 0) self.raised = true;
    }

    /// One block per controller: the two windows are 0x2000 apart and only
    /// 0x1920 wide, so the gap between them is not ours to answer for.
    pub fn block(self: *Canfd, index: usize) periph.Block {
        return .{
            .name = if (index == 0) "CANFD0" else "CANFD1",
            .base = unitBase(index),
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// The base address of one controller, so a test or a later slice does not do
/// the arithmetic itself.
pub fn unitBase(index: usize) u32 {
    return if (index == 0) unit0_base else unit1_base;
}

fn unitIndex(address: u32) ?usize {
    for (0..unit_count) |index| {
        const start = unitBase(index);
        if (address >= start and address - start < win_span) return index;
    }
    return null;
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
    const self: *Canfd = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Canfd = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

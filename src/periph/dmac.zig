//! DMAC0: the direct memory access controller, which copies a buffer on one
//! register store instead of a loop of loads and stores.
//!
//! Eight channels at 0x4000_A000, 0x40 apart. The shared module bank next
//! door, whose DMAST.DMST is the activation gate over all eight, is its own
//! file (dma_bank.zig) and this block asks it before every request. A channel is programmed with DMSAR, DMDAR, DMCRA, DMCRB, DMTMD
//! and DMAMD, armed with DMCNT.DTE, and triggered with a DMREQ.SWREQ store.
//! Unlike the DTC next door, nothing about the transfer lives in memory: the
//! registers ARE the descriptor, which is why there is no vector table here.
//!
//! Ported from board_periph_dmac.c on dev, with four of its behaviours
//! corrected rather than carried over, each named in the decisions below: dev
//! copies the whole count on one request whatever DMREQ.CLRS says, ignores
//! DMAST entirely, leaves DMCNT.DTE up after the count is spent, and treats
//! every address mode that is not increment as fixed.
//!
//! ONE DIVERGENCE OF THIS TREE'S OWN, SAID OUT LOUD: the copy happens inside
//! the SWREQ store, as it does on dev, but the transfer-end interrupt does
//! not: it is queued and raised at the chunk boundary with the rest of the
//! events, so firmware sees the bytes immediately and the interrupt one
//! boundary later.
const std = @import("std");

const engine = @import("../core/engine.zig");
const dma_bank = @import("dma_bank.zig");
const periph = @import("registry.zig");
const xfer = @import("dmac_xfer.zig");

/// DMAC0 channel geometry (ra8_dmac_regs.h).
pub const win_base: u32 = 0x4000_A000;
pub const channel_stride: u32 = 0x40;
pub const channel_count: usize = 8;
pub const win_span: u32 = channel_stride * @as(u32, channel_count);

/// DMAC0 channel-0 transfer-end event; the eight channels run from there.
pub const event_base: u16 = 0x0E0;

/// Per-channel register offsets (the subset a driver touches).
pub const off = struct {
    pub const dmsar: u32 = 0x00;
    pub const dmdar: u32 = 0x04;
    pub const dmcra: u32 = 0x08;
    pub const dmcrb: u32 = 0x0C;
    pub const dmtmd: u32 = 0x10;
    pub const dmint: u32 = 0x13;
    pub const dmamd: u32 = 0x14;
    pub const dmofr: u32 = 0x18;
    pub const dmcnt: u32 = 0x1C;
    pub const dmreq: u32 = 0x1D;
    pub const dmsts: u32 = 0x1E;
};

pub const field = struct {
    /// DMCNT.DTE b0: this channel is armed.
    pub const dte: u8 = 0x01;
    /// DMREQ.SWREQ b0: the software transfer request.
    pub const swreq: u8 = 0x01;
    /// DMREQ.CLRS b4: keep the request set, so one store drains the count.
    pub const clrs: u8 = 0x10;
    /// DMINT.DTIE b4: interrupt the CPU when the count is spent.
    pub const dtie: u8 = 0x10;
    /// DMSTS.DTIF b4: transfer-end status, write 0 to clear.
    pub const dtif: u8 = 0x10;
    /// DMSTS.ACT b7: a transfer is in progress.
    pub const act: u8 = 0x80;
};

/// A ceiling on one continuous request, so a mis-programmed channel stops
/// instead of walking the whole address space.
pub const max_units: u32 = 0x1_0000;

/// Why a request moved nothing. Every one of these reads back to the firmware
/// as a channel that simply did not transfer, so they are counted and
/// reported rather than passed over.
pub const Refusal = union(enum) {
    /// DMAST.DMST is clear: the module was never started, so no channel
    /// transfers. dev shadows DMAST and copies anyway.
    stopped,
    /// DMCNT.DTE is clear, which is also what a finished channel looks like.
    disarmed,
    /// The count is spent and the channel was not re-armed.
    spent,
    /// No engine behind the board, which only a test builds.
    unbacked,
    /// A channel shape this model will not invent a transfer for.
    unsupported: xfer.Unsupported,
};

pub fn refusalName(reason: Refusal) []const u8 {
    return switch (reason) {
        .unsupported => |detail| @tagName(detail),
        else => @tagName(reason),
    };
}

pub const Due = std.BoundedArray(u16, channel_count);

/// One channel: its registers, the counts it latched when it was armed, and
/// what it has moved.
pub const Channel = struct {
    dmsar: u32 = 0,
    dmdar: u32 = 0,
    dmcra: u32 = 0,
    dmcrb: u32 = 0,
    dmofr: u32 = 0,
    dmtmd: u16 = 0,
    dmamd: u16 = 0,
    dmint: u8 = 0,
    dmcnt: u8 = 0,
    dmsts: u8 = 0,
    /// Units left in the current block, latched from DMCRAL when DTE went up.
    pending: u32 = 0,
    /// Blocks left, latched from DMCRB.
    blocks: u32 = 0,
    requests: u32 = 0,
    units: u64 = 0,
    bytes: u64 = 0,
    completions: u32 = 0,
    /// Units a memory fault cut short.
    faults: u32 = 0,

    pub fn armed(self: *const Channel) bool {
        return self.dmcnt & field.dte != 0;
    }

    pub fn plan(self: *const Channel) xfer.Plan {
        return xfer.Plan.decode(self.dmtmd, self.dmamd);
    }

    pub fn quiet(self: *const Channel) bool {
        return self.requests == 0 and !self.armed();
    }

    /// DMCNT.DTE going up loads the counts, the way silicon does: a channel
    /// whose count is spent has to be re-armed before it moves again.
    fn arm(self: *Channel) void {
        self.pending = xfer.latchedCount(self.dmcra);
        self.blocks = xfer.latchedBlocks(self.dmcrb);
    }

    /// Spend one request's worth of counts and answer the units it is worth.
    fn spend(self: *Channel, shape: xfer.Plan) u32 {
        if (shape.mode != .block) {
            self.pending -= 1;
            return 1;
        }
        const size = @min(xfer.blockSize(self.dmcra), max_units);
        self.blocks -= 1;
        if (self.blocks == 0) self.pending = 0;
        return size;
    }

    fn done(self: *const Channel, shape: xfer.Plan) bool {
        return if (shape.mode == .block) self.blocks == 0 else self.pending == 0;
    }
};

/// The eight channels, the module gate over them, and the counters behind the
/// end-of-run line.
pub const Dmac = struct {
    channels: [channel_count]Channel = [_]Channel{.{}} ** channel_count,
    /// The machine whose memory a transfer moves. Board.attach points this at
    /// the run's engine; a board built without one declines every request.
    memory: ?engine.Engine = null,
    /// The module bank next door, whose DMAST.DMST gates every channel.
    /// Board.attach points this at the board's own bank, not a copy.
    bank: *const dma_bank.Bank,
    due: Due = Due{},
    refused: u32 = 0,
    last_refusal: ?Refusal = null,

    pub fn init(bank: *const dma_bank.Bank) Dmac {
        return .{ .bank = bank };
    }

    pub fn started(self: *const Dmac) bool {
        return self.bank.started();
    }

    pub fn quiet(self: *const Dmac) bool {
        if (self.refused != 0 or self.started()) return false;
        for (&self.channels) |*channel| {
            if (!channel.quiet()) return false;
        }
        return true;
    }

    /// The transfer-end interrupts this boundary, drained by the board.
    pub fn dueEvents(self: *Dmac) Due {
        const ready = self.due;
        self.due = Due{};
        return ready;
    }

    /// One software transfer request on a channel. With DMREQ.CLRS clear the
    /// request is worth ONE transfer and clears itself, which is the line dev
    /// gets wrong; with CLRS set it stays asserted and the count drains.
    pub fn request(self: *Dmac, index: usize, continuous: bool) void {
        const shape = self.channels[index].plan();
        if (!self.started()) return self.refuse(.stopped);
        if (!self.channels[index].armed()) return self.refuse(.disarmed);
        if (shape.unsupported()) |reason| return self.refuse(.{ .unsupported = reason });
        if (self.channels[index].pending == 0) return self.refuse(.spent);
        if (self.memory == null) return self.refuse(.unbacked);
        self.channels[index].dmsts |= field.act;
        while (true) {
            self.transfer(index, shape);
            if (!continuous or self.channels[index].done(shape)) break;
        }
        self.settle(index, shape);
    }

    /// One request's worth of units, with the addresses and the running count
    /// left where they now stand so a polling driver sees progress.
    fn transfer(self: *Dmac, index: usize, shape: xfer.Plan) void {
        const channel = &self.channels[index];
        const units = @min(channel.spend(shape), max_units);
        const moved = self.copy(channel, shape, units);
        channel.requests +%= 1;
        channel.units += moved;
        channel.bytes += moved * shape.unit();
        if (moved != units) channel.faults +%= 1;
        channel.dmcra = xfer.withCount(channel.dmcra, channel.pending);
        channel.dmcrb = channel.blocks;
    }

    /// Move `units` units, walking each address by what its mode says. A unit
    /// memory refuses stops the transfer where it stands rather than skipping
    /// on, so the addresses left behind are the ones that faulted.
    fn copy(self: *Dmac, channel: *Channel, shape: xfer.Plan, units: u32) u32 {
        const memory = self.memory.?;
        const width = shape.unit();
        const source_step = shape.step(shape.source);
        const dest_step = shape.step(shape.destination);
        var cell: [4]u8 = undefined;
        var moved: u32 = 0;
        while (moved < units) : (moved += 1) {
            const slice = cell[0..width];
            memory.read(channel.dmsar, slice) catch return moved;
            memory.write(channel.dmdar, slice) catch return moved;
            channel.dmsar = xfer.walk(channel.dmsar, source_step);
            channel.dmdar = xfer.walk(channel.dmdar, dest_step);
        }
        return moved;
    }

    /// The transfer is synchronous here, so ACT is down again by the time the
    /// store returns. A spent count takes DTE down with it (dev leaves it up,
    /// and its zero count then reads as a full 1024 units on the next
    /// request) and queues the transfer-end interrupt if DMINT.DTIE is set.
    fn settle(self: *Dmac, index: usize, shape: xfer.Plan) void {
        const channel = &self.channels[index];
        channel.dmsts &= ~field.act;
        if (!channel.done(shape)) return;
        channel.dmcnt &= ~field.dte;
        channel.dmsts |= field.dtif;
        channel.completions +%= 1;
        if (channel.dmint & field.dtie == 0) return;
        self.due.append(event_base + @as(u16, @intCast(index))) catch {};
    }

    fn refuse(self: *Dmac, reason: Refusal) void {
        self.last_refusal = reason;
        self.refused +%= 1;
    }

    pub fn read(self: *Dmac, address: u32, width: u3) u32 {
        _ = width;
        const index = (address -% win_base) / channel_stride;
        if (index >= channel_count) return 0;
        const channel = &self.channels[index];
        return switch ((address -% win_base) % channel_stride) {
            off.dmsar => channel.dmsar,
            off.dmdar => channel.dmdar,
            off.dmcra => channel.dmcra,
            off.dmcrb => channel.dmcrb,
            off.dmtmd => channel.dmtmd,
            off.dmamd => channel.dmamd,
            off.dmofr => channel.dmofr,
            off.dmint => channel.dmint,
            off.dmcnt => channel.dmcnt,
            off.dmsts => channel.dmsts,
            else => 0,
        };
    }

    pub fn write(self: *Dmac, address: u32, width: u3, value: u32) void {
        _ = width;
        const index = (address -% win_base) / channel_stride;
        if (index >= channel_count) return;
        const offset = (address -% win_base) % channel_stride;
        if (offset == off.dmreq) {
            if (value & field.swreq == 0) return;
            return self.request(index, value & field.clrs != 0);
        }
        self.store(index, offset, value);
    }

    /// A plain register store. DMCNT.DTE going up latches the counts, and
    /// DMSTS's status bits are write-0-to-clear.
    fn store(self: *Dmac, index: usize, offset: u32, value: u32) void {
        const channel = &self.channels[index];
        switch (offset) {
            off.dmsar => channel.dmsar = value,
            off.dmdar => channel.dmdar = value,
            off.dmcra => channel.dmcra = value,
            off.dmcrb => channel.dmcrb = value,
            off.dmtmd => channel.dmtmd = @truncate(value),
            off.dmamd => channel.dmamd = @truncate(value),
            off.dmofr => channel.dmofr = value,
            off.dmint => channel.dmint = @truncate(value),
            off.dmsts => channel.dmsts &= @truncate(value),
            off.dmcnt => {
                const raising = value & field.dte != 0 and !channel.armed();
                channel.dmcnt = @truncate(value);
                if (raising) channel.arm();
            },
            else => {},
        }
    }

    pub fn block(self: *Dmac) periph.Block {
        return .{
            .name = "DMAC channels",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Dmac = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Dmac = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The base address of one channel's registers.
pub fn channelAddress(index: usize) u32 {
    return win_base + channel_stride * @as(u32, @intCast(index));
}

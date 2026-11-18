//! Vendor-neutral external interrupt source contract between peripheral blocks
//! and a core's NVIC pending registers.
//!
//! Decouples core interrupt delivery from any specific routing table (such as
//! `IELSR0..95`): an implementation maps its own peripheral event or fixed line
//! numbers onto external interrupt lines `0..irq_lines - 1`, drives NVIC_ISPR
//! through `Sink`, re-pends level-asserted lines at chunk boundaries, and drops
//! latched status on reset.
const memmap = @import("../core/memmap.zig");
const scs_mod = @import("../core/machine/scs.zig");

pub const SinkError = error{Unmapped};

/// Type-erased word reader/writer over a guest core's NVIC pending registers.
pub const Sink = struct {
    ctx: *anyopaque,
    readWordFn: *const fn (ctx: *anyopaque, address: u32) SinkError!u32,
    writeWordFn: *const fn (ctx: *anyopaque, address: u32, value: u32) SinkError!void,

    pub fn of(core_ptr: anytype) Sink {
        const Ptr = @TypeOf(core_ptr);
        const Adapter = struct {
            fn read(ctx: *anyopaque, address: u32) SinkError!u32 {
                const target: Ptr = @ptrCast(@alignCast(ctx));
                return target.readWord(address) catch return SinkError.Unmapped;
            }

            fn write(ctx: *anyopaque, address: u32, value: u32) SinkError!void {
                const target: Ptr = @ptrCast(@alignCast(ctx));
                target.writeWord(address, value) catch return SinkError.Unmapped;
            }
        };
        return .{
            .ctx = @ptrCast(@constCast(core_ptr)),
            .readWordFn = Adapter.read,
            .writeWordFn = Adapter.write,
        };
    }

    pub fn isPending(self: Sink, line: u16, irq_lines: u16) SinkError!bool {
        if (line >= @min(irq_lines, scs_mod.max_irq_lines)) return false;
        const word = try self.readWordFn(self.ctx, pendingWord(line));
        return word & pendingBit(line) != 0;
    }

    pub fn pend(self: Sink, line: u16, irq_lines: u16) SinkError!bool {
        if (line >= @min(irq_lines, scs_mod.max_irq_lines)) return false;
        const address = pendingWord(line);
        const current = try self.readWordFn(self.ctx, address);
        try self.writeWordFn(self.ctx, address, current | pendingBit(line));
        return true;
    }

    pub fn clearPending(self: Sink, line: u16, irq_lines: u16) SinkError!void {
        if (line >= @min(irq_lines, scs_mod.max_irq_lines)) return;
        const address = pendingWord(line);
        const current = try self.readWordFn(self.ctx, address);
        try self.writeWordFn(self.ctx, address, current & ~pendingBit(line));
    }
};

pub fn pendingWord(line: u16) u32 {
    return memmap.nvic.ispr + 4 * (@as(u32, line) / 32);
}

pub fn pendingBit(line: u16) u32 {
    return @as(u32, 1) << @intCast(line % 32);
}

/// Pluggable external interrupt controller / router interface.
pub const IrqSource = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        raise: *const fn (ctx: *anyopaque, sink: Sink, irq_lines: u16, source_id: u16) SinkError!void,
        repend: *const fn (ctx: *anyopaque, sink: Sink, irq_lines: u16) SinkError!void,
        asserted: *const fn (ctx: *anyopaque, line: u16) bool,
        acknowledge: *const fn (ctx: *anyopaque, line: u16) void,
        clearLatches: *const fn (ctx: *anyopaque) void,
    };

    pub fn raise(self: IrqSource, core_ptr: anytype, irq_lines: u16, source_id: u16) SinkError!void {
        return self.vtable.raise(self.ctx, Sink.of(core_ptr), irq_lines, source_id);
    }

    pub fn repend(self: IrqSource, core_ptr: anytype, irq_lines: u16) SinkError!void {
        return self.vtable.repend(self.ctx, Sink.of(core_ptr), irq_lines);
    }

    pub fn asserted(self: IrqSource, line: u16) bool {
        return self.vtable.asserted(self.ctx, line);
    }

    pub fn acknowledge(self: IrqSource, line: u16) void {
        self.vtable.acknowledge(self.ctx, line);
    }

    pub fn clearLatches(self: IrqSource) void {
        self.vtable.clearLatches(self.ctx);
    }
};

/// Direct external interrupt line bank (0..479) for machines with fixed vector
/// wiring or level/pulse peripheral interrupt lines rather than an event-link table.
pub const DirectLines = struct {
    /// Bitmap of lines whose peripheral output is level-asserted until acknowledged.
    level_mask: [scs_mod.max_irq_words]u32 = @splat(0),
    /// Currently asserted level lines.
    latched: [scs_mod.max_irq_words]u32 = @splat(0),
    raised: u64 = 0,
    dropped: u64 = 0,
    pends: u64 = 0,
    repends: u64 = 0,

    pub fn setLevelTriggered(self: *DirectLines, line: u16, level: bool) void {
        if (line >= scs_mod.max_irq_lines) return;
        const word = line / 32;
        const bit = pendingBit(line);
        if (level) self.level_mask[word] |= bit else self.level_mask[word] &= ~bit;
    }

    pub fn irqSource(self: *DirectLines) IrqSource {
        return .{
            .ctx = self,
            .vtable = &.{
                .raise = raiseThunk,
                .repend = rependThunk,
                .asserted = assertedThunk,
                .acknowledge = acknowledgeThunk,
                .clearLatches = clearLatchesThunk,
            },
        };
    }

    fn raiseThunk(ctx: *anyopaque, sink: Sink, irq_lines: u16, line: u16) SinkError!void {
        const self: *DirectLines = @ptrCast(@alignCast(ctx));
        const limit = @min(irq_lines, scs_mod.max_irq_lines);
        if (line >= limit) {
            self.dropped += 1;
            return;
        }
        self.raised += 1;
        const word = line / 32;
        const bit = pendingBit(line);
        if (self.level_mask[word] & bit != 0) {
            if (self.latched[word] & bit != 0) return;
            self.latched[word] |= bit;
        }
        if (try sink.pend(line, limit)) self.pends += 1;
    }

    fn rependThunk(ctx: *anyopaque, sink: Sink, irq_lines: u16) SinkError!void {
        const self: *DirectLines = @ptrCast(@alignCast(ctx));
        const words = scs_mod.irqWordsOf(irq_lines);
        var word: u16 = 0;
        while (word < words) : (word += 1) {
            const active = self.latched[word] & scs_mod.wordIrqMaskOf(irq_lines, word);
            if (active != 0) try self.rependWord(sink, word, active, irq_lines);
        }
    }

    fn rependWord(self: *DirectLines, sink: Sink, word: u16, active: u32, irq_lines: u16) SinkError!void {
        var remaining = active;
        while (remaining != 0) {
            const bit: u5 = @intCast(@ctz(remaining));
            remaining &= remaining - 1;
            const line = word * 32 + bit;
            if (!(try sink.isPending(line, irq_lines))) {
                if (try sink.pend(line, irq_lines)) self.repends += 1;
            }
        }
    }

    fn assertedThunk(ctx: *anyopaque, line: u16) bool {
        const self: *const DirectLines = @ptrCast(@alignCast(ctx));
        if (line >= scs_mod.max_irq_lines) return false;
        return self.latched[line / 32] & pendingBit(line) != 0;
    }

    fn acknowledgeThunk(ctx: *anyopaque, line: u16) void {
        const self: *DirectLines = @ptrCast(@alignCast(ctx));
        if (line >= scs_mod.max_irq_lines) return;
        self.latched[line / 32] &= ~pendingBit(line);
    }

    fn clearLatchesThunk(ctx: *anyopaque) void {
        const self: *DirectLines = @ptrCast(@alignCast(ctx));
        self.latched = @splat(0);
    }
};

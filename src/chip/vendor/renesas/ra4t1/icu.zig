//! RA4T1 Interrupt Controller Unit (`ICU = 0x4000_6000`, `IELSR0..95 = 0x4000_6300 + 4*n`)
//! (R01UH0999EJ0140 Rev.1.40 Ch. 12, pp. 222–255; RA8EMU-A-71).
//!
//! Connects 96 programmable event links (`IELSR0..95`) to NVIC external lines
//! `0..95` (while `IRQ96`/`IRQ97` are `CTIIRQ[0]`/`[1]`) via the chip's `IrqSource`
//! contract (`irq_source.zig`). Distinct from RA8, where `IELSR` sits at `0x4000_C300`.
const chip = @import("../../../root.zig");

const irq_source = chip.periph.irq_source;
const registry = chip.periph.registry;

pub const win_base: u32 = 0x4000_6000;
pub const win_size: u32 = 0x500;
pub const ielsr_count: usize = 96;
pub const irqcr_count: usize = 15;
pub const delsr_count: usize = 8;

pub const ofs = struct {
    pub const irqcr: u32 = 0x000;
    pub const nmicr: u32 = 0x100;
    pub const nmier: u32 = 0x120;
    pub const nmiclr: u32 = 0x130;
    pub const nmisr: u32 = 0x140;
    pub const wupen0: u32 = 0x1A0;
    pub const wupen1: u32 = 0x1A4;
    pub const selsr0: u32 = 0x200;
    pub const delsr: u32 = 0x280;
    pub const ielsr: u32 = 0x300;
};

pub const ielsr_field = struct {
    pub const iels_mask: u32 = 0x0000_01FF;
    pub const ir: u32 = 1 << 16;
    pub const dtce: u32 = 1 << 24;
    pub const writemask: u32 = iels_mask | dtce;
};

pub const Icu = struct {
    irqcr: [irqcr_count]u8 = @splat(0),
    nmicr: u8 = 0,
    nmier: u16 = 0,
    nmisr: u16 = 0,
    wupen0: u32 = 0,
    wupen1: u32 = 0,
    selsr0: u16 = 0,
    delsr: [delsr_count]u32 = @splat(0),
    ielsr: [ielsr_count]u32 = @splat(0),
    raised: u64 = 0,
    pends: u64 = 0,
    repends: u64 = 0,

    pub fn init() Icu {
        return .{};
    }

    pub fn block(self: *Icu) registry.Block {
        return .{
            .name = "RA4T1 ICU",
            .base = win_base,
            .size = win_size,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
            .peekFn = readThunk,
        };
    }

    pub fn irqSource(self: *Icu) irq_source.IrqSource {
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

    fn raiseThunk(
        ctx: *anyopaque,
        sink: irq_source.Sink,
        irq_lines: u16,
        event_no: u16,
    ) irq_source.SinkError!void {
        const self: *Icu = @ptrCast(@alignCast(ctx));
        self.raised +%= 1;
        if (event_no == 0 or event_no > ielsr_field.iels_mask) return;
        const cap = @min(irq_lines, @as(u16, ielsr_count));
        for (self.ielsr[0..cap], 0..) |*slot, line| {
            if ((slot.* & ielsr_field.iels_mask) != event_no) continue;
            slot.* |= ielsr_field.ir;
            if (try sink.pend(@intCast(line), irq_lines)) self.pends +%= 1;
        }
    }

    fn rependThunk(ctx: *anyopaque, sink: irq_source.Sink, irq_lines: u16) irq_source.SinkError!void {
        const self: *Icu = @ptrCast(@alignCast(ctx));
        const cap = @min(irq_lines, @as(u16, ielsr_count));
        for (self.ielsr[0..cap], 0..) |slot, line| {
            if ((slot & ielsr_field.ir) == 0) continue;
            const irq: u16 = @intCast(line);
            if (!(try sink.isPending(irq, irq_lines))) {
                if (try sink.pend(irq, irq_lines)) self.repends +%= 1;
            }
        }
    }

    fn assertedThunk(ctx: *anyopaque, line: u16) bool {
        const self: *const Icu = @ptrCast(@alignCast(ctx));
        if (line >= ielsr_count) return false;
        return (self.ielsr[line] & ielsr_field.ir) != 0;
    }

    fn acknowledgeThunk(_: *anyopaque, _: u16) void {}

    fn clearLatchesThunk(ctx: *anyopaque) void {
        const self: *Icu = @ptrCast(@alignCast(ctx));
        for (&self.ielsr) |*slot| {
            slot.* &= ~ielsr_field.ir;
        }
        self.nmisr = 0;
    }

    fn readThunk(ctx: *anyopaque, address: u32, width: u3) u32 {
        const self: *const Icu = @ptrCast(@alignCast(ctx));
        return self.read(address, width);
    }

    fn writeThunk(ctx: *anyopaque, address: u32, width: u3, value: u32) void {
        const self: *Icu = @ptrCast(@alignCast(ctx));
        self.write(address, width, value);
    }

    pub fn read(self: *const Icu, address: u32, width: u3) u32 {
        if (address < win_base or address - win_base >= win_size) return 0;
        const off = address - win_base;
        if (off >= ofs.ielsr and off < ofs.ielsr + ielsr_count * 4) {
            const idx = (off - ofs.ielsr) / 4;
            const shift: u5 = @intCast((off & 3) * 8);
            return maskWidth(self.ielsr[idx] >> shift, width);
        }
        if (off >= ofs.delsr and off < ofs.delsr + delsr_count * 4) {
            const idx = (off - ofs.delsr) / 4;
            const shift: u5 = @intCast((off & 3) * 8);
            return maskWidth(self.delsr[idx] >> shift, width);
        }
        if (off < irqcr_count) return self.irqcr[off];
        return self.readSideReg(off, width);
    }

    fn readSideReg(self: *const Icu, off: u32, width: u3) u32 {
        const val: u32 = switch (off) {
            ofs.nmicr => self.nmicr,
            ofs.nmier => self.nmier,
            ofs.nmiclr => 0,
            ofs.nmisr => self.nmisr,
            ofs.wupen0 => self.wupen0,
            ofs.wupen1 => self.wupen1,
            ofs.selsr0 => self.selsr0,
            else => 0,
        };
        return maskWidth(val, width);
    }

    pub fn write(self: *Icu, address: u32, width: u3, value: u32) void {
        if (address < win_base or address - win_base >= win_size) return;
        const off = address - win_base;
        if (off >= ofs.ielsr and off < ofs.ielsr + ielsr_count * 4) {
            const idx = (off - ofs.ielsr) / 4;
            const merged = widenWrite(self.ielsr[idx], off & 3, width, value);
            const ir = (self.ielsr[idx] & merged) & ielsr_field.ir;
            self.ielsr[idx] = (merged & ielsr_field.writemask) | ir;
            return;
        }
        if (off >= ofs.delsr and off < ofs.delsr + delsr_count * 4) {
            const idx = (off - ofs.delsr) / 4;
            const merged = widenWrite(self.delsr[idx], off & 3, width, value);
            self.delsr[idx] = merged & ielsr_field.iels_mask;
            return;
        }
        if (off < irqcr_count) {
            self.irqcr[off] = @truncate(value);
            return;
        }
        self.writeSideReg(off, value);
    }

    fn writeSideReg(self: *Icu, off: u32, value: u32) void {
        switch (off) {
            ofs.nmicr => self.nmicr = @truncate(value),
            // HUM §12.2.3 Note 2: NMIER bits are write-once to 1 until reset.
            ofs.nmier => self.nmier |= @as(u16, @truncate(value)),
            ofs.nmiclr => self.nmisr &= ~@as(u16, @truncate(value)),
            ofs.wupen0 => self.wupen0 = value,
            ofs.wupen1 => self.wupen1 = value,
            ofs.selsr0 => self.selsr0 = @truncate(value & 0x01FF),
            else => {},
        }
    }
};

fn maskWidth(value: u32, width: u3) u32 {
    return switch (width) {
        1 => value & 0xFF,
        2 => value & 0xFFFF,
        else => value,
    };
}

fn widenWrite(current: u32, byte_off: u32, width: u3, value: u32) u32 {
    const shift: u5 = @intCast(byte_off * 8);
    const width_mask: u32 = switch (width) {
        1 => 0xFF,
        2 => 0xFFFF,
        else => return value,
    };
    const shifted = width_mask << shift;
    return (current & ~shifted) | ((value & width_mask) << shift);
}

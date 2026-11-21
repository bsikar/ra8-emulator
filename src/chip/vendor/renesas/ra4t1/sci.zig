//! Classic Renesas RA4T1 `SCI0` (`0x4011_8000`) and `SCI9` (`0x4011_8900`)
//! serial controllers (R01UH0999EJ0140 Rev.1.40 Ch. 24, pp. 650–785; RA8EMU-A-71).
//!
//! Models classic 8/16-bit register layout (`SMR`, `BRR`, `SCR`, `TDR`, `SSR`,
//! `RDR`, `SCMR`, `SEMR`, `SIMR1..3`, `SPMR`, `TDRHL`/`RDRHL`, `MDDR`, `FCR`,
//! `FDR`, `LSR`, `SPTR`) with `SCI9` forwarded to the shared board serial console.
const chip = @import("../../../root.zig");

const registry = chip.periph.registry;

pub const win_size: u32 = 0x100;
pub const base0: u32 = 0x4011_8000;
pub const base9: u32 = 0x4011_8900;

pub const ofs = struct {
    pub const smr: u32 = 0x00;
    pub const brr: u32 = 0x01;
    pub const scr: u32 = 0x02;
    pub const tdr: u32 = 0x03;
    pub const ssr: u32 = 0x04;
    pub const rdr: u32 = 0x05;
    pub const scmr: u32 = 0x06;
    pub const semr: u32 = 0x07;
    pub const snfr: u32 = 0x08;
    pub const simr1: u32 = 0x09;
    pub const simr2: u32 = 0x0A;
    pub const simr3: u32 = 0x0B;
    pub const sisr: u32 = 0x0C;
    pub const spmr: u32 = 0x0D;
    pub const tdrhl: u32 = 0x0E;
    pub const rdrhl: u32 = 0x10;
    pub const mddr: u32 = 0x12;
    pub const fcr: u32 = 0x14;
    pub const fdr: u32 = 0x16;
    pub const lsr: u32 = 0x18;
    pub const cdr: u32 = 0x1A;
    pub const dccr: u32 = 0x1C;
    pub const actr: u32 = 0x1D;
    pub const sptr: u32 = 0x20;
};

pub const ssr_bit = struct {
    pub const tend: u8 = 1 << 2;
    pub const per: u8 = 1 << 3;
    pub const fer: u8 = 1 << 4;
    pub const orer: u8 = 1 << 5;
    pub const rdrf: u8 = 1 << 6;
    pub const tdre: u8 = 1 << 7;
    pub const fifo_tend: u8 = 1 << 3;
};

pub const scr_bit = struct {
    pub const teie: u8 = 1 << 2;
    pub const re: u8 = 1 << 4;
    pub const te: u8 = 1 << 5;
    pub const rie: u8 = 1 << 6;
    pub const tie: u8 = 1 << 7;
};

pub const events = struct {
    pub const sci0_rxi: u16 = 0x180;
    pub const sci0_txi: u16 = 0x181;
    pub const sci0_tei: u16 = 0x182;
    pub const sci9_rxi: u16 = 0x1B6;
    pub const sci9_txi: u16 = 0x1B7;
    pub const sci9_tei: u16 = 0x1B8;
};

pub const TxSink = struct {
    context: *anyopaque,
    onByteFn: *const fn (context: *anyopaque, sci_index: u4, byte: u8) void,
};

pub const IrqSink = struct {
    context: *anyopaque,
    raiseFn: *const fn (context: *anyopaque, event_no: u16) void,
};

pub const Channel = struct {
    smr: u8 = 0x00,
    brr: u8 = 0xFF,
    scr: u8 = 0x00,
    tdr: u8 = 0xFF,
    ssr: u8 = ssr_bit.tdre | ssr_bit.tend,
    rdr: u8 = 0x00,
    scmr: u8 = 0xF2,
    semr: u8 = 0x00,
    snfr: u8 = 0x00,
    simr1: u8 = 0x00,
    simr2: u8 = 0x00,
    simr3: u8 = 0x00,
    sisr: u8 = 0x00,
    spmr: u8 = 0x00,
    mddr: u8 = 0xFF,
    fcr: u16 = 0xF800,
    fdr: u16 = 0x0000,
    lsr: u16 = 0x0000,
    cdr: u16 = 0x0000,
    dccr: u8 = 0x00,
    actr: u8 = 0x00,
    sptr: u8 = 0x03,
    tx_count: u64 = 0,
    rx_count: u64 = 0,
    last_tx: u8 = 0,

    pub fn fifoEnabled(self: *const Channel) bool {
        return (self.fcr & 0x0001) != 0;
    }

    pub fn receiveByte(self: *Channel, byte: u8) bool {
        if ((self.scr & scr_bit.re) == 0) return false;
        if ((self.ssr & ssr_bit.rdrf) != 0) self.ssr |= ssr_bit.orer;
        self.rdr = byte;
        self.ssr |= ssr_bit.rdrf;
        self.rx_count +%= 1;
        return true;
    }
};

pub const Sci = struct {
    channels: [2]Channel = .{ .{}, .{} }, // [0] = SCI0, [1] = SCI9
    tx_sink: ?TxSink = null,
    irq_sink: ?IrqSink = null,

    pub fn init() Sci {
        return .{};
    }

    pub fn block0(self: *Sci) registry.Block {
        return .{
            .name = "RA4T1 SCI0",
            .base = base0,
            .size = win_size,
            .context = self,
            .readFn = read0Thunk,
            .writeFn = write0Thunk,
            .peekFn = read0Thunk,
        };
    }

    pub fn block9(self: *Sci) registry.Block {
        return .{
            .name = "RA4T1 SCI9",
            .base = base9,
            .size = win_size,
            .context = self,
            .readFn = read9Thunk,
            .writeFn = write9Thunk,
            .peekFn = read9Thunk,
        };
    }

    pub fn channelNumber(slot: usize) u4 {
        return if (slot == 0) 0 else 9;
    }

    pub fn pushRx(self: *Sci, slot: u1, byte: u8) bool {
        const ch = &self.channels[slot];
        if (!ch.receiveByte(byte)) return false;
        if ((ch.scr & scr_bit.rie) != 0) {
            self.raiseEvent(if (slot == 0) events.sci0_rxi else events.sci9_rxi);
        }
        return true;
    }

    fn read0Thunk(ctx: *anyopaque, address: u32, width: u3) u32 {
        const self: *const Sci = @ptrCast(@alignCast(ctx));
        return self.read(0, address - base0, width);
    }

    fn write0Thunk(ctx: *anyopaque, address: u32, width: u3, value: u32) void {
        const self: *Sci = @ptrCast(@alignCast(ctx));
        self.write(0, address - base0, width, value);
    }

    fn read9Thunk(ctx: *anyopaque, address: u32, width: u3) u32 {
        const self: *const Sci = @ptrCast(@alignCast(ctx));
        return self.read(1, address - base9, width);
    }

    fn write9Thunk(ctx: *anyopaque, address: u32, width: u3, value: u32) void {
        const self: *Sci = @ptrCast(@alignCast(ctx));
        self.write(1, address - base9, width, value);
    }

    pub fn read(self: *const Sci, slot: u1, offset: u32, width: u3) u32 {
        if (offset >= win_size) return 0;
        const ch = &self.channels[slot];
        if (width == 2) {
            const lo = self.readByte(ch, offset);
            const hi = self.readByte(ch, offset + 1);
            return @as(u32, lo) | (@as(u32, hi) << 8);
        }
        if (width == 4) {
            var out: u32 = 0;
            for (0..4) |i| {
                out |= @as(u32, self.readByte(ch, offset + @as(u32, @intCast(i)))) << @intCast(i * 8);
            }
            return out;
        }
        return self.readByte(ch, offset);
    }

    fn readByte(self: *const Sci, ch: *const Channel, offset: u32) u8 {
        _ = self;
        return switch (offset) {
            ofs.smr => ch.smr,
            ofs.brr => ch.brr,
            ofs.scr => ch.scr,
            ofs.tdr => ch.tdr,
            ofs.ssr => if (ch.fifoEnabled()) (ch.ssr & 0x70) | ssr_bit.tdre | ssr_bit.fifo_tend else ch.ssr,
            ofs.rdr => ch.rdr,
            ofs.scmr => ch.scmr,
            ofs.semr => ch.semr,
            ofs.snfr => ch.snfr,
            ofs.simr1 => ch.simr1,
            ofs.simr2 => ch.simr2,
            ofs.simr3 => ch.simr3,
            ofs.sisr => ch.sisr,
            ofs.spmr => ch.spmr,
            ofs.tdrhl => ch.tdr,
            ofs.tdrhl + 1 => 0xFF,
            ofs.rdrhl => ch.rdr,
            ofs.rdrhl + 1 => 0,
            ofs.mddr => ch.mddr,
            ofs.fcr => @truncate(ch.fcr),
            ofs.fcr + 1 => @truncate(ch.fcr >> 8),
            ofs.fdr => @truncate(ch.fdr),
            ofs.fdr + 1 => @truncate(ch.fdr >> 8),
            ofs.lsr => @truncate(ch.lsr),
            ofs.lsr + 1 => @truncate(ch.lsr >> 8),
            ofs.cdr => @truncate(ch.cdr),
            ofs.cdr + 1 => @truncate(ch.cdr >> 8),
            ofs.dccr => ch.dccr,
            ofs.actr => ch.actr,
            ofs.sptr => ch.sptr,
            else => 0,
        };
    }

    pub fn write(self: *Sci, slot: u1, offset: u32, width: u3, value: u32) void {
        if (offset >= win_size) return;
        const ch = &self.channels[slot];
        if (width == 2 and offset == ofs.fcr) {
            ch.fcr = @truncate(value);
            if ((ch.fcr & 0x0004) != 0) ch.fcr &= ~@as(u16, 0x0004);
            return;
        }
        if (width == 2 and offset == ofs.tdrhl) {
            self.transmitByte(slot, @truncate(value));
            return;
        }
        const count: usize = switch (width) {
            1 => 1,
            2 => 2,
            else => 4,
        };
        for (0..count) |i| {
            self.writeByte(slot, offset + @as(u32, @intCast(i)), @truncate(value >> @intCast(i * 8)));
        }
    }

    fn writeByte(self: *Sci, slot: u1, offset: u32, byte: u8) void {
        const ch = &self.channels[slot];
        switch (offset) {
            ofs.smr => ch.smr = byte,
            ofs.brr => if ((ch.scr & (scr_bit.te | scr_bit.re)) == 0) {
                ch.brr = byte;
            },
            ofs.scr => self.writeScr(slot, byte),
            ofs.tdr, ofs.tdrhl => self.transmitByte(slot, byte),
            ofs.ssr => ch.ssr = (ch.ssr & (byte | 0x84)) & 0xFF,
            ofs.scmr => ch.scmr = byte | 0x62,
            ofs.semr => ch.semr = byte,
            ofs.snfr => ch.snfr = byte,
            ofs.simr1 => ch.simr1 = byte,
            ofs.simr2 => ch.simr2 = byte,
            ofs.simr3 => ch.simr3 = byte,
            ofs.spmr => ch.spmr = byte,
            ofs.mddr => if ((ch.scr & (scr_bit.te | scr_bit.re)) == 0) {
                ch.mddr = byte;
            },
            ofs.fcr => ch.fcr = (ch.fcr & 0xFF00) | byte,
            ofs.fcr + 1 => ch.fcr = (ch.fcr & 0x00FF) | (@as(u16, byte) << 8),
            ofs.dccr => ch.dccr = byte,
            ofs.actr => ch.actr = byte,
            ofs.sptr => ch.sptr = byte,
            else => {},
        }
    }

    fn writeScr(self: *Sci, slot: u1, byte: u8) void {
        const ch = &self.channels[slot];
        const prev = ch.scr;
        ch.scr = byte;
        if ((byte & scr_bit.te) != 0) {
            ch.ssr |= ssr_bit.tdre | ssr_bit.tend;
            if ((prev & scr_bit.te) == 0 and (byte & scr_bit.tie) != 0) {
                self.raiseEvent(if (slot == 0) events.sci0_txi else events.sci9_txi);
            }
        }
    }

    fn transmitByte(self: *Sci, slot: u1, byte: u8) void {
        const ch = &self.channels[slot];
        ch.tdr = byte;
        if ((ch.scr & scr_bit.te) == 0) return;
        ch.last_tx = byte;
        ch.tx_count +%= 1;
        ch.ssr |= ssr_bit.tdre | ssr_bit.tend;
        if (self.tx_sink) |sink| sink.onByteFn(sink.context, channelNumber(slot), byte);
        if ((ch.scr & scr_bit.tie) != 0) {
            self.raiseEvent(if (slot == 0) events.sci0_txi else events.sci9_txi);
        }
        if ((ch.scr & scr_bit.teie) != 0) {
            self.raiseEvent(if (slot == 0) events.sci0_tei else events.sci9_tei);
        }
    }

    fn raiseEvent(self: *const Sci, event_no: u16) void {
        if (self.irq_sink) |sink| sink.raiseFn(sink.context, event_no);
    }
};

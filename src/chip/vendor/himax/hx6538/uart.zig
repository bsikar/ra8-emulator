//! DesignWare APB UART (`UART0..2`) for the Himax HX6538 (`WE2_device_addr.h`).
//!
//! Base addresses (Secure / Non-secure bit-28):
//!   UART0: 0x5400_3000 / 0x4400_3000 (IRQ 90) - console UART on Grove Vision AI V2
//!   UART1: 0x5200_0000 / 0x4200_0000 (IRQ 91)
//!   UART2: 0x5400_4000 / 0x4400_4000 (IRQ 95)
const registry = @import("../../../periph/registry.zig");
const sci_line = @import("../../../periph/sci/line.zig");

pub const channel_count: usize = 3;
pub const window_size: u32 = 0x1000;
pub const rx_capacity: usize = 64;

pub const bases = [channel_count]u32{ 0x5400_3000, 0x5200_0000, 0x5400_4000 };
pub const irqs = [channel_count]u16{ 90, 91, 95 };

pub const regs = struct {
    pub const rbr_thr_dll: u32 = 0x00;
    pub const ier_dlh: u32 = 0x04;
    pub const iir_fcr: u32 = 0x08;
    pub const lcr: u32 = 0x0C;
    pub const mcr: u32 = 0x10;
    pub const lsr: u32 = 0x14;
    pub const msr: u32 = 0x18;
    pub const scr: u32 = 0x1C;
    pub const usr: u32 = 0x7C;
    pub const srr: u32 = 0x88;
    pub const dlf: u32 = 0xC0;
    pub const cpr: u32 = 0xF4;
    pub const ucv: u32 = 0xFC;
};

pub const bits = struct {
    pub const lcr_dlab: u32 = 0x80;
    pub const mcr_loop: u32 = 0x10;
    pub const ier_erbfi: u32 = 0x01;
    pub const ier_etbei: u32 = 0x02;
    pub const lsr_dr: u32 = 0x01;
    pub const lsr_tx_empty: u32 = 0x60; // THRE | TEMT
    pub const usr_tfnf: u32 = 0x02;
    pub const usr_tfe: u32 = 0x04;
    pub const usr_rfne: u32 = 0x08;
    pub const cpr_reset: u32 = 0x0001_0422;
    pub const ucv_reset: u32 = 0x3430_332A;
};

pub const Uart = struct {
    dll: u8 = 0,
    dlh: u8 = 0,
    dlf: u8 = 0,
    ier: u32 = 0,
    fcr: u32 = 0,
    lcr: u32 = 0,
    mcr: u32 = 0,
    scr: u32 = 0,
    tx_count: u64 = 0,
    tx_irq_latched: bool = false,
    rx_buf: [rx_capacity]u8 = @splat(0),
    rx_head: usize = 0,
    rx_len: usize = 0,
    console: ?*sci_line.Line = null,

    pub fn block(self: *Uart, index: usize) registry.Block {
        return .{
            .name = "hx_uart",
            .base = bases[index],
            .size = window_size,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
            .peekFn = peekThunk,
        };
    }

    pub fn pushRx(self: *Uart, byte: u8) void {
        if (self.rx_len >= rx_capacity) return;
        const tail = (self.rx_head + self.rx_len) % rx_capacity;
        self.rx_buf[tail] = byte;
        self.rx_len += 1;
    }

    pub fn read(self: *Uart, offset: u32) u32 {
        return switch (offset) {
            regs.rbr_thr_dll => self.readRbrOrDll(),
            regs.ier_dlh => if (self.dlab()) self.dlh else self.ier,
            regs.iir_fcr => self.readIir(),
            else => self.peek(offset),
        };
    }

    pub fn peek(self: *const Uart, offset: u32) u32 {
        return switch (offset) {
            regs.rbr_thr_dll => if (self.dlab()) self.dll else if (self.rx_len != 0) self.rx_buf[self.rx_head] else 0,
            regs.ier_dlh => if (self.dlab()) self.dlh else self.ier,
            regs.iir_fcr => self.peekIir(),
            regs.lcr => self.lcr,
            regs.mcr => self.mcr,
            regs.lsr => bits.lsr_tx_empty | @as(u32, @intFromBool(self.rx_len != 0)),
            regs.msr => 0xB0,
            regs.scr => self.scr,
            regs.usr => bits.usr_tfnf | bits.usr_tfe | (if (self.rx_len != 0) bits.usr_rfne else 0),
            regs.dlf => self.dlf,
            regs.cpr => bits.cpr_reset,
            regs.ucv => bits.ucv_reset,
            else => 0,
        };
    }

    pub fn write(self: *Uart, offset: u32, value: u32) void {
        switch (offset) {
            regs.rbr_thr_dll => self.writeThrOrDll(value),
            regs.ier_dlh => self.writeIerOrDlh(value),
            regs.iir_fcr => self.writeFcr(value),
            regs.lcr => self.lcr = value & 0xFF,
            regs.mcr => self.mcr = value & 0xFF,
            regs.scr => self.scr = value & 0xFF,
            regs.srr => if (value & 1 != 0) self.softReset(value),
            regs.dlf => self.dlf = @truncate(value),
            else => {},
        }
    }

    pub fn irqAsserted(self: *const Uart) bool {
        const rx_hit = (self.ier & bits.ier_erbfi != 0) and self.rx_len != 0;
        const tx_hit = (self.ier & bits.ier_etbei != 0) and self.tx_irq_latched;
        return rx_hit or tx_hit;
    }

    fn dlab(self: *const Uart) bool {
        return (self.lcr & bits.lcr_dlab) != 0;
    }

    fn readRbrOrDll(self: *Uart) u32 {
        if (self.dlab()) return self.dll;
        if (self.rx_len == 0) return 0;
        const byte = self.rx_buf[self.rx_head];
        self.rx_head = (self.rx_head + 1) % rx_capacity;
        self.rx_len -= 1;
        return byte;
    }

    fn writeThrOrDll(self: *Uart, value: u32) void {
        if (self.dlab()) {
            self.dll = @truncate(value);
            return;
        }
        const ch: u8 = @truncate(value);
        self.tx_count += 1;
        self.tx_irq_latched = true;
        if (self.mcr & bits.mcr_loop != 0) {
            self.pushRx(ch);
            return;
        }
        if (self.console) |line| line.feed(ch);
    }

    fn writeIerOrDlh(self: *Uart, value: u32) void {
        if (self.dlab()) {
            self.dlh = @truncate(value);
            return;
        }
        const prev = self.ier;
        self.ier = value & 0x0F;
        if (prev & bits.ier_etbei == 0 and self.ier & bits.ier_etbei != 0) self.tx_irq_latched = true;
        if (self.ier & bits.ier_etbei == 0) self.tx_irq_latched = false;
    }

    fn writeFcr(self: *Uart, value: u32) void {
        self.fcr = value & 0xFF;
        if (value & 0x02 != 0) {
            self.rx_head = 0;
            self.rx_len = 0;
        }
        if (value & 0x04 != 0) self.tx_irq_latched = (self.ier & bits.ier_etbei) != 0;
    }

    fn softReset(self: *Uart, value: u32) void {
        const line = self.console;
        const count = self.tx_count;
        self.* = .{ .console = line, .tx_count = count };
        if (value & 0x02 != 0) {
            self.rx_head = 0;
            self.rx_len = 0;
        }
    }

    fn readIir(self: *Uart) u32 {
        const out = self.peekIir();
        if (out & 0x0F == 0x02) self.tx_irq_latched = false;
        return out;
    }

    fn peekIir(self: *const Uart) u32 {
        const fifo: u32 = if (self.fcr & 1 != 0) 0xC0 else 0;
        if ((self.ier & bits.ier_erbfi != 0) and self.rx_len != 0) return fifo | 0x04;
        if ((self.ier & bits.ier_etbei != 0) and self.tx_irq_latched) return fifo | 0x02;
        return fifo | 0x01;
    }
};

pub const Bank = struct {
    channels: [channel_count]Uart = @splat(.{}),
};

fn indexFor(address: u32) ?usize {
    for (bases, 0..) |base, idx| {
        if (address >= base and address < base + window_size) return idx;
    }
    return null;
}

fn readThunk(context: *anyopaque, address: u32, _: u3) u32 {
    const ch: *Uart = @ptrCast(@alignCast(context));
    const idx = indexFor(address) orelse return 0;
    return ch.read(address - bases[idx]);
}

fn peekThunk(context: *anyopaque, address: u32, _: u3) u32 {
    const ch: *const Uart = @ptrCast(@alignCast(context));
    const idx = indexFor(address) orelse return 0;
    return ch.peek(address - bases[idx]);
}

fn writeThunk(context: *anyopaque, address: u32, _: u3, value: u32) void {
    const ch: *Uart = @ptrCast(@alignCast(context));
    const idx = indexFor(address) orelse return;
    ch.write(address - bases[idx], value);
}

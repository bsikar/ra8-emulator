//! GPIO / PORT: the pins every app on this board touches first.
//!
//! The RA8D2 puts PORT0..PORT14 at 0x4040_0000 on a 0x20 stride, and the FSP
//! ioport driver reaches them through the combined PCNTR registers rather than
//! the byte-wide aliases (HUM Ch 20.2 p 730-736, ra8_port_regs.h):
//!
//!   PCNTR1 = {PODR[31:16], PDR[15:0]}  RW  direction and output latch
//!   PCNTR2 = {EIDR[31:16], PIDR[15:0]}  R  live pin level
//!   PCNTR3 = {PORR[31:16], POSR[15:0]}  W  atomic clear / atomic set
//!   PCNTR4 = {EORR[31:16], EOSR[15:0]} RW  event output, unmodelled
//!
//! Until now these addresses fell through to the sparse register file, and
//! that file cannot be honest about a pin: PCNTR2 is a different register from
//! PCNTR1, so a firmware that drove a pin high and read the level back got the
//! alternating zero/ones stand-in instead of its own output, and a blink loop
//! that waits for its own LED could not be believed either way. A port is a
//! latch and a direction mask, which is small enough to model exactly, so this
//! models it exactly.
//!
//! PIDR here is the C tree's rule, ported from board_periph_gpio.c on dev: an
//! output pin reads back the latch it drives, an input pin reads whatever is
//! externally driven onto it, and anything else reads zero. The three EK-RA8D2
//! user LEDs and the two user switches are the externally-driven pins that
//! exist, so they live here too: the LEDs as observability (level and edge
//! count, reported at the end of a run) and the switches seeded high, because
//! they are active-low with pull-ups and a released button must not read as
//! pressed.
const std = @import("std");
const periph = @import("periph.zig");

/// PORT geometry (HUM Ch 20.2 p 730). The Non-secure alias is folded onto this
/// base by the bus before anything here sees it.
pub const win_base: u32 = 0x4040_0000;
pub const port_stride: u32 = 0x20;
pub const port_count: u32 = 15;
pub const win_span: u32 = port_stride * port_count;

pub const pins_per_port: u32 = 16;

const pcntr1: u32 = 0x00;
const pcntr2: u32 = 0x04;
const pcntr3: u32 = 0x08;
const pcntr4: u32 = 0x0C;

const half_shift: u5 = 16;
const half_mask: u32 = 0xFFFF;

/// One PORT instance. Four 16-bit halves is the whole of it: what the firmware
/// drives, which way each pin faces, and which pins the board drives back.
const Port = struct {
    /// Direction, 1 = output.
    pdr: u16 = 0,
    /// Output-data latch.
    podr: u16 = 0,
    /// Pins whose input level comes from outside the firmware.
    in_ovr: u16 = 0,
    /// The level those pins are driven to.
    in_lvl: u16 = 0,

    /// What PIDR reads: driven outputs, plus externally-driven inputs.
    fn level(self: Port) u16 {
        const driven = self.podr & self.pdr;
        const inputs = ~self.pdr & self.in_ovr & self.in_lvl;
        return driven | inputs;
    }
};

/// A board LED: where it sits, and what colour it emits when driven high. The
/// colours are carried from the C tree so the board view can light them the
/// same way when the display slice lands.
const Led = struct {
    port: u8,
    pin: u4,
    rgb565: u16,
    name: []const u8,
};

pub const led_count: usize = 3;

pub const leds = [led_count]Led{
    .{ .port = 6, .pin = 0, .rgb565 = 0x001F, .name = "LED1 BLUE  P600" },
    .{ .port = 3, .pin = 3, .rgb565 = 0x07E0, .name = "LED2 GREEN P303" },
    .{ .port = 10, .pin = 7, .rgb565 = 0xF800, .name = "LED3 RED   PA07" },
};

/// The two user switches, both on PORT0 (UM Tbl 25): SW1 = P009, SW2 = P008.
pub const sw_port: u8 = 0;
pub const sw1_pin: u4 = 9;
pub const sw2_pin: u4 = 8;

pub const Gpio = struct {
    ports: [port_count]Port = [1]Port{.{}} ** port_count,
    /// Last level seen on each board LED, and how many times it changed.
    led_level: [led_count]u1 = .{0} ** led_count,
    led_edges: [led_count]u32 = .{0} ** led_count,

    pub fn init() Gpio {
        var self = Gpio{};
        self.reset();
        return self;
    }

    /// Reset is not just zeroing: the user switches are active-low with
    /// pull-ups, so a released button has to read high or a firmware poll sees
    /// a press that never happened.
    pub fn reset(self: *Gpio) void {
        self.ports = [1]Port{.{}} ** port_count;
        self.led_level = .{0} ** led_count;
        self.led_edges = .{0} ** led_count;
        self.setInput(sw_port, sw1_pin, true);
        self.setInput(sw_port, sw2_pin, true);
    }

    /// Drive a pin from outside the firmware: a button press, or a peripheral
    /// that answers on a GPIO line (the e-paper HRDY in the C tree).
    pub fn setInput(self: *Gpio, port: u8, pin: u4, high: bool) void {
        if (port >= port_count) return;
        const bit = @as(u16, 1) << pin;
        self.ports[port].in_ovr |= bit;
        if (high) {
            self.ports[port].in_lvl |= bit;
        } else {
            self.ports[port].in_lvl &= ~bit;
        }
    }

    pub fn getInput(self: *const Gpio, port: u8, pin: u4) bool {
        if (port >= port_count) return false;
        return (self.ports[port].in_lvl & (@as(u16, 1) << pin)) != 0;
    }

    /// The level a pin actually sits at, which is what PIDR answers.
    pub fn pinLevel(self: *const Gpio, port: u8, pin: u4) bool {
        if (port >= port_count) return false;
        return (self.ports[port].level() & (@as(u16, 1) << pin)) != 0;
    }

    pub fn ledLevel(self: *const Gpio, index: usize) u1 {
        if (index >= led_count) return 0;
        return self.led_level[index];
    }

    pub fn ledEdges(self: *const Gpio, index: usize) u32 {
        if (index >= led_count) return 0;
        return self.led_edges[index];
    }

    pub fn quiet(self: *const Gpio) bool {
        for (self.led_edges) |edges| {
            if (edges != 0) return false;
        }
        return true;
    }

    /// Apply a new output latch and count any board-LED edge it caused. Every
    /// write path goes through here so PCNTR1 and PCNTR3 are counted alike.
    fn setLatch(self: *Gpio, index: u32, next: u16) void {
        const port = &self.ports[index];
        const before = port.podr;
        if (before == next) return;
        port.podr = next;
        for (leds, 0..) |led, i| {
            if (led.port != index) continue;
            const bit = @as(u16, 1) << led.pin;
            const was: u1 = if ((before & bit) != 0) 1 else 0;
            const now: u1 = if ((next & bit) != 0) 1 else 0;
            if (was == now) continue;
            self.led_level[i] = now;
            self.led_edges[i] += 1;
        }
    }

    pub fn readReg(self: *const Gpio, address: u32, width: u3) u32 {
        _ = width;
        const offset = address -% win_base;
        const index = offset / port_stride;
        if (index >= port_count) return 0;
        const port = self.ports[index];
        return switch (offset % port_stride) {
            pcntr1 => (@as(u32, port.podr) << half_shift) | @as(u32, port.pdr),
            pcntr2 => @as(u32, port.level()),
            // PCNTR3 is write-only and PCNTR4's event output is unmodelled;
            // both read zero rather than borrowing the sparse file's toggle.
            else => 0,
        };
    }

    pub fn applyWrite(self: *Gpio, address: u32, width: u3, value: u32) void {
        _ = width;
        const offset = address -% win_base;
        const index = offset / port_stride;
        if (index >= port_count) return;
        switch (offset % port_stride) {
            pcntr1 => {
                self.ports[index].pdr = @truncate(value & half_mask);
                self.setLatch(index, @truncate((value >> half_shift) & half_mask));
            },
            pcntr3 => {
                // POSR sets, PORR clears, in that order, so a word that names
                // the same pin in both halves leaves it clear the way the
                // hardware's clear-dominant pair does.
                const posr: u16 = @truncate(value & half_mask);
                const porr: u16 = @truncate((value >> half_shift) & half_mask);
                var latch = self.ports[index].podr;
                latch |= posr;
                latch &= ~porr;
                self.setLatch(index, latch);
            },
            else => {},
        }
    }

    fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
        const self: *Gpio = @ptrCast(@alignCast(context));
        return self.readReg(address, width);
    }

    fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
        const self: *Gpio = @ptrCast(@alignCast(context));
        self.applyWrite(address, width, value);
    }

    pub fn block(self: *Gpio) periph.Block {
        return .{
            .name = "GPIO/PORT",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// The address of one PCNTR register, for tests and for anything that wants to
/// poke a port without doing the arithmetic itself.
pub fn regAddress(port: u32, offset: u32) u32 {
    return win_base + port * port_stride + offset;
}

test "a port resets with nothing driven and both switches released" {
    const gpio = Gpio.init();
    try std.testing.expectEqual(@as(u32, 0), gpio.readReg(regAddress(6, pcntr1), 4));
    try std.testing.expect(gpio.pinLevel(sw_port, sw1_pin));
    try std.testing.expect(gpio.pinLevel(sw_port, sw2_pin));
    try std.testing.expectEqual(@as(u1, 0), gpio.ledLevel(0));
}

test "PCNTR1 carries the latch in the high half and the direction in the low" {
    var gpio = Gpio.init();
    gpio.applyWrite(regAddress(6, pcntr1), 4, (@as(u32, 0x0001) << 16) | 0x0001);
    try std.testing.expectEqual(@as(u32, 0x0001_0001), gpio.readReg(regAddress(6, pcntr1), 4));
    try std.testing.expectEqual(@as(u16, 1), gpio.ports[6].pdr);
    try std.testing.expectEqual(@as(u16, 1), gpio.ports[6].podr);
}

test "an output pin reads its own level back through PCNTR2" {
    var gpio = Gpio.init();
    // P600 as an output, driven high: this is the LED1 blink the sparse file
    // could never answer honestly.
    gpio.applyWrite(regAddress(6, pcntr1), 4, (@as(u32, 1) << 16) | 1);
    try std.testing.expectEqual(@as(u32, 1), gpio.readReg(regAddress(6, pcntr2), 4));
    gpio.applyWrite(regAddress(6, pcntr1), 4, (@as(u32, 0) << 16) | 1);
    try std.testing.expectEqual(@as(u32, 0), gpio.readReg(regAddress(6, pcntr2), 4));
}

test "an input pin reads what the board drives, not what the latch holds" {
    var gpio = Gpio.init();
    // Latch high but direction input: the pin is not driven by the firmware.
    gpio.applyWrite(regAddress(0, pcntr1), 4, (@as(u32, 1) << 16) | 0);
    try std.testing.expectEqual(@as(u32, 0), gpio.readReg(regAddress(0, pcntr2), 4) & 1);
    gpio.setInput(0, 0, true);
    try std.testing.expectEqual(@as(u32, 1), gpio.readReg(regAddress(0, pcntr2), 4) & 1);
}

test "pressing a user switch pulls its pin low" {
    var gpio = Gpio.init();
    const sw1 = @as(u32, 1) << sw1_pin;
    try std.testing.expectEqual(sw1, gpio.readReg(regAddress(sw_port, pcntr2), 4) & sw1);
    gpio.setInput(sw_port, sw1_pin, false);
    try std.testing.expectEqual(@as(u32, 0), gpio.readReg(regAddress(sw_port, pcntr2), 4) & sw1);
    try std.testing.expect(!gpio.getInput(sw_port, sw1_pin));
}

test "PCNTR3 sets and clears without touching the rest of the port" {
    var gpio = Gpio.init();
    gpio.applyWrite(regAddress(3, pcntr1), 4, (@as(u32, 0x00F0) << 16) | 0xFFFF);
    gpio.applyWrite(regAddress(3, pcntr3), 4, 0x0003); // POSR: set pins 0,1
    try std.testing.expectEqual(@as(u16, 0x00F3), gpio.ports[3].podr);
    gpio.applyWrite(regAddress(3, pcntr3), 4, @as(u32, 0x00F0) << 16); // PORR
    try std.testing.expectEqual(@as(u16, 0x0003), gpio.ports[3].podr);
    try std.testing.expectEqual(@as(u16, 0xFFFF), gpio.ports[3].pdr);
}

test "a pin named in both PCNTR3 halves ends clear" {
    var gpio = Gpio.init();
    gpio.applyWrite(regAddress(1, pcntr3), 4, (@as(u32, 0x0001) << 16) | 0x0001);
    try std.testing.expectEqual(@as(u16, 0), gpio.ports[1].podr);
}

test "PCNTR3 reads zero, and PCNTR4 is unmodelled" {
    var gpio = Gpio.init();
    gpio.applyWrite(regAddress(2, pcntr3), 4, 0xFFFF);
    try std.testing.expectEqual(@as(u32, 0), gpio.readReg(regAddress(2, pcntr3), 4));
    gpio.applyWrite(regAddress(2, pcntr4), 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), gpio.readReg(regAddress(2, pcntr4), 4));
}

test "a blink counts one edge per change, on either write path" {
    var gpio = Gpio.init();
    gpio.applyWrite(regAddress(6, pcntr1), 4, 1); // P600 output, latch low
    try std.testing.expect(gpio.quiet());
    gpio.applyWrite(regAddress(6, pcntr3), 4, 1); // POSR high
    gpio.applyWrite(regAddress(6, pcntr3), 4, @as(u32, 1) << 16); // PORR low
    gpio.applyWrite(regAddress(6, pcntr1), 4, (@as(u32, 1) << 16) | 1); // high again
    try std.testing.expectEqual(@as(u32, 3), gpio.ledEdges(0));
    try std.testing.expectEqual(@as(u1, 1), gpio.ledLevel(0));
    try std.testing.expect(!gpio.quiet());
}

test "writing the same latch twice is not an edge" {
    var gpio = Gpio.init();
    gpio.applyWrite(regAddress(3, pcntr1), 4, (@as(u32, 1) << (16 + 3)) | (1 << 3));
    gpio.applyWrite(regAddress(3, pcntr1), 4, (@as(u32, 1) << (16 + 3)) | (1 << 3));
    try std.testing.expectEqual(@as(u32, 1), gpio.ledEdges(1));
}

test "each LED tracks only its own port and pin" {
    var gpio = Gpio.init();
    gpio.applyWrite(regAddress(10, pcntr1), 4, (@as(u32, 0xFFFF) << 16) | 0xFFFF);
    try std.testing.expectEqual(@as(u32, 1), gpio.ledEdges(2));
    try std.testing.expectEqual(@as(u32, 0), gpio.ledEdges(0));
    try std.testing.expectEqual(@as(u32, 0), gpio.ledEdges(1));
}

test "the window ends at PORT14 and addresses past it are inert" {
    var gpio = Gpio.init();
    try std.testing.expectEqual(win_base + 0x1E0, win_base + win_span);
    gpio.applyWrite(win_base + win_span, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), gpio.readReg(win_base + win_span, 4));
}

test "the port block answers on the bus, on both security aliases" {
    var bus = periph.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var gpio = Gpio.init();
    try bus.add(gpio.block());

    bus.write(regAddress(6, pcntr1), 4, (@as(u32, 1) << 16) | 1);
    try std.testing.expectEqual(@as(u32, 1), bus.read(periph.ns_base - periph.base + regAddress(6, pcntr2), 4));
    try std.testing.expectEqual(@as(u32, 0), bus.unmodelledAddresses());
}

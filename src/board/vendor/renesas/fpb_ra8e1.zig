//! Peripheral wiring for the single-core RA8E1 / FPB-RA8E1 machine profile
//! (`R01UH1129EJ0110` Rev.1.10 & `R20UT5474EG0100` Rev.1.00).
const Board = @import("../../board.zig").Board;
const fcache = @import("ra8_chip").vendor.renesas.ra8e1.fcache;
const gpio = @import("ra8_chip").periph.gpio;
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const ra8e1 = @import("ra8_chip").vendor.renesas.ra8e1;
const wiring = @import("../../wiring.zig");

const icu_slots: u32 = 96;

/// Attach only the on-chip peripherals and board wiring present on FPB-RA8E1.
pub fn attach(self: *Board, memory: Guest) !void {
    try wiring.attachGate(self);
    self.modules.resetRa8e1();

    self.pins = gpio.Gpio.init();
    self.pins.pullUp(0, 9); // S1 = P009 active-low (R20UT5474EG0100 Table 2).
    try self.bus.add(self.pins.blockRa8e1());
    self.pinfunc.resetRa8e1();
    for (self.pinfunc.blocksRa8e1()) |block| {
        try self.bus.add(block);
    }

    try self.bus.add(self.protection.block());
    try self.bus.add(self.protection.nsBlock());
    self.fcache = fcache.Fcache.init(&self.protection);
    try self.bus.add(self.fcache.block());

    try wiring.attachSharedProtected(self, false);
    self.oscillators.resetRa8e1();
    self.tree.resetRa8e1();

    self.serial.configureRa8e1();
    for (self.serial.blocksRa8e1()) |block| {
        try self.bus.add(block);
    }
    for (self.pwm.blocksRa8e1()) |block| {
        try self.bus.add(block);
    }
    try self.wire.attachRiicOnly(&self.bus);
    self.wire.clock(&self.time.base);
    try self.usb.attachFs(&self.bus);
    self.trace.memory = memory;

    try wiring.attachSharedPeripherals(self, memory);
    self.events.issuer = &self.bus.issuer;
    try self.bus.add(self.events.blockSlots(icu_slots));
    try self.bus.add(self.events.pinsBlockRa8e1());
    try self.bus.add(self.events.nmiBlock());

    try ra8e1.seedMemory(memory);
}

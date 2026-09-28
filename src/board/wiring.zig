//! Wiring: the order the blocks go onto the peripheral bus.
//!
//! board.zig owns the blocks themselves, what each one is and how it is
//! built. This file owns the one thing that is not about any single block:
//! the sequence they are added in, which is load-bearing. The module-stop
//! shadow goes on first and then becomes the gate the rest of the bus is
//! filtered through; PORT follows it because PORT has no module-stop bit on
//! this part and has to answer regardless of MSTPCRx; and the blocks that
//! paint into or read out of RAM need the engine handed to them as they go
//! on. Keeping it here leaves board.zig as the list of what the board is.
const engine = @import("../core/engine.zig");

const Board = @import("board.zig").Board;

const bkup = @import("../periph/bkup.zig");
const dmac = @import("../periph/dmac.zig");
const drw = @import("../periph/drw.zig");
const eink = @import("../periph/eink.zig");
const modem = @import("../periph/modem.zig");
const ckcr = @import("../periph/ckcr.zig");
const pdctr = @import("../periph/pdctr.zig");
const sd_card = @import("../periph/sd_card.zig");

/// Put every block on the bus, in the order that works.
pub fn attach(self: *Board, core: *engine.Engine) !void {
    try self.bus.add(self.modules.block());
    self.bus.gate = self.modules.gate();
    try self.bus.add(self.pins.block());
    try self.bus.add(self.checksum.block());
    try self.bus.add(self.dataops.block());
    try self.bus.add(self.accuracy.block());
    try self.bus.add(self.comparators.block());
    self.capture.memory = core.*;
    try self.bus.add(self.capture.block());
    try self.bus.add(self.analog.block());
    try self.bus.add(self.adc.block());
    try self.bus.add(self.shutoff.block());
    try self.bus.add(self.protection.block());
    try self.bus.add(self.oscillators.block());
    try attachProtected(self);
    // The panel is scanned out of the same RAM the engine paints into.
    try self.display.attach(&self.bus, &self.graphics, core.*);
    self.raster = drw.Drw.init(&self.graphics);
    // The engine rasterizes into RAM, so it needs the machine that owns
    // it. A board built by a test without one declines the render.
    self.raster.memory = core.*;
    try self.bus.add(self.raster.block());
    try self.bus.add(self.link.block());
    try self.bus.add(self.receiver.block());
    try self.bus.add(self.host.block());
    try self.bus.add(self.serial.block());
    try self.bus.add(self.spi.block());
    self.spi.attachDevice(sd_card.line_channel, self.sd.device());
    self.spi.attachDevice(eink.line_channel, self.panel.device());
    self.pins.setInput(eink.hrdy.port, eink.hrdy.pin, true);
    self.serial.attachDevice(modem.line_channel, self.modem.device());
    try self.wire.attach(&self.bus);
    try self.rswitch.attach(&self.bus, core.*);
    try self.usb.attach(&self.bus);
    self.trace.memory = core.*;
    try self.bus.add(self.flash.block());
    try self.bus.add(self.cipher.block());
    try self.options.attach(&self.bus, core.*);
    try self.bus.add(self.card.block());
    try self.bus.add(self.ecc.block());
    try self.bus.add(self.audio.block());
    try self.bus.add(self.microphone.block());
    try self.bus.add(self.clock.block());
    try self.bus.add(self.can.block(0));
    try self.bus.add(self.can.block(1));
    try self.bus.add(self.mailbox.block());
    if (self.part.hasNpu()) {
        self.npu.memory = core.*;
        try self.bus.add(self.npu.block());
    }
    try self.bus.add(self.lowpower.block());
    try self.bus.add(self.interval.block());
    try self.bus.add(self.pwm.block());
    try self.bus.add(self.ptp.block());
    try self.bus.add(self.events.block());
    try self.bus.add(self.links.block());
    try self.bus.add(self.transfers.block());
    try self.bus.add(self.dma_module.block());
    self.dma = dmac.Dmac.init(&self.dma_module);
    self.dma.memory = core.*;
    try self.bus.add(self.dma.block());
    try self.bus.add(self.monitors.statusBlock());
    try self.bus.add(self.monitors.controlBlock());
    try self.bus.add(self.monitors.filterBlock());
    try self.bus.add(self.watchdog.block());
    try self.bus.add(self.heartbeat.block());
    try self.bus.add(self.causes.statusBlock());
    try self.bus.add(self.causes.causeBlock());
    try core.attachPeriph(&self.bus);
    // AIRCR is PPB RAM, not a bus block, and RAM starts at zero: without
    // this the first read of it is 0 rather than the key status.
    try self.control.prime(core.*);
    // Same reason for the cache window: CTR read as zero, so the firmware
    // computed a four-byte line and walked every range eight times over.
    try self.caches.prime(core.*);
}

/// The blocks that ask PRCR before they accept a store. Each needs a pointer
/// to the protection model this board owns, not a copy of one, so none of
/// them can be built in the struct literal.
fn attachProtected(self: *Board) !void {
    self.backup = bkup.Bkup.init(&self.protection);
    try self.bus.add(self.backup.block());
    self.branches = ckcr.Ckcr.init(&self.protection);
    for (0..ckcr.windows.len) |which| try self.bus.add(self.branches.block(which));
    self.graphics = pdctr.Pdctr.init(&self.protection);
    try self.bus.add(self.graphics.block());
}

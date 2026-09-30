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
const octaclk = @import("../periph/octaclk.zig");
const mrms = @import("../periph/mrms.zig");
const ckdiv = @import("../periph/ckdiv.zig");
const oscsf = @import("../periph/oscsf.zig");
const subclock = @import("../periph/subclock.zig");
const reset = @import("../periph/reset.zig");
const sysclk = @import("../periph/sysclk.zig");
const voltage_hazard = @import("../periph/voltage_hazard.zig");
const lpm = @import("../periph/lpm.zig");
const pll = @import("../periph/pll.zig");
const gtclkcr = @import("../periph/gtclkcr.zig");
const pscu = @import("../periph/pscu.zig");
const vscr = @import("../periph/vscr.zig");
const pdctr = @import("../periph/pdctr.zig");
const sd_card = @import("../periph/sd_card.zig");
const sd_card_line = @import("../periph/sd_card_line.zig");

/// The module-stop shadow, the attribution words that decide which of its
/// bits a Secure store may move, and the gate the rest of the bus hangs off.
/// These three go on together because none of them is any use alone.
fn attachGate(self: *Board) !void {
    try self.bus.add(self.modules.block());
    self.modules.attribution = &self.attribution;
    try self.bus.add(self.attribution.block());
    self.bus.gate = self.modules.gate();
}

/// Put every block on the bus, in the order that works.
pub fn attach(self: *Board, core: *engine.Engine) !void {
    try attachGate(self);
    try self.bus.add(self.pins.block());
    try self.bus.add(self.pinfunc.block());
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
    try attachProtected(self);
    // The panel is scanned out of the same RAM the engine paints into.
    try self.display.attach(&self.bus, &self.domains.graphics, core.*);
    self.raster = drw.Drw.init(&self.domains.graphics);
    // The engine rasterizes into RAM, so it needs the machine that owns
    // it. A board built by a test without one declines the render.
    self.raster.memory = core.*;
    try self.bus.add(self.raster.block());
    try self.bus.add(self.link.block());
    try self.bus.add(self.receiver.block());
    try self.bus.add(self.host.block());
    try self.bus.add(self.serial.block());
    try self.bus.add(self.spi.block());
    // The card is on Pmod2, which is SCI0 in Simple-SPI mode, not on a
    // SPI_B channel (src/periph/sd_card_line.zig).
    self.sd_line = sd_card_line.Line.init(&self.sd);
    self.serial.attachDevice(sd_card_line.line_channel, self.sd_line.device());
    self.spi.attachDevice(eink.line_channel, self.panel.device());
    self.pins.setInput(eink.hrdy.port, eink.hrdy.pin, true);
    self.serial.attachDevice(modem.line_channel, self.modem.device());
    try self.wire.attach(&self.bus);
    try self.rswitch.attach(&self.bus, core.*, &self.domains.eswm);
    try self.usb.attach(&self.bus);
    self.trace.memory = core.*;
    try self.bus.add(self.flash.block());
    try self.bus.add(self.cipher.block());
    try self.options.attach(&self.bus, core.*);
    try self.bus.add(self.second_core.block());
    try self.bus.add(self.memory_rates.block());
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
    try self.bus.add(self.events.pinsBlock());
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
    try primeCoreWindows(self, core);
}

/// The core's own windows are PPB RAM rather than bus blocks, and RAM starts
/// at zero. Every one of these is a register the firmware reads before it
/// writes anything, so a zero is not a neutral starting value: it is a wrong
/// answer the firmware then believes. Seed each with what the core reports.
/// Put a SECOND core in front of the board the first already owns.
///
/// Only the per-core wiring is repeated. The blocks themselves are
/// registered once, on the one bus the board owns, and both cores dispatch
/// into that same registry: that is what makes IPCSEM and the IPC channels
/// ONE block both cores reach rather than two models kept in step, which is
/// the whole point of the pingpong apps. Adding them a second time is what
/// `registry.Error.OverlappingBlock` is there to catch.
///
/// The blocks that hold a core of their own (the rasterizer, the capture
/// unit, the DMA engines, the NPU) keep CPU0's. They read and write memory
/// on behalf of whoever programmed them, and in this model CPU0 is the core
/// that owns the clocks and the interrupt controller; handing them CPU1
/// instead would move the asymmetry, not remove it.
pub fn attachSecond(self: *Board, core: *engine.Engine) !void {
    try core.attachPeriph(&self.bus);
    try primeCoreWindows(self, core);
    self.second_core.mapped = true;
}

fn primeCoreWindows(self: *Board, core: *engine.Engine) !void {
    // AIRCR: the first read of it is 0 rather than the key status.
    try self.control.prime(core.*);
    // CTR read as zero, so the firmware computed a four-byte line and
    // walked every range eight times over.
    try self.caches.prime(core.*);
    // MPU_TYPE read as zero, so ra8_mpu_configure rejected every
    // configuration for want of capacity and main never got past it.
    try self.regions.prime(core.*);
    // RBAR/RLAR are one word each in RAM, so without this every region a
    // driver programs overwrites the last and the table reads back empty.
    // The guard goes on with it: the same hook that banks the table is the
    // one that sees CTRL and arms the read-only traps.
    try core.attachRegions(&self.regions, &self.guard);
}

/// The blocks that ask PRCR before they accept a store. Each needs a pointer
/// to the protection model this board owns, not a copy of one, so none of
/// them can be built in the struct literal.
fn attachProtected(self: *Board) !void {
    self.backup = bkup.Bkup.init(&self.protection);
    try self.bus.add(self.backup.block());
    self.oscillators = oscsf.Oscillators.init(&self.protection);
    try self.bus.add(self.oscillators.block());
    self.subclk = subclock.Unit.init(&self.protection);
    try self.bus.add(self.subclk.block());
    // The tree asks the oscillators whether the source it was told to select
    // had stabilised, so it goes on after them.
    // The core voltage range is step 2 of the same protected bring-up, and it
    // has to exist before the tree: the tree tells the brown-out watch about
    // every clock select, and the watch reads this range live.
    self.voltage = vscr.Unit.init(&self.protection);
    try self.bus.add(self.voltage.block());
    self.brownout = voltage_hazard.Watch.init(&self.voltage);
    self.tree = sysclk.Tree.init(&self.protection, &self.oscillators, &self.brownout);
    try self.bus.add(self.tree.block());
    self.branches = ckcr.Ckcr.init(&self.protection);
    for (0..ckcr.windows.len) |which| try self.bus.add(self.branches.block(which));
    // MSTPB16/B17 may only be released once OCTACKCR has handshaken (HUM
    // Ch 11.2.7 Note 3), so the watch reads the selects live and both the
    // module-stop window and the command engine it uncovers consult it.
    self.octa = octaclk.Octa.init(&self.branches);
    self.modules.octa = &self.octa;
    self.flash.octa = &self.octa;
    // The dividers ask the selects whether the branch is gated, so they go
    // on after the selects they are paired with.
    self.ratios = ckdiv.Ckdiv.init(&self.protection, &self.branches);
    for (0..ckdiv.windows.len) |which| try self.bus.add(self.ratios.block(which));
    // PLL1's configuration asks PRCR before a store, as the clock tree does.
    self.plls = pll.Unit.init(&self.protection, &self.oscillators);
    // GTCLKCR is the GPT bank's clock domain, and only the module-stop
    // model can say whether the window to change it is still open.
    self.gpt_clock = gtclkcr.Unit.init(&self.modules);
    try self.bus.add(self.gpt_clock.block());
    for (0..pll.slots.len) |which| try self.bus.add(self.plls.block(which));
    // The low-power bytes ask PRCR before a store, so they go on after it.
    self.low_power = lpm.Unit.init(&self.protection);
    for (0..lpm.slots.len) |which| try self.bus.add(self.low_power.block(which));
    self.domains = pdctr.Domains.init(&self.protection);
    try self.bus.add(self.domains.graphics.block());
    try self.bus.add(self.domains.eswm.block());
    // SYRSTMSK0/1/2 is PRC5-protected, and its two watchdog mask bits freeze
    // while their watchdog runs (HUM Ch 6.2.6 p 263), so it reads both
    // watchdogs' armed flags live rather than a copy.
    self.causes.watchWatchdogs(
        &self.protection,
        &self.watchdog.armed,
        &self.heartbeat.armed,
    );
    try self.bus.add(self.causes.maskBlock());
}

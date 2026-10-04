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
const Guest = @import("../core/cpu/memory/guest.zig").Guest;
const tsn_cal = @import("../periph/adc/adc_tsn_cal.zig");
const sau = @import("../periph/sau.zig");
const mpu = @import("../periph/mpu/mpu.zig");
const mpu_guard = @import("../core/mpu_guard.zig");
const mpu_ns_hook = @import("../core/mpu_ns_hook.zig");
const cpuid = @import("../periph/cpuid.zig");
const dwt = @import("../debug/dwt.zig");
const scb = @import("../periph/scb.zig");
const fault_clear = @import("../periph/fault_clear.zig");

const Board = @import("board.zig").Board;
const plug = @import("plug.zig");

const bkup = @import("../periph/bkup/bkup.zig");
const dmac = @import("../periph/dmac/dmac.zig");
const drw = @import("../periph/drw/drw.zig");
const eink = @import("../periph/eink/eink.zig");
const modem = @import("../periph/modem/modem.zig");
const ckcr = @import("../periph/ckcr.zig");
const octaclk = @import("../periph/octaclk.zig");
const mrms = @import("../periph/mrms.zig");
const ckdiv = @import("../periph/ckdiv.zig");
const oscsf = @import("../periph/oscsf.zig");
const subclock = @import("../periph/subclock.zig");
const reset = @import("../periph/reset.zig");
const sysclk = @import("../periph/sysclk/sysclk.zig");
const voltage_hazard = @import("../periph/voltage_hazard.zig");
const lpm = @import("../periph/lpm/lpm.zig");
const pll = @import("../periph/pll/pll.zig");
const gtclkcr = @import("../periph/gtclkcr.zig");
const pscu = @import("../periph/pscu.zig");
const cpscu = @import("../periph/cpscu.zig");
const dtc = @import("../periph/dtc/dtc.zig");
const vscr = @import("../periph/vscr.zig");
const pdctr = @import("../periph/pdctr.zig");
const sd_card = @import("../periph/sd/sd_card.zig");
const sd_card_line = @import("../periph/sd/sd_card_line.zig");

/// The module-stop shadow, the attribution words that decide which of its
/// bits a Secure store may move, and the gate the rest of the bus hangs off.
/// These three go on together because none of them is any use alone.
fn attachGate(self: *Board) !void {
    try self.bus.add(self.modules.block());
    self.modules.attribution = &self.attribution;
    self.modules.bus = &self.bus;
    try self.bus.add(self.attribution.block());
    self.bus.gate = self.modules.gate();
}

/// The ADC, and the TSN factory calibration words its die-temperature line
/// is converted against (adc_tsn_cal.zig).
fn attachAdc(self: *Board, core: Guest) !void {
    try self.bus.add(self.adc.block());
    _ = tsn_cal.map(core) catch false;
}

/// The I2C lines with their fitted parts, then the run's `--attach` asks,
/// so a clash with a fitted part is reported against the ask.
fn attachWire(self: *Board) !void {
    try self.wire.attach(&self.bus);
    try plug.all(self);
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
    self.capture.memory = .{ .engine = core.* };
    try self.bus.add(self.capture.block());
    try self.bus.add(self.analog.block());
    try attachAdc(self, .{ .engine = core.* });
    try self.bus.add(self.shutoff.block());
    try self.bus.add(self.protection.block());
    try attachProtected(self);
    // The panel is scanned out of the same RAM the engine paints into.
    try self.display.attach(&self.bus, &self.domains.graphics, .{ .engine = core.* });
    self.raster = drw.Drw.init(&self.domains.graphics);
    // Rendering uses the board's RAM.
    self.raster.memory = .{ .engine = core.* };
    try self.bus.add(self.raster.block());
    try self.bus.add(self.link.block());
    try self.bus.add(self.receiver.block());
    try self.bus.add(self.host.block());
    try self.bus.add(self.serial.block());
    self.c6.init(&self.serial, &self.pins);
    try self.bus.add(self.spi.block());
    // The card is on Pmod2, which is SCI0 in Simple-SPI mode, not on a
    // SPI_B channel (src/periph/sd_card_line.zig).
    self.sd_line = sd_card_line.Line.init(&self.sd);
    self.serial.attachDevice(sd_card_line.line_channel, self.sd_line.device());
    self.spi.attachDevice(eink.line_channel, self.panel.device());
    self.pins.setInput(eink.hrdy.port, eink.hrdy.pin, true);
    self.serial.attachDevice(modem.line_channel, self.modem.device());
    try attachWire(self);
    try self.rswitch.attach(&self.bus, .{ .engine = core.* }, &self.domains.eswm);
    try self.usb.attach(&self.bus);
    self.trace.memory = .{ .engine = core.* };
    try self.bus.add(self.flash.block());
    try self.bus.add(self.cipher.block());
    try self.options.attach(&self.bus, .{ .engine = core.* });
    try self.bus.add(self.second_core.block());
    try self.bus.add(self.memory_rates.block());
    try self.memory_ecc.attach(&self.bus);
    try self.sdram.attach(&self.bus);
    try self.bus.add(self.card.block());
    try self.bus.add(self.ecc.block());
    try self.bus.add(self.audio.block());
    try self.bus.add(self.microphone.block());
    try self.bus.add(self.clock.block());
    try self.bus.add(self.can.block(0));
    try self.bus.add(self.can.block(1));
    try self.bus.add(self.mailbox.block());
    if (self.part.hasNpu()) {
        self.npu.memory = .{ .engine = core.* };
        try self.bus.add(self.npu.block());
    }
    try self.bus.add(self.lowpower.block());
    try self.bus.add(self.interval.block());
    try self.bus.add(self.pwm.block());
    try self.bus.add(self.ptp.block());
    self.events.issuer = &self.bus.issuer;
    try self.bus.add(self.events.block());
    try self.bus.add(self.events.pinsBlock());
    for (self.events.sideBlocks()) |block| try self.bus.add(block);
    try self.bus.add(self.links.block());
    try attachTransfers(self);
    try self.bus.add(self.dma_module.block());
    self.dma = dmac.Dmac.init(&self.dma_module);
    self.dma.memory = .{ .engine = core.* };
    try self.bus.add(self.dma.block());
    try self.bus.add(self.monitors.statusBlock());
    try self.bus.add(self.monitors.controlBlock());
    try self.bus.add(self.monitors.filterBlock());
    try self.bus.add(self.watchdog.block());
    try self.bus.add(self.heartbeat.block());
    try self.bus.add(self.causes.statusBlock());
    try self.bus.add(self.causes.causeBlock());
    try attachCore(self, core);
}

/// Last step of `attach`: hand the finished bus to the engine, then prime
/// CPU0's own SAU and MPU windows.
/// DTC0 and DTC1 share one window, served by whichever core is on the bus;
/// DTC1 starts on the DTCE bits of CPU1's ICU table.
fn attachTransfers(self: *Board) !void {
    self.transfers1.table = .cpu1;
    self.transfers.twin = &self.transfers1;
    self.transfers.issuer = &self.bus.issuer;
    try self.bus.add(self.transfers.block());
    self.transfer_attribution = dtc.attribution.Unit.init(&self.protection);
    try self.bus.add(self.transfer_attribution.block());
}

fn attachCore(self: *Board, core: *engine.Engine) !void {
    try core.attachPeriph(&self.bus);
    try primeCoreWindows(self, core, .{
        .partitions = &self.partitions,
        .regions = &self.regions,
        .regions_ns = &self.regions_ns,
        .guard = &self.guard,
        .identity = cpuid.cpu0,
        .control = &self.control,
        .clears = &self.clears,
    });
}

/// The state that lives inside one core rather than on the bus: its SAU,
/// its MPU table and the guard that enforces that table. CPU0's are the
/// board's own; CPU1 brings its own set.
pub const CoreWindows = struct {
    partitions: *sau.Sau,
    regions: *mpu.Mpu,
    guard: *mpu_guard.Guard,
    /// The Non-secure MPU table the MPU_NS alias files into, when this core
    /// has one wired (RA8EMU-445).
    regions_ns: ?*mpu.Mpu = null,
    /// The CPUID word this core answers with: a Cortex-M85 on CPU0, a
    /// Cortex-M33 on CPU1.
    identity: u32,
    /// The AIRCR model this core's writes are judged by. CPU0's is the
    /// board's own; CPU1 brings its own, so a PRIGROUP one core programs is
    /// never the split the other reports.
    control: *scb.Scb,
    /// The CFSR/HFSR clears this core's stores owe, applied at its boundary.
    clears: *fault_clear.Clears,
};

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
///
/// THE SAU AND THE MPU ARE NOT SHARED BLOCKS. They are taken as parameters
/// because they live inside the core rather than on the bus: see
/// `primeCoreWindows`.
pub fn attachSecond(self: *Board, core: *engine.Engine, windows: CoreWindows) !void {
    try core.attachPeriphAs(&self.bus, .cpu1);
    self.cpu1 = core.*;
    try primeCoreWindows(self, core, windows);
    self.second_core.mapped = true;
}

/// The windows that live inside a core rather than on the bus, seeded and
/// hooked for the core in front of them.
///
/// `partitions` is the caller's because the SAU is CORE-PRIVATE STATE: each
/// Cortex-M has its own, reached through its own PPB, and two cores
/// programme two different maps. Sharing one model let CPU1's SAU
/// bring-up land on top of CPU0's, and the report then described neither
/// core: with `cpu1_pingpong_ipc` mapped onto CPU1, CPU0's five regions and
/// two Non-Secure Callable entries read back as five regions and none,
/// because CPU1 had overwritten the first four with its own.
///
/// THE MPU BESIDE IT IS CORE-PRIVATE IN EXACTLY THE SAME WAY, so it comes
/// in with the SAU: the table and the guard that enforces it are the
/// caller's. Shared, a CTRL store from either core rebuilt the traps from
/// one table on whichever engine made it, and CPU0's regions were CPU1's.
fn primeCoreWindows(self: *Board, core: *engine.Engine, windows: CoreWindows) !void {
    const guest: Guest = .{ .engine = core.* };
    // CPUID read as zero on both cores, so neither said what it was.
    try cpuid.prime(guest, windows.identity);
    // DWT_CTRL.NUMCOMP read as zero, so the core claimed no comparators.
    try guest.writeWord(dwt.base, dwt.ctrlReset(windows.identity));
    // AIRCR: the first read of it is 0 rather than the key status.
    try windows.control.prime(guest);
    // CTR read as zero, so the firmware computed a four-byte line and
    // walked every range eight times over.
    try self.caches.prime(guest);
    // MPU_TYPE read as zero, so ra8_mpu_configure rejected every
    // configuration for want of capacity and main never got past it.
    try windows.regions.prime(guest);
    // The Non-secure view of MPU_TYPE is its own banked word (RA8EMU-446).
    try mpu.ns.prime(guest, mpu.geometry.type_value);
    // RBAR/RLAR are one word each in RAM, so without this every region a
    // driver programs overwrites the last and the table reads back empty.
    // The guard goes on with it: the same hook that banks the table is the
    // one that sees CTRL and arms the read-only traps.
    try core.attachRegions(windows.regions, windows.guard);
    // Secure code programs the Non-secure MPU through the MPU_NS alias.
    if (windows.regions_ns) |ns| try mpu_ns_hook.attach(core.handle, ns);
    // SAU_TYPE read as zero, so the secure boot's capability check failed
    // and ra8_tz_secure_boot_sau_init programmed nothing and returned an
    // error, parking the run in the Secure fallback main() forever.
    try windows.partitions.prime(guest);
    // The SAU's own RBAR/RLAR bank through RNR exactly like the MPU's, so
    // the five regions the boot map programs need the same hook to keep
    // from collapsing onto one entry.
    try core.attachPartitions(windows.partitions);
    // CFSR and HFSR are write-one-to-clear, and RAM is not.
    try core.attachFaultClears(windows.clears);
}

/// The blocks that ask PRCR before they accept a store. Each needs a pointer
/// to the protection model this board owns, not a copy of one, so none of
/// them can be built in the struct literal.
fn attachProtected(self: *Board) !void {
    self.backup = bkup.Bkup.init(&self.protection);
    try self.bus.add(self.backup.block());
    self.battery_switch = bkup.pcr1.Pcr1.init(&self.protection);
    try self.bus.add(self.battery_switch.block());
    self.oscillators = oscsf.Oscillators.init(&self.protection);
    try self.bus.add(self.oscillators.block());
    self.subclk = subclock.Unit.init(&self.protection);
    try self.bus.add(self.subclk.block());
    self.loco = subclock.loco.Unit.init(&self.protection);
    try self.bus.add(self.loco.block());
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
    try self.bus.add(self.pwm_delay.block());
    for (0..pll.slots.len) |which| try self.bus.add(self.plls.block(which));
    // The low-power bytes ask PRCR before a store, so they go on after it.
    self.low_power = lpm.Unit.init(&self.protection);
    for (0..lpm.slots.len) |which| try self.bus.add(self.low_power.block(which));
    try self.bus.add(self.standby_cancel.block());
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
    // IPCSAR / IPCPAR are PRC4-gated and sit in CPSCU, nowhere near the
    // mailbox window, so the mailbox offers them as a block of their own.
    self.mailbox.protect(&self.protection);
    try self.bus.add(self.mailbox.attributionBlock());
    // The rest of the CPSCU attribution the boot writes in the same scope:
    // the bus masters, the master MPUs and the second CPU, behind PRC4 too.
    self.chip_attribution = cpscu.Unit.init(&self.protection);
    try self.bus.add(self.chip_attribution.block());
    for (self.sram_attribution.blocks()) |window| try self.bus.add(window);
    self.idau = sau.idau.Map.forPart(&self.sram_attribution, self.part == .ra8p1);
    for (self.memory_monitors.blocks()) |window| try self.bus.add(window);
    if (self.memory_monitors.cms) |area| self.idau.code_secure = sau.idau.cmsBytes(area);
}

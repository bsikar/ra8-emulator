//! The initial value of every block the board holds.
//!
//! board.zig is the list of what a board is made of, and wiring.zig is the
//! order those blocks go onto the bus. This file is the third question and
//! the least interesting one: what each block starts as before anything has
//! been wired or run. It is here rather than in board.zig because the list
//! of parts and the construction of them are two subjects, and the list is
//! the one worth reading first.
//!
//! A field left `undefined` here is one that cannot exist yet: it needs a
//! pointer into the board that is still being built, so wiring.zig fills it
//! in during attach(). The comment on the field in board.zig says which.
const std = @import("std");

const Board = @import("board.zig").Board;

const acmphs = @import("ra8_chip").periph.acmphs;
const adc = @import("ra8_chip").periph.adc;
const agt = @import("ra8_chip").periph.agt;
const bkup = @import("ra8_chip").periph.bkup;
const bus_card = @import("ra8_components").sd_card.bus_card;
const cac = @import("ra8_chip").periph.cac;
const cache = @import("ra8_chip").periph.cache;
const canfd = @import("ra8_chip").periph.canfd;
const ceu = @import("ra8_chip").periph.ceu;
const ckcr = @import("ra8_chip").periph.ckcr;
const ckdiv = @import("ra8_chip").periph.ckdiv;
const cpscu = @import("ra8_chip").periph.cpscu;
const crc = @import("ra8_chip").periph.crc;
const dac = @import("ra8_chip").periph.dac;
const dmac = @import("ra8_chip").periph.dmac;
const doc = @import("ra8_chip").periph.doc;
const dotf = @import("ra8_chip").periph.dotf;
const drw = @import("ra8_chip").periph.drw;
const dtc = @import("ra8_chip").periph.dtc;
const elc = @import("ra8_chip").periph.elc;
const fault_clear = @import("ra8_chip").periph.fault.clear;
const fcache = @import("ra8_chip").vendor.renesas.ra8e1.fcache;
const fpb_ra4t1 = @import("vendor/renesas/fpb_ra4t1.zig");
const glcdc = @import("ra8_chip").periph.glcdc;
const gpt = @import("ra8_chip").periph.gpt;
const gptp = @import("ra8_chip").periph.gptp;
const gtclkcr = @import("ra8_chip").periph.gtclkcr;
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const icu = @import("ra8_chip").periph.icu;
const ipc = @import("ra8_chip").periph.ipc;
const iwdt = @import("ra8_chip").periph.iwdt;
const lpm = @import("ra8_chip").periph.lpm;
const lvd = @import("ra8_chip").periph.lvd;
const mipi_csi = @import("ra8_chip").periph.mipi.csi;
const mipi_dsi = @import("ra8_chip").periph.mipi.dsi;
const mipi_phy = @import("ra8_chip").periph.mipi.phy;
const mpu = @import("ra8_chip").periph.mpu;
const mpu_guard = @import("ra8_chip").core.mpu_guard;
const mram = @import("ra8_chip").periph.mram;
const nor_flash = @import("ra8_components").nor_flash;
const npu = @import("ra8_chip").periph.npu;
const octaclk = @import("ra8_chip").periph.octaclk;
const oscsf = @import("ra8_chip").periph.oscsf;
const pdctr = @import("ra8_chip").periph.pdctr;
const pdm = @import("ra8_chip").periph.pdm;
const periph = @import("ra8_chip").periph.registry;
const pfs = @import("ra8_chip").periph.pfs;
const pll = @import("ra8_chip").periph.pll;
const poeg = @import("ra8_chip").periph.poeg;
const prcr = @import("ra8_chip").periph.prcr;
const reset = @import("ra8_chip").periph.reset;
const rtc = @import("ra8_chip").periph.rtc;
const sau = @import("ra8_chip").periph.sau;
const scb = @import("ra8_chip").periph.scb;
const sci = @import("ra8_chip").periph.sci;
const sd_card = @import("ra8_components").sd_card;
const sdhi = @import("ra8_chip").periph.sdhi;
const spi = @import("ra8_chip").periph.spi;
const sram = @import("ra8_chip").periph.sram;
const ssie = @import("ra8_chip").periph.ssie;
const subclock = @import("ra8_chip").periph.subclock;
const switches = @import("switches.zig");
const sysclk = @import("ra8_chip").periph.sysclk;
const ulpt = @import("ra8_chip").periph.ulpt;
const voltage_hazard = @import("ra8_chip").periph.voltage_hazard;
const vscr = @import("ra8_chip").periph.vscr;
const wdt = @import("ra8_chip").periph.wdt;

/// A fresh board, with nothing on the bus yet.
pub fn build(allocator: std.mem.Allocator) Board {
    return .{
        .bus = periph.Bus.init(allocator),
        .events = icu.Icu.init(),
        .links = elc.Elc.init(),
        .transfers = dtc.Dtc.init(),
        .transfers1 = dtc.Dtc.init(),
        .transfer_attribution = undefined,
        .dma = undefined,
        .pins = switches.pulled(),
        .touch_input = .{ .switches = &switches.user },
        .pinfunc = pfs.Pfs.init(),
        .checksum = crc.Crc.init(),
        .dataops = doc.Doc.init(),
        .accuracy = cac.Cac.init(),
        .comparators = acmphs.Acmphs.init(),
        .capture = ceu.Ceu.init(),
        .analog = dac.Dac.init(),
        .adc = adc.Adc.init(),
        .shutoff = poeg.Poeg.init(),
        .protection = prcr.Prcr.init(),
        .fcache = fcache.Fcache.init(null),
        // Patched in attach(): the backup file has to point at this
        // board's own protection model, not a copy of it.
        .backup = undefined,
        .battery_switch = undefined,
        .oscillators = undefined,
        .subclk = undefined,
        .loco = undefined,
        .tree = undefined,
        .low_power = undefined,
        .plls = undefined,
        .gpt_clock = undefined,
        .voltage = undefined,
        .brownout = undefined,
        .ratios = undefined,
        .branches = undefined,
        .chip_attribution = undefined,
        .domains = undefined,
        .display = undefined,
        .panel_vsync = null,
        .raster = undefined,
        .serial = sci.Sci.init(),
        .spi = spi.Spi.init(),
        .sd = sd_card.Card.init(allocator),
        .flash = .{},
        .nor = nor_flash.Flash.init(allocator),
        .octa = undefined,
        .cipher = dotf.Dotf.init(),
        .card = sdhi.Sdhi.init(),
        .host_card = bus_card.Card.init(allocator),
        .options = mram.Mram.init(allocator),
        .ecc = sram.Sram.init(),
        .audio = ssie.Ssie.init(),
        .microphone = pdm.Pdm.init(),
        .clock = rtc.Rtc.init(),
        .can = canfd.Canfd.init(),
        .mailbox = ipc.Ipc.init(),
        .npu = npu.Npu.init(),
        .lowpower = ulpt.Ulpt.init(),
        .interval = agt.Agt.init(),
        .pwm = gpt.Gpt.init(),
        .pwm_delay = gpt.pdg.Pdg.init(),
        .ptp = gptp.Gptp.init(),
        .monitors = lvd.Lvd.init(),
        .watchdog = wdt.Wdt.init(),
        .heartbeat = iwdt.Iwdt.init(),
        .link = mipi_phy.MipiPhy.init(),
        .receiver = mipi_csi.MipiCsi.init(),
        .host = mipi_dsi.MipiDsi.init(),
        .causes = reset.Reset.init(),
        .control = scb.Scb.init(),
        .clears = fault_clear.Clears.init(),
        .caches = cache.Cache.init(),
        .regions = mpu.Mpu.init(),
        .regions_ns = mpu.Mpu.init(),
        .guard = mpu_guard.Guard.init(),
        .partitions = sau.Sau.init(),
    };
}

/// Initializes every self-referential field left `undefined` in `build` once
/// `self` has its final address, whether or not RA8 peripheral blocks go onto
/// `self.bus`. Keeps snapshots, display hosts, reports, and boundary ticks
/// free of uninitialized fields on non-RA8 machines.
pub fn seed(self: *Board, memory: Guest) void {
    self.backup = bkup.Bkup.init(&self.protection);
    self.battery_switch = bkup.pcr1.Pcr1.init(&self.protection);
    self.fcache = fcache.Fcache.init(&self.protection);
    self.oscillators = oscsf.Oscillators.init(&self.protection);
    self.subclk = subclock.Unit.init(&self.protection);
    self.loco = subclock.loco.Unit.init(&self.protection);
    self.voltage = vscr.Unit.init(&self.protection);
    self.brownout = voltage_hazard.Watch.init(&self.voltage);
    self.tree = sysclk.Tree.init(&self.protection, &self.oscillators, &self.brownout);
    self.branches = ckcr.Ckcr.init(&self.protection);
    self.octa = octaclk.Octa.init(&self.branches);
    self.ratios = ckdiv.Ckdiv.init(&self.protection, &self.branches);
    self.plls = pll.Unit.init(&self.protection, &self.oscillators);
    self.gpt_clock = gtclkcr.Unit.init(&self.modules);
    self.low_power = lpm.Unit.init(&self.protection);
    self.domains = pdctr.Domains.init(&self.protection);
    self.display = glcdc.Glcdc.init(&self.domains.graphics);
    self.raster = drw.Drw.init(&self.domains.graphics);
    self.chip_attribution = cpscu.Unit.init(&self.protection);
    self.transfer_attribution = dtc.attribution.Unit.init(&self.protection);
    self.dma = dmac.Dmac.init(&self.dma_module);
    self.dma.memory = memory.asInitiator(.dmac);
    self.sd_line = sd_card.line.Line.init(&self.sd);
    self.trace.memory = memory;
    self.idau = sau.idau.Map.forPart(&self.sram_attribution, self.desc().part == .ra8p1);
    self.idau.custom = self.desc().memory.idau;
    if (self.desc().memory.resolvedPeripherals() == .ra4t1) fpb_ra4t1.bind(self);
    self.hx.seed(&self.serial.line);
    if (self.desc().memory.resolvedPeripherals() == .hx6538) self.time.base.setRate(self.desc().cpu0_hz);
}

/// Releases heap-backed component state owned by `self`.
pub fn destroy(self: *Board) void {
    self.capture.source.close();
    self.c6.deinit();
    self.sd.deinit();
    self.host_card.deinit();
    self.options.deinit();
    self.nor.deinit();
    self.bus.deinit();
    self.panel.deinit();
}

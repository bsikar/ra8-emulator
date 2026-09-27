//! The board: the peripheral bus and every block that answers on it.
//!
//! This is the part of the machine that is not the CPU. main.zig owns the
//! wiring of a run (read an ELF, reset, run, print), the engine owns the CPU,
//! and everything that lives behind an address in the peripheral window is
//! held here so neither of the other two has to know the list. The end-of-run
//! narration that reads this state lives next door in report.zig.
const std = @import("std");

const engine = @import("../core/engine.zig");
const i2c = @import("i2c.zig");
const wiring = @import("wiring.zig");
const part = @import("../core/part.zig");
const reboot = @import("../core/reboot.zig");
const periph = @import("../periph/registry.zig");
const adc = @import("../periph/adc.zig");
const agt = @import("../periph/agt.zig");
const bkup = @import("../periph/bkup.zig");
const acmphs = @import("../periph/acmphs.zig");
const cac = @import("../periph/cac.zig");
const canfd = @import("../periph/canfd.zig");
const ceu = @import("../periph/ceu.zig");
const crc = @import("../periph/crc.zig");
const dac = @import("../periph/dac.zig");
const dma_bank = @import("../periph/dma_bank.zig");
const dmac = @import("../periph/dmac.zig");
const doc = @import("../periph/doc.zig");
const dotf = @import("../periph/dotf.zig");
const drw = @import("../periph/drw.zig");
const dtc = @import("../periph/dtc.zig");
const eink = @import("../periph/eink.zig");
const elc = @import("../periph/elc.zig");
const glcdc = @import("../periph/glcdc.zig");
const gpio = @import("../periph/gpio.zig");
const gpt = @import("../periph/gpt.zig");
const gptp = @import("../periph/gptp.zig");
const icu = @import("../periph/icu.zig");
const ipc = @import("../periph/ipc.zig");
const lvd = @import("../periph/lvd.zig");
const mipi_csi = @import("../periph/mipi_csi.zig");
const mipi_dsi = @import("../periph/mipi_dsi.zig");
const mipi_phy = @import("../periph/mipi_phy.zig");
const modem = @import("../periph/modem.zig");
const net = @import("net.zig");
const mram = @import("../periph/mram.zig");
const mstp = @import("../periph/mstp.zig");
const npu = @import("../periph/npu.zig");
const pdctr = @import("../periph/pdctr.zig");
const pdm = @import("../periph/pdm.zig");
const poeg = @import("../periph/poeg.zig");
const prcr = @import("../periph/prcr.zig");
const reset = @import("../periph/reset.zig");
const rtc = @import("../periph/rtc.zig");
const rtt = @import("../periph/rtt.zig");
const cache = @import("../periph/cache.zig");
const scb = @import("../periph/scb.zig");
const sci = @import("../periph/sci.zig");
const sd_card = @import("../periph/sd_card.zig");
const sd_format = @import("../periph/sd_format.zig");
const sdhi = @import("../periph/sdhi.zig");
const spi = @import("../periph/spi.zig");
const sram = @import("../periph/sram.zig");
const ssie = @import("../periph/ssie.zig");
const ulpt = @import("../periph/ulpt.zig");
const usb = @import("usb.zig");
const iwdt = @import("../periph/iwdt.zig");
const wdt = @import("../periph/wdt.zig");
const xspi = @import("../periph/xspi.zig");

pub const Board = struct {
    bus: periph.Bus,
    modules: mstp.Mstp = .{},
    events: icu.Icu,
    /// The event link controller: the other half of the event path, where a
    /// source event drives a peripheral rather than an NVIC line, and the
    /// only way firmware raises an event itself.
    links: elc.Elc,
    /// The data transfer controller: the other consumer of an event, which
    /// moves bytes on an interrupt instead of letting the CPU take it.
    transfers: dtc.Dtc,
    /// The DMA module gate, and the eight channels behind it. Both are built
    /// in attach(): the channels need a pointer to this board's own bank, and
    /// the engine whose memory they copy.
    dma: dmac.Dmac,
    dma_module: dma_bank.Bank = .{},
    pins: gpio.Gpio,
    checksum: crc.Crc,
    dataops: doc.Doc,
    accuracy: cac.Cac,
    comparators: acmphs.Acmphs,
    /// The parallel-camera capture engine. No sensor behind it, so the
    /// observable is whether a frame actually landed in the buffer CDAYR
    /// points at. Built in attach(): it writes into the engine's memory.
    capture: ceu.Ceu,
    /// The two 12-bit D/A channels. No result readback on this part, so the
    /// code stream and DACR0.DACEN are the whole observable.
    analog: dac.Dac,
    /// The 16-bit A/D converter. No analog core behind it, so the observable
    /// is which scans actually ran and what they put in the result
    /// registers.
    adc: adc.Adc,
    /// Safe shutoff: the request flags that force the GPT outputs of a group
    /// into high impedance, and the state bit firmware reads back to prove it.
    shutoff: poeg.Poeg,
    protection: prcr.Prcr,
    backup: bkup.Bkup,
    /// The graphics power domain, and the one block so far that lives in it.
    /// Both are built in attach(): each needs a pointer to a model this board
    /// owns, not a copy of one.
    graphics: pdctr.Pdctr,
    display: glcdc.Glcdc,
    /// The 2D drawing engine, in the same domain and drawing into the same
    /// framebuffer the display controller scans out.
    raster: drw.Drw,
    serial: sci.Sci,
    /// The system I2C bus: the RIIC controller and the port expander and
    /// camera on it. Populated in attach(), the way the SPI line is.
    wire: i2c.Wire = .{},
    rswitch: net.Rswitch = .{},
    usb: usb.Usb = .{},
    /// The two SPI_B channels. No pin here, so the observable is the frames
    /// a channel actually clocked and the ones a disabled channel only wrote
    /// down.
    spi: spi.Spi,
    /// The e-paper panel, the other thing on the SPI line. Attached in
    /// attach(), which is also where its ready line is driven, because a
    /// firmware HRDY poll reads the pin rather than the panel.
    panel: eink.Panel = .{},
    /// The AT modem on the MikroBUS UART. Attached in attach(), the same
    /// way the card and the panel go on the SPI line: it is a device on
    /// SCI7's line, not a block of its own.
    modem: modem.Modem = .{},
    /// The debug probe draining the firmware's SEGGER RTT ring out of RAM.
    /// It owns no register window at all, so it is not on the bus: attach()
    /// only hands it the machine whose memory it reads.
    trace: rtt.Rtt = .{},
    /// The SD card on the SPI line, the other way an image reaches storage.
    /// Built in attach(): it holds only the blocks something wrote, so it
    /// needs the board's allocator, and attach() is where it goes on a line.
    sd: sd_card.Card,
    /// The volume a `--sd-new` format put on that card, for the report. Null
    /// when the card came up blank, which is every run that did not ask.
    sd_volume: ?sd_format.Volume = null,
    /// The extra-MRAM controller: the option-setting memory the MACI
    /// sequencer programs, and the commands it refuses. Built in attach():
    /// the cells are sparse and need the board's allocator, and a program
    /// that lands is written through to the engine's memory.
    options: mram.Mram,
    /// The octal NOR flash behind XSPI0, and the manual-command engine in
    /// front of it. Built in attach(): the part is sparse and needs the
    /// board's allocator to hold the sectors something actually wrote to.
    flash: xspi.Xspi,
    /// The decryption-on-the-fly stage in front of each xSPI controller.
    /// No AES core here, so what it answers for is the control word the
    /// driver polls and the conversion area it programmes.
    cipher: dotf.Dotf,
    /// The SD host controller, and the card behind it. Built in attach():
    /// the card holds only the blocks something wrote, so it needs the
    /// board's allocator.
    card: sdhi.Sdhi,
    /// The SRAM controller's ECC side: what the decoder self-test latched.
    /// The banks themselves are host memory, so this is the whole window.
    ecc: sram.Sram,
    /// The two I2S channels. No audio clock in the model, so the observable
    /// is the transmit handshake and the sample stream behind it.
    audio: ssie.Ssie,
    /// The three digital-microphone channels. No mic behind them, so the
    /// observable is whether the FIFO a capture loop drains was ever filled.
    microphone: pdm.Pdm,
    /// The calendar. It keeps its own time and raises the alarm and
    /// periodic events an image would otherwise wait on forever.
    clock: rtc.Rtc,
    /// The two CAN-FD controllers. No bus and no other node here, so the
    /// observable is the internal loopback: which frames actually left a
    /// running channel, and which of those a receive stage took.
    can: canfd.Canfd,
    /// The cross-core mailbox. Only the primary core runs in this build, so
    /// the observable is which pokes were for it and which messages the four
    /// stages actually carried.
    mailbox: ipc.Ipc,
    /// The Ethos-U55 micro-NPU. Only the RA8P1 carries one, so `part`
    /// decides whether attach() puts it on the bus at all; on the RA8D2 the
    /// window falls through to the sparse bus exactly as it does on dev.
    npu: npu.Npu,
    /// The low-power timer, which keeps counting through Software Standby
    /// and is how a sleeping part wakes itself back up.
    lowpower: ulpt.Ulpt,
    /// The interval timers: ten reloading down-counters, the block an image
    /// asks for a periodic tick from.
    interval: agt.Agt,
    /// The PWM timers: fourteen saw up-counters. No output pin in the model,
    /// so the observable is the count itself and the wrap past the period.
    pwm: gpt.Gpt,

    /// The Ethernet PTP timers: two free-running counters an image puts on
    /// network time and then reads back through a latched view.
    ptp: gptp.Gptp,
    monitors: lvd.Lvd,
    watchdog: wdt.Wdt,
    /// The independent watchdog: OFS0 starts it, software cannot stop it,
    /// and only the two-byte IWDTRR sequence keeps it fed.
    heartbeat: iwdt.Iwdt,
    /// The MIPI D-PHY under both display and camera: the LDO and PLL flags
    /// the bring-up sequence waits on before either link is worth starting.
    link: mipi_phy.MipiPhy,
    receiver: mipi_csi.MipiCsi,
    host: mipi_dsi.MipiDsi,
    causes: reset.Reset,
    control: scb.Scb,
    /// The Arm cache window in the PPB: the geometry the firmware reads out
    /// of CTR before every by-address maintenance call, and the maintenance
    /// it then asks for. Primed and polled like AIRCR beside it, because
    /// neither sits on the peripheral bus.
    caches: cache.Cache,
    /// Where a reset this board decides on is left for the engine to perform.
    /// main.zig points it at the run's own seam; a board built by a test that
    /// never reboots leaves it null and the request is only latched.
    reboot: ?*reboot.Reboot = null,
    /// Which part this board is. main.zig sets it from the command line
    /// before attach(); a board built by a test is an RA8D2 unless it says
    /// otherwise.
    part: part.Part = .ra8d2,

    pub fn init(allocator: std.mem.Allocator) Board {
        return .{
            .bus = periph.Bus.init(allocator),
            .events = icu.Icu.init(),
            .links = elc.Elc.init(),
            .transfers = dtc.Dtc.init(),
            .dma = undefined,
            .pins = gpio.Gpio.init(),
            .checksum = crc.Crc.init(),
            .dataops = doc.Doc.init(),
            .accuracy = cac.Cac.init(),
            .comparators = acmphs.Acmphs.init(),
            .capture = ceu.Ceu.init(),
            .analog = dac.Dac.init(),
            .adc = adc.Adc.init(),
            .shutoff = poeg.Poeg.init(),
            .protection = prcr.Prcr.init(),
            // Patched in attach(): the backup file has to point at this
            // board's own protection model, not a copy of it.
            .backup = undefined,
            .graphics = undefined,
            .display = undefined,
            .raster = undefined,
            .serial = sci.Sci.init(),
            .spi = spi.Spi.init(),
            .sd = sd_card.Card.init(allocator),
            .flash = xspi.Xspi.init(allocator),
            .cipher = dotf.Dotf.init(),
            .card = sdhi.Sdhi.init(allocator),
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
            .ptp = gptp.Gptp.init(),
            .monitors = lvd.Lvd.init(),
            .watchdog = wdt.Wdt.init(),
            .heartbeat = iwdt.Iwdt.init(),
            .link = mipi_phy.MipiPhy.init(),
            .receiver = mipi_csi.MipiCsi.init(),
            .host = mipi_dsi.MipiDsi.init(),
            .causes = reset.Reset.init(),
            .control = scb.Scb.init(),
            .caches = cache.Cache.init(),
        };
    }

    pub fn deinit(self: *Board) void {
        self.sd.deinit();
        self.card.deinit();
        self.options.deinit();
        self.flash.deinit();
        self.bus.deinit();
    }

    /// Put every block on the bus. The order is load-bearing and lives
    /// next door in wiring.zig.
    pub fn attach(self: *Board, core: *engine.Engine) !void {
        return wiring.attach(self, core);
    }

    /// The chunk boundary, peripheral side: the watchdog counts, a block with
    /// an event due raises it into the event links, a reset the watchdog asked
    /// for is recorded as the boot cause, then any line still latched
    /// re-pends. The controller picks straight afterwards, so an interrupt
    /// raised here is entered in the same boundary rather than a chunk later.
    pub fn tick(self: *Board, core: engine.Engine) !void {
        self.watchdog.tick();
        self.heartbeat.tick();
        self.lowpower.tick();
        self.microphone.tick();
        self.clock.tick();
        self.interval.tick();
        self.pwm.tick();
        self.ptp.tick();
        self.trace.tick();
        self.rswitch.tick();
        try self.takeResetRequests(core);
        try self.drain(core, self.serial.dueEvents());
        try self.drain(core, self.lowpower.dueEvents());
        try self.drain(core, self.mailbox.dueEvents());
        try self.drain(core, self.can.dueEvents());
        try self.drain(core, self.npu.dueEvents());
        try self.drain(core, self.clock.dueEvents());
        try self.drain(core, self.interval.dueEvents());
        try self.drain(core, self.pwm.dueEvents());
        try self.drain(core, self.adc.dueEvents());
        try self.drain(core, self.dma.dueEvents());
        try self.drain(core, self.links.takeEvents());
        try self.events.repend(core);
    }

    /// Every event one block has due this boundary, offered one at a time.
    fn drain(self: *Board, core: engine.Engine, events: anytype) !void {
        for (events.constSlice()) |event| try self.raise(core, event);
    }

    /// One event, offered to all three consumers of one. The links first,
    /// and they see EVERY event, not just the four the ELC generates: an
    /// event fans out to the ICU and the ELC at once, and a link conducts
    /// without consuming it. Then the transfer controller, before the core:
    /// a DTCE slot belongs to the DTC until its descriptor runs out.
    pub fn raise(self: *Board, core: engine.Engine, event: u16) !void {
        _ = self.links.conduct(event);
        if (self.transfers.activate(core, &self.events, event)) |moved| {
            if (!moved.interrupt) return;
        }
        try self.events.raise(core, event);
    }

    /// Whoever asked for a reset this boundary hands the request to the reset
    /// block, which latches the cause the firmware will read on the way back
    /// up. A software request is then performed: the run has a reboot seam and
    /// the firmware behind AIRCR is sitting in a wait loop expecting the part
    /// to go away. A watchdog request still only latches, because the image
    /// that tripped it has nothing waiting on the reboot.
    pub fn takeResetRequests(self: *Board, core: anytype) !void {
        if (self.watchdog.reset_requested) {
            self.watchdog.reset_requested = false;
            self.causes.request(.watchdog);
        }
        if (self.heartbeat.reset_requested) {
            self.heartbeat.reset_requested = false;
            self.causes.request(.iwdt);
        }
        try self.caches.poll(core);
        if (!try self.control.poll(core)) return;
        self.causes.request(.software);
        self.events.clearLatches();
        if (self.reboot) |pending| pending.requested = true;
    }

    pub fn ticker(self: *Board) engine.Tick {
        return .{ .context = self, .tickFn = tickThunk };
    }
};

fn tickThunk(context: *anyopaque, core: engine.Engine) anyerror!void {
    const board: *Board = @ptrCast(@alignCast(context));
    return board.tick(core);
}

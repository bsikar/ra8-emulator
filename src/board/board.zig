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
const construct = @import("construct.zig");
const boundary = @import("boundary.zig");
const part = @import("../core/part.zig");
const reboot = @import("../core/reboot.zig");
const periph = @import("../periph/registry.zig");
const adc = @import("../periph/adc/adc.zig");
const agt = @import("../periph/agt/agt.zig");
const bkup = @import("../periph/bkup/bkup.zig");
const acmphs = @import("../periph/acmphs/acmphs.zig");
const cac = @import("../periph/cac.zig");
const canfd = @import("../periph/canfd/canfd.zig");
const ceu = @import("../periph/ceu.zig");
const crc = @import("../periph/crc.zig");
const dac = @import("../periph/dac/dac.zig");
const dma_bank = @import("../periph/dma_bank.zig");
const dmac = @import("../periph/dmac/dmac.zig");
const doc = @import("../periph/doc/doc.zig");
const dotf = @import("../periph/dotf/dotf.zig");
const drw = @import("../periph/drw/drw.zig");
const dtc = @import("../periph/dtc/dtc.zig");
const eink = @import("../periph/eink/eink.zig");
const elc = @import("../periph/elc/elc.zig");
const glcdc = @import("../periph/glcdc/glcdc.zig");
const gpio = @import("../periph/gpio/gpio.zig");
const pfs = @import("../periph/pfs/pfs.zig");
const gpt = @import("../periph/gpt/gpt.zig");
const gptp = @import("../periph/gptp/gptp.zig");
const icu = @import("../periph/icu/icu.zig");
const ipc = @import("../periph/ipc/ipc.zig");
const lvd = @import("../periph/lvd/lvd.zig");
const mipi_csi = @import("../periph/mipi/mipi_csi.zig");
const mipi_dsi = @import("../periph/mipi/mipi_dsi.zig");
const mipi_phy = @import("../periph/mipi/mipi_phy.zig");
const modem = @import("../periph/modem/modem.zig");
const net = @import("net.zig");
const mram = @import("../periph/mram/mram.zig");
const sdramc = @import("../periph/sdramc.zig");
const cpu_ctrl = @import("../periph/cpu_ctrl.zig");
const mrms = @import("../periph/mrms.zig");
const mstp = @import("../periph/mstp/mstp.zig");
const octaclk = @import("../periph/octaclk.zig");
const pscu = @import("../periph/pscu.zig");
const cpscu = @import("../periph/cpscu.zig");
const gtclkcr = @import("../periph/gtclkcr.zig");
const npu = @import("../periph/npu/npu.zig");
const ckcr = @import("../periph/ckcr.zig");
const ckdiv = @import("../periph/ckdiv.zig");
const oscsf = @import("../periph/oscsf.zig");
const subclock = @import("../periph/subclock.zig");
const sysclk = @import("../periph/sysclk/sysclk.zig");
const lpm = @import("../periph/lpm/lpm.zig");
const pll = @import("../periph/pll/pll.zig");
const vscr = @import("../periph/vscr.zig");
const voltage_hazard = @import("../periph/voltage_hazard.zig");
const pdctr = @import("../periph/pdctr.zig");
const pdm = @import("../periph/pdm.zig");
const poeg = @import("../periph/poeg.zig");
const prcr = @import("../periph/prcr.zig");
const reset = @import("../periph/reset.zig");
const rtc = @import("../periph/rtc/rtc.zig");
const rtt = @import("../periph/rtt/rtt.zig");
const cache = @import("../periph/cache/cache.zig");
const mpu = @import("../periph/mpu/mpu.zig");
const sau = @import("../periph/sau.zig");
const mpu_guard = @import("../core/mpu_guard.zig");
const scb = @import("../periph/scb.zig");
const fault_clear = @import("../periph/fault_clear.zig");
const sci = @import("../periph/sci/sci.zig");
const sci_input = @import("../periph/sci/sci_input.zig");
const gt911 = @import("../periph/i3c/i3c_gt911.zig");
const sd_card = @import("../periph/sd/sd_card.zig");
const sd_card_line = @import("../periph/sd/sd_card_line.zig");
const sd_format = @import("../periph/sd/sd_format.zig");
const sdhi = @import("../periph/sdhi/sdhi.zig");
const spi = @import("../periph/spi/spi.zig");
const sram = @import("../periph/sram/sram.zig");
const ssie = @import("../periph/ssie/ssie.zig");
const ulpt = @import("../periph/ulpt/ulpt.zig");
const usb = @import("usb.zig");
const iwdt = @import("../periph/iwdt/iwdt.zig");
const wdt = @import("../periph/wdt/wdt.zig");
const xspi = @import("../periph/xspi/xspi.zig");

pub const Board = struct {
    bus: periph.Bus,
    modules: mstp.Mstp = .{},
    attribution: pscu.Unit = .{},
    /// GTCLKCR, the GPT bank's clock domain, writable only while stopped.
    gpt_clock: gtclkcr.Unit,
    events: icu.Icu,
    /// The event link controller: the other half of the event path, where a
    /// source event drives a peripheral rather than an NVIC line, and the
    /// only way firmware raises an event itself.
    links: elc.Elc,
    /// The data transfer controller: the other consumer of an event, which
    /// moves bytes on an interrupt instead of letting the CPU take it.
    transfers: dtc.Dtc,
    /// DTC1, CPU1's own transfer controller at DTC0's address.
    transfers1: dtc.Dtc,
    /// DTCSAR: which of DTC0 and DTC1 the boot handed to Non-secure.
    transfer_attribution: dtc.attribution.Unit,
    /// The DMA module gate, and the eight channels behind it. Both are built
    /// in attach(): the channels need a pointer to this board's own bank, and
    /// the engine whose memory they copy.
    dma: dmac.Dmac,
    dma_module: dma_bank.Bank = .{},
    pins: gpio.Gpio,
    /// The pin function array and the write protect in front of it.
    pinfunc: pfs.Pfs,
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
    /// VBTBPCR1: the battery power-supply switch stop.
    battery_switch: bkup.pcr1.Pcr1,
    /// The peripheral clock source selects, built in attach() for the same
    /// reason the two below are: each needs this board's own protection.
    branches: ckcr.Ckcr,
    /// The chip-level security attribution: which bus masters, master-MPU
    /// windows and CPUs the Secure boot gave away. Built in attach(): every
    /// store is PRC4-gated, so it needs this board's own protection.
    chip_attribution: cpscu.Unit,
    /// SRAMSAR, SRAMSABAR0..3 and SRAMESAR (RA8EMU-230).
    sram_attribution: cpscu.sram.Unit = .{},
    /// CMSAMON/SFSAMON, the code MRAM and SiP flash split the OEM programmed.
    /// An unset CMS keeps the IDAU's bit-28 answer for code (RA8EMU-389/420).
    memory_monitors: pscu.samon.Unit = .{},
    /// The IDAU over those words and address bit 28 (RA8EMU-277). Pointed
    /// at sram_attribution in attach(), where the board's address is final.
    idau: sau.idau.Map = .{},
    /// The handshake CPU0 uses to take the second core out of reset. Keyed,
    /// so nothing lands here without the key the driver writes.
    second_core: cpu_ctrl.CpuCtrl = .{},
    /// CPU1's engine once attachSecond has put it on the bus, so an event
    /// INTSELR hands to CPU1 pends CPU1's NVIC. Null on a single-core run.
    cpu1: ?engine.Engine = null,
    /// The code-MRAM frequency latches and the prefetch buffer. Keyed
    /// registers, so nothing lands here without the key the driver writes.
    memory_rates: mrms.Mrms = .{},
    /// The MRAM ECC controls and program speed (src/periph/mrms_ecc.zig).
    memory_ecc: mrms.ecc.Ecc = .{},
    /// The SDRAM controller and SDCKOCR (src/periph/sdramc.zig).
    sdram: sdramc.Sdramc = .{},
    ratios: ckdiv.Ckdiv,

    /// The four clock sources and the stabilisation flags that follow their
    /// stop bits. Built in attach(): every store is PRC0-gated, so it needs a
    /// pointer to this board's own protection model rather than a copy.
    oscillators: oscsf.Oscillators,
    subclk: subclock.Unit,
    /// LOCOCR: the low-speed oscillator's stop bit.
    loco: subclock.loco.Unit,
    /// The system clock tree: the source CKSEL picks and the dividers under
    /// it. Built in attach(): every store is PRC0-gated and a select is
    /// checked against the stabilisation flags, so it needs pointers to this
    /// board's own protection and oscillators rather than copies.
    tree: sysclk.Tree,
    /// SBYCR / DPSBYCR / LPSCR, behind PRCR.PRC1.
    low_power: lpm.Unit,
    /// DPSIER/DPSIFR/DPSIEGR: which sources may end deep standby.
    standby_cancel: lpm.dps.Dps = .{},
    /// PLLCCR / PLLCCR2 / MOSCWTCR, behind PRCR.PRC0.
    plls: pll.Unit,
    /// VSCR, the core voltage range, behind PRCR.PRC0.
    voltage: vscr.Unit,
    brownout: voltage_hazard.Watch,
    /// The switchable power domains, both gated off at reset: the graphics one
    /// the display blocks live in, and the ESWM one the Ethernet cluster does.
    /// Built in attach(), which is where the PRCR they ask already exists.
    domains: pdctr.Domains,
    display: glcdc.Glcdc,
    /// The 2D drawing engine, in the same domain and drawing into the same
    /// framebuffer the display controller scans out.
    raster: drw.Drw,
    serial: sci.Sci,
    /// Host stdin is sampled at each board boundary when --console is set.
    console_input: sci_input.Input = .{},
    /// Host touches sampled at each board boundary under `--touch @PATH`.
    touch_input: gt911.host.Input = .{},
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
    /// The SD card on the Pmod2 line, the other way an image reaches
    /// storage. Built in attach(): it holds only the blocks something wrote,
    /// so it needs the board's allocator, and attach() is where it goes on a
    /// line.
    sd: sd_card.Card,
    /// The card as something on SCI0's line. Built in attach(), which is
    /// also where it is handed the card it speaks for: it holds a pointer,
    /// so it cannot be built before the board it points into.
    sd_line: sd_card_line.Line = undefined,
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
    /// Whether the OSPI was uncovered on a stable OCTACLK. Built in attach():
    /// it reads the clock-select model live, so it cannot exist before it.
    octa: octaclk.Octa,
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
    /// The PDG delay lines in front of GPT channels 0..3.
    pwm_delay: gpt.pdg.Pdg,

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
    /// CPU0's owed CFSR/HFSR clears: src/periph/fault_clear.zig.
    clears: fault_clear.Clears,
    /// The Arm cache window in the PPB: the geometry the firmware reads out
    /// of CTR before every by-address maintenance call, and the maintenance
    /// it then asks for. Primed and polled like AIRCR beside it.
    caches: cache.Cache,
    /// The MPU window, beside the cache one and primed the same way: TYPE is
    /// hardwired, so nothing would have put the region count there.
    regions: mpu.Mpu,
    /// The Non-secure MPU the Zig core banks into (RA8EMU-446).
    regions_ns: mpu.Mpu,
    /// MPU enforcement: the traps kept over the read-only regions while
    /// CTRL.ENABLE stands, and what they caught. Beside the table because
    /// one is what the firmware programmed, the other what the engine does.
    guard: mpu_guard.Guard,
    /// The SAU window, third PPB block: TYPE is hardwired like the MPU's.
    partitions: sau.Sau,
    /// Where a reset this board decides on is left for the engine to perform.
    /// main.zig points it at the run's seam; a test's board leaves it null.
    reboot: ?*reboot.Reboot = null,
    /// Which part this board is. main.zig sets it from the command line
    /// before attach(); a test's board is an RA8D2 unless it says otherwise.
    part: part.Part = .ra8d2,

    /// A fresh board. What each block starts as lives next door in
    /// construct.zig, so this file stays the list of what a board is.
    pub fn init(allocator: std.mem.Allocator) Board {
        return construct.build(allocator);
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

    /// The chunk boundary, peripheral side. What actually happens there is
    /// next door in boundary.zig: the order the blocks are stepped in and
    /// where an event goes is its own subject, and this file is the list of
    /// what the board is made of.
    pub fn tick(self: *Board, core: engine.Engine) !void {
        return boundary.tick(self, core);
    }

    /// One event, offered to the links, the transfer controller and the core.
    pub fn raise(self: *Board, core: engine.Engine, event: u16) !void {
        return boundary.raise(self, core, event);
    }

    /// Whoever asked for a reset this boundary, plus the PPB windows that are
    /// polled rather than hooked.
    pub fn takeResetRequests(self: *Board, core: anytype) !void {
        return boundary.takeResetRequests(self, core);
    }

    /// A reset another core asked for, latched and handed to the run loop
    /// the way CPU0's own request is (RA8EMU-59).
    pub fn requestReset(self: *Board, source: reset.Source) void {
        boundary.resetFor(self, source);
    }

    pub fn ticker(self: *Board) engine.Tick {
        return .{ .context = self, .tickFn = tickThunk };
    }
};

fn tickThunk(context: *anyopaque, core: engine.Engine) anyerror!void {
    const board: *Board = @ptrCast(@alignCast(context));
    return board.tick(core);
}

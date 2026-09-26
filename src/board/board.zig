//! The board: the peripheral bus and every block that answers on it.
//!
//! This is the part of the machine that is not the CPU. main.zig owns the
//! wiring of a run (read an ELF, reset, run, print), the engine owns the CPU,
//! and everything that lives behind an address in the peripheral window is
//! held here so neither of the other two has to know the list. The end-of-run
//! narration that reads this state lives next door in report.zig.
const std = @import("std");

const engine = @import("../core/engine.zig");
const reboot = @import("../core/reboot.zig");
const periph = @import("../periph/registry.zig");
const bkup = @import("../periph/bkup.zig");
const cac = @import("../periph/cac.zig");
const crc = @import("../periph/crc.zig");
const dac = @import("../periph/dac.zig");
const dma_bank = @import("../periph/dma_bank.zig");
const dmac = @import("../periph/dmac.zig");
const doc = @import("../periph/doc.zig");
const drw = @import("../periph/drw.zig");
const dtc = @import("../periph/dtc.zig");
const elc = @import("../periph/elc.zig");
const glcdc = @import("../periph/glcdc.zig");
const gpio = @import("../periph/gpio.zig");
const icu = @import("../periph/icu.zig");
const lvd = @import("../periph/lvd.zig");
const mstp = @import("../periph/mstp.zig");
const pdctr = @import("../periph/pdctr.zig");
const poeg = @import("../periph/poeg.zig");
const prcr = @import("../periph/prcr.zig");
const reset = @import("../periph/reset.zig");
const scb = @import("../periph/scb.zig");
const sci = @import("../periph/sci.zig");
const ssie = @import("../periph/ssie.zig");
const ulpt = @import("../periph/ulpt.zig");
const wdt = @import("../periph/wdt.zig");

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
    /// The two 12-bit D/A channels. No result readback on this part, so the
    /// code stream and DACR0.DACEN are the whole observable.
    analog: dac.Dac,
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
    /// The two I2S channels. No audio clock in the model, so the observable
    /// is the transmit handshake and the sample stream behind it.
    audio: ssie.Ssie,
    /// The low-power timer, which keeps counting through Software Standby
    /// and is how a sleeping part wakes itself back up.
    lowpower: ulpt.Ulpt,
    monitors: lvd.Lvd,
    watchdog: wdt.Wdt,
    causes: reset.Reset,
    control: scb.Scb,
    /// Where a reset this board decides on is left for the engine to perform.
    /// main.zig points it at the run's own seam; a board built by a test that
    /// never reboots leaves it null and the request is only latched.
    reboot: ?*reboot.Reboot = null,

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
            .analog = dac.Dac.init(),
            .shutoff = poeg.Poeg.init(),
            .protection = prcr.Prcr.init(),
            // Patched in attach(): the backup file has to point at this
            // board's own protection model, not a copy of it.
            .backup = undefined,
            .graphics = undefined,
            .display = undefined,
            .raster = undefined,
            .serial = sci.Sci.init(),
            .audio = ssie.Ssie.init(),
            .lowpower = ulpt.Ulpt.init(),
            .monitors = lvd.Lvd.init(),
            .watchdog = wdt.Wdt.init(),
            .causes = reset.Reset.init(),
            .control = scb.Scb.init(),
        };
    }

    pub fn deinit(self: *Board) void {
        self.bus.deinit();
    }

    /// Order matters. The module-stop shadow goes on first and then becomes
    /// the gate the rest of the bus is filtered through; PORT follows it
    /// because PORT has no module-stop bit on this part and has to answer
    /// regardless of MSTPCRx.
    pub fn attach(self: *Board, core: *engine.Engine) !void {
        try self.bus.add(self.modules.block());
        self.bus.gate = self.modules.gate();
        try self.bus.add(self.pins.block());
        try self.bus.add(self.checksum.block());
        try self.bus.add(self.dataops.block());
        try self.bus.add(self.accuracy.block());
        try self.bus.add(self.analog.block());
        try self.bus.add(self.shutoff.block());
        try self.bus.add(self.protection.block());
        self.backup = bkup.Bkup.init(&self.protection);
        try self.bus.add(self.backup.block());
        self.graphics = pdctr.Pdctr.init(&self.protection);
        try self.bus.add(self.graphics.block());
        self.display = glcdc.Glcdc.init(&self.graphics);
        try self.bus.add(self.display.block());
        self.raster = drw.Drw.init(&self.graphics);
        // The engine rasterizes into RAM, so it needs the machine that owns
        // it. A board built by a test without one declines the render.
        self.raster.memory = core.*;
        try self.bus.add(self.raster.block());
        try self.bus.add(self.serial.block());
        try self.bus.add(self.audio.block());
        try self.bus.add(self.lowpower.block());
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
        try self.bus.add(self.causes.statusBlock());
        try self.bus.add(self.causes.causeBlock());
        try core.attachPeriph(&self.bus);
        // AIRCR is PPB RAM, not a bus block, and RAM starts at zero: without
        // this the first read of it is 0 rather than the key status.
        try self.control.prime(core.*);
    }

    /// The chunk boundary, peripheral side: the watchdog counts, a block with
    /// an event due raises it into the event links, a reset the watchdog asked
    /// for is recorded as the boot cause, then any line still latched
    /// re-pends. The controller picks straight afterwards, so an interrupt
    /// raised here is entered in the same boundary rather than a chunk later.
    pub fn tick(self: *Board, core: engine.Engine) !void {
        self.watchdog.tick();
        self.lowpower.tick();
        try self.takeResetRequests(core);
        for (self.serial.dueEvents().constSlice()) |event| {
            try self.raise(core, event);
        }
        for (self.lowpower.dueEvents().constSlice()) |event| {
            try self.raise(core, event);
        }
        for (self.dma.dueEvents().constSlice()) |event| {
            try self.raise(core, event);
        }
        for (self.links.takeEvents().constSlice()) |event| {
            try self.raise(core, event);
        }
        try self.events.repend(core);
    }

    /// One event, offered to the transfer controller before the core. A slot
    /// with IELSR.DTCE set belongs to the DTC: it moves its descriptor's
    /// units and keeps the interrupt to itself until the descriptor runs out,
    /// which is the whole reason firmware sets DTCE instead of handling every
    /// byte in an ISR. Everything else goes straight to the event links.
    pub fn raise(self: *Board, core: engine.Engine, event: u16) !void {
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

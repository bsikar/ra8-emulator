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
const doc = @import("../periph/doc.zig");
const gpio = @import("../periph/gpio.zig");
const icu = @import("../periph/icu.zig");
const lvd = @import("../periph/lvd.zig");
const mstp = @import("../periph/mstp.zig");
const prcr = @import("../periph/prcr.zig");
const reset = @import("../periph/reset.zig");
const scb = @import("../periph/scb.zig");
const sci = @import("../periph/sci.zig");
const wdt = @import("../periph/wdt.zig");

pub const Board = struct {
    bus: periph.Bus,
    modules: mstp.Mstp = .{},
    events: icu.Icu,
    pins: gpio.Gpio,
    checksum: crc.Crc,
    dataops: doc.Doc,
    accuracy: cac.Cac,
    protection: prcr.Prcr,
    backup: bkup.Bkup,
    serial: sci.Sci,
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
            .pins = gpio.Gpio.init(),
            .checksum = crc.Crc.init(),
            .dataops = doc.Doc.init(),
            .accuracy = cac.Cac.init(),
            .protection = prcr.Prcr.init(),
            // Patched in attach(): the backup file has to point at this
            // board's own protection model, not a copy of it.
            .backup = undefined,
            .serial = sci.Sci.init(),
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
        try self.bus.add(self.protection.block());
        self.backup = bkup.Bkup.init(&self.protection);
        try self.bus.add(self.backup.block());
        try self.bus.add(self.serial.block());
        try self.bus.add(self.events.block());
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
        try self.takeResetRequests(core);
        for (self.serial.dueEvents().constSlice()) |event| {
            try self.events.raise(core, event);
        }
        try self.events.repend(core);
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
